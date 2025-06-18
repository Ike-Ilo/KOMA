import AVFoundation

/// ``AudioStreamUp``  class is a real-time audio streaming engine.
/// It captures live audio from the device's microphone using 'AVAudioEngine' , buffers the input. and after accumlating 5 seconds of audio (@ 44.1kHz),
/// ir sends the audio as 16-bit PCM data to a WebSocket backend for musical analysis.
/// The backend returns information such as BPM(Beats Per Minute), Key Signature and Detection Status as explained in ``init(completion:)``.
/// These values are passes back to SwiftUI later via the 'completion;' closure.
///
/// ### Key Features:
/// - 5-second fixed-length audio capture per detection cycle
/// - Downsamples waveform data for real-time UI visualization
/// - WebSocket communication to send/receive musical data
/// - Automatic timeout using 'Timer' to end detection after one cycle
/// - Handles channel merging and audio format eencoding internally
/// - Built-in reconnection logic on WebSocket failures
///
/// ### Usage:
///  ```swift
///  let stream = AudioStreamUp { bpm, key, status in
///     print("BPM: \(bpm), Key: \(key), Status: \(status)")
///```
///
///To manually halt streaming before the 5-second timeout, call:
///```swift
///stream.stop()
///```
///> Tip: Designed for clean one-shot detection workflows.
///
///> Warning:
///``AVAudioSession`` is shared across the app. If another audio session is started elsewhere, it can conflict or interrupt the current one. Avoid multiple simultaneous audio session.
///
///
class AudioStreamUp: ObservableObject {
    /// closure called when the backend returns BPM, Key Signature and Status.
    private let completion: (String, String, String) -> Void
    /// Core audio engine to capture microphone input
    private let audioEngine = AVAudioEngine()
    /// Persistent connection to the backend
    private var webSocketTask: URLSessionWebSocketTask?
    /// Times out audio collection after 5 seconds for consistent detection time.
    private var detectionTimer: Timer?
    
    
    /// track how many audio frames have been collected so far during a streaming session.
    private var totalFrameCount = 0
    /// Controls batching: 5 seconds of audio at 44.1kHz.
    private let targetFrameCount = 44100 * 5
    
    /// Downsampled waveform data for UI Display
    @Published var samples: [Float] = []
    
    /// Is an internal buffer queue that temporarily stores chunks of live audio captured from the microphone.
    ///
    /// This array holds multiple ``AVAudioPCMBuffer`` instances — each representing a short segment of audio — until a complete 5-second window is accumulated (as tracked by ``totalFrameCount``).
    private var audioBufferQueue = [AVAudioPCMBuffer]()
    /// declares a constant property named maxBuffersToBatch that is only accessible within the ``AudioStreamUp`` class, and is set to the integer value 3.
    /// >tip: If you're processing short bursts of audio, you might want to limit how many buffers are allowed in audioBufferQueue and trigger merging/sending early if audioBufferQueue.count >= maxBuffersToBatch.
    private let maxBuffersToBatch = 3
    /// Dedicated serial dispatch queue to ensure thread-safe-access to the shared resource audioBufferQueue.
    ///
    /// Because audio buffering and merging can happen across multiple threads (e.g. audio tap callback, background batching, WebSocket communication), it's essential to prevent race conditions or data corruption when reading from or writing to audioBufferQueue.
    /// This queue acts as a lock mechanism, serializing access like so:
    /// ```swift
    /// bufferQueueLock.sync {
    /// safe access or modification of audioBufferQueue
    /// }
    /// ```
    private let bufferQueueLock = DispatchQueue(label: "BufferQueueLock")
    
    /// Starts the audio session, WebSocket connection and a 5 section dection timer that will stop the stream after one cycle
    ///
    /// BPM = The beats per minute detected from the streamed audio.
    /// ```swift
    /// 128
    /// ```
    /// KEY SIGNATURE = The musical key signature detected.
    /// ```swift
    /// C major
    /// ```
    /// STATUS = Detection status message from the server such as:
    /// ```swift
    /// "Detected", "Timeout", "Error"
    /// ```
    ///
    /// >Upon instantiation these are the functionalities performed in init:
    /// - Stores the completion handler for later use once detection results are received.
    /// - Starts the audio capture session via startAudioSession() — initializes microphone, taps input, and sets up waveform buffering.
    /// - Establishes a WebSocket connection to the backend with connectWebSocket().
    /// - Initializes a one-shot timer that stops the stream after 5 seconds using:
    /// ```swift
    /// Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in self.stop() }
    /// ```
    /// This ensures that even if the user doesn't stop the stream manually, it automatically ends after a defined period — optimizing performance and bandwidth.
    /// - Parameter completion: A closure that is executed once the server responds with analysis results. It takes three string values: BPM, KEY and STATUS.
    init(completion: @escaping (String, String, String) -> Void) {
        self.completion = completion
        startAudioSession()
        connectWebSocket()
        
        DispatchQueue.main.async {
            self.detectionTimer?.invalidate()
            self.detectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                print("⏱ Timer ended, stopping stream")
                self.stop()
                
            }
        }
        //Notified when another session interrupts the stream
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }
            if type == .began{
                print("Audio session interruption began")
                self.stop()
            } else if type == .ended {
                print("Audio session interruption ended")
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            
        }
    }
    
    /// This method configures, starts and taps into the IOS audio engine to activate the microphone, capture real-time audio data,
    /// process audio for waveform visualization, prepare audio buffers for analysis and transmission.
    ///
    ///  1. > Access the shared audio session:
    ///  ```swift
    ///  let session = AVAudioSession.sharedInstance()
    ///  ```
    ///  This gets the global AVAudioSession instance which manages the device audio behavior
    ///
    ///  2. >Configure the audio session:
    ///  ```swift
    /// try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
    /// try session.setActive(true)
    /// ```
    /// - .playAndRecord: Allows input from the microphone and output to speakers or headphones.
    /// - .measurement: Optimized for audio analysis (disables voice processing).
    /// - [.defaultToSpeaker, .allowBluetooth]: Routes output to the speaker by default and allows Bluetooth mic/headset input.
    /// - setActive(true): Activates the session for use.
    ///
    /// 3. >Configure microphone input:
    /// ```swift
    /// let inputNode = audioEngine.inputNode
    /// let format = inputNode.inputFormat(forBus: 0)
    /// ```
    /// - Retrieves the mic input node
    /// - Gets the audio format (e.g., sample rate, channel count).
    ///
    ///4. >Install a tap on the mic input:
    ///```swift
    ///inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
    ///```
    ///- Adds a callback that receives audio data in chunks (bufferSize: 1024 frames).
    ///- Called continuously as audio flows into the app
    ///
    ///5. >Validate and downsample audio:
    ///```swift
    /// guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
    /// return
    /// }
    /// let channelSamples = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
    /// let downsampled = stride(from: 0, to: channelSamples.count, by: 10).map {
    ///  min(1.0, abs(channelSamples[$0]) * 10)
    ///}
    ///```
    /// - Verifies audio data is valid
    /// - Converts audio to downsample represation(1 out of ever 10 samples).
    /// - Boosts amplitude (x10) and clamps values to  [0.0. 1.0] for UI waveform display.
    ///
    ///6. >Update UI waveform:
    ///```swift
    /// DispatchQueue.main.async {
    /// self.samples = downsampled
    /// }
    ///```
    ///- Sends the simplified waveform to the main thread for real-time display in SwiftUI.
    ///
    ///7. >Clone buffer for backend analysis:
    ///```swift
    /// let copiedBuffer = AVAudioPCMBuffer(...)
    /// memcpy(...)
    ///```
    ///- Creates a deep copy of the audio buffer.
    ///- Copies float samples  channel-by-channel.
    ///
    ///8. >Queue buffer for batching
    ///```swift
    /// DispatchQueue.global(qos: .userInitiated).async {
    /// self.enqueueAndBatchBuffer(copiedBuffer, format: format)
    /// }
    ///```
    ///- Adds the copied buffer to a queue
    ///- Once 5 seconds of audio is collected, it is merged and sent to the backend.
    ///
    ///9. >Start the audio engine
    ///```swift
    ///try audioEngine.start()
    ///```
    ///- Begins microphone input
    ///- Audio tap now starts receiving real-time data.
    ///
    ///>Warning: Exceness memory usage. Downsample and clear buffers promptly
    private func startAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("AVAudioSession activate")
        } catch {
            print("❌ Audio session error: \(error)")
        }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                return
            }
            let channelSamples = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
            let downsampled = stride(from: 0, to: channelSamples.count, by: 10).map {
                min(1.0, abs(channelSamples[$0]) * 10)  // Apply gain
            }
            
            DispatchQueue.main.async {
                self.samples = downsampled
            }
            
            
            let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)!
            copiedBuffer.frameLength = buffer.frameLength
            for i in 0..<Int(buffer.format.channelCount) {
                memcpy(copiedBuffer.floatChannelData![i], buffer.floatChannelData![i], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.enqueueAndBatchBuffer(copiedBuffer, format: format)
            }
        }
        
        do {
            try audioEngine.start()
            print("✅ Audio Engine Started")
        } catch {
            print("❌ Audio Engine Failed: \(error)")
        }
    }
    
    /// This method safely appends a new audio buffer to a queue as well as accumulating the total numbers of frames received.
    /// Onece enough audio are collected (5 seconds worth), it mergers all queued buffers into a single buffer,
    /// sends the merged buffer to the backend over WebSocket,
    /// clears the buffer queue and resets the counter.
    ///
    ///
    ///
    /// - Parameters:
    ///   - buffer: A real-time audio chunk captured from the microphone. Type ``AVAudioPCMBuffer``
    ///   - format: The format (sample rate, channels, etc.) of the audio data.
    ///
    ///1. >Thread-Safe Access with Lock:
    ///```swift
    ///bufferQueueLock.sync {
    ///...
    ///}
    ///```
    ///- Uses a serial DispatchQueue (bufferQueueLock) to synchronize access to shared state (audioBufferQueue, totalFrameCount) and prevent race conditions.
    ///
    ///2. >Append New Audio Chunk
    ///```swift
    ///audioBufferQueue.append(buffer)
    ///totalFrameCount += Int(buffer.frameLength)
    ///```
    ///
    ///3. >Check if Enough Audio Has Been Collected
    /// ```swift
    /// if totalFrameCount >= targetFrameCount
    /// ```
    /// - targetFrameCount is typically 44100 * 5 (5 seconds of 441.kHz audio).
    /// - Once this threshold is reached, the app proceeds to batch and send data.
    ///
    /// 4. >Merge and Send the Audio
    ///```swift
    /// let merged = mergeBuffers(audioBufferQueue, format: format)
    /// audioBufferQueue.removeAll()
    /// totalFrameCount = 0
    /// sendMergedBuffer(merged, format: format)
    ///```
    ///- mergeBuffers: Combines multiple small buffers into a large one.
    ///- removeAll(): Clears the queue for the next collection cycle.
    ///- totalFrameCount = 0: Resets framee counter for next batch.
    ///- sendMergedBuffer: Converts audio to int16 PCM and transmits it over WebSocket to the backend for analysis.
    ///
    ///>Tip: sendMergedBuffer handles WebSocket connection checks.
    private func enqueueAndBatchBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        bufferQueueLock.sync {
            audioBufferQueue.append(buffer)
            totalFrameCount += Int(buffer.frameLength)
            
            if totalFrameCount >= targetFrameCount {
                let merged = mergeBuffers(audioBufferQueue, format: format)
                audioBufferQueue.removeAll()
                totalFrameCount = 0
                sendMergedBuffer(merged, format: format)
            }
        }
    }
    
    /// Merges multiple audio buffers into a single contigous/adjacent buffer. This method is used to concatenate
    /// serval `AVAudioPCMBuffer` instances into one larger buffer. It is useful when batching multiple short audio segments into a full-length buffer for
    /// analysis or transimition
    ///
    /// - Parameters:
    ///   - buffers: An array of `AVAudioPCMBuffer` instance to be merged. Each buffer must have the same format.
    ///   - format: The `AVAudioFormat` describing the audio format shared by all input buggers like sample rate and channels.
    /// - Returns: A single `AVAudioPCMBuffer` that contains the audio data from all the provided buffers in sequential order.
    /// >Important: This code assumes all input buffers have matching format and channel count. The return buffer is allocated with a total frame capacity equal to the sum of all
    /// input frames. Audio data is copied channel by channel and sample by sample using `memcpy`
    ///
    /// - Example:
    /// ```swift
    /// let combinedBuffer = mergeBuffers([buffer1, buffer2, buffer3], format: myFormat)
    /// ```
    ///
    /// Time Complexity:
    ///    - Time: O(n), where n is the total number of frames in all buffers.
    ///   - Space: O(n), allocated for the merged buffer.
    ///
    /// 1. > Calculate total number of frames across all buffers.:
    ///  ```swift
    ///    let totalFrameCount = buffers.reduce(0) { $0 + Int($1.frameLength) }
    ///  ```
    /// - This is used to determine the final size of the merged buffer.
    ///
    /// 2. > Create a new buffer with enough capacity to hold all the frames.:
    /// ```swift
    /// let mergedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrameCount))!
    /// ```
    /// - Use the same format as input buffers
    ///
    /// 3.  > Set the actual frame length to match total frame count.:
    /// ```swift
    /// mergedBuffer.frameLength = AVAudioFrameCount(totalFrameCount)
    /// ```
    /// - This tells AVFoundation how much of the buffer is filled with valid audio
    ///
    /// 4. > Loop through each channel (mono = 1, stereo = 2, etc.).:
    /// ```swift
    /// for channel in 0..<Int(format.channelCount){
    /// var offset = 0
    /// ```
    /// - Tracks current write position in merged buffer.
    ///
    /// 5. > Copy buffer-by-buffer into merged buffer:
    /// ```swift
    /// for buffer in buffers {
    /// _ = buffer.frameLength
    /// memcpy(
    /// mergedBuffer.floatChannelData![channel] + offset,
    /// buffer.floatChannelData![channel],
    /// Int(buffer.frameLength) * MemoryLayout<Float>.size
    /// )
    /// ```
    /// - Copy current buffer audio data into the appropriate channel and offset
    ///
    /// ```swift
    /// offset += Int(buffer.frameLength)
    /// ```
    /// - Update the offset for the next buffer
    ///
    /// 6. > Return the fully merged buffer.:
    /// ```swift
    /// return mergedBuffer
    /// ```
    /// - Return the fully merged buffer
    ///
    /// >Tip: Always validate channel count and data existence (floatChannelData != nil)  before copying.
    ///
    /// >Warning: Writing outside bounds of `floatChannelData` leads to undefined behavior.
    private func mergeBuffers(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let totalFrameCount = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let mergedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrameCount))!
        mergedBuffer.frameLength = AVAudioFrameCount(totalFrameCount)
        
        for channel in 0..<Int(format.channelCount) {
            var offset = 0
            for buffer in buffers {
                _ = buffer.frameLength
                memcpy(
                    mergedBuffer.floatChannelData![channel] + offset,
                    buffer.floatChannelData![channel],
                    Int(buffer.frameLength) * MemoryLayout<Float>.size
                )
                offset += Int(buffer.frameLength)
            }
        }
        
        return mergedBuffer
    }
    
    /// This function takes a merged audio buffer (`AVAudioPCMBuffer`), converts its audio samples from
    /// `Float32` format to `Int16` PCM format, wraps it in a `Data` object, and sends it over an active WebSocket
    /// connection to the FastAPI backend server.
    /// - Parameters:
    ///   - buffer: The audio buffer to be sent (assumed to be a merged collection of small buffers).
    ///   - format: The audio format describing the buffer (sample rate, channel count, ect.).
    ///
    /// 1. > Extract the Channel Data.:
    /// ```swift
    /// guard let channelData = buffer.floatChannelData else {
    /// print("❌ Failed to encode buffer: no channel data")
    /// return
    /// ```
    /// - Ensures the buffer contains valid float channel data.
    /// - If not, exits early with an error log.
    ///
    /// 2. > Define Frame and Channel Info.:
    /// ```swift
    /// let numChannels = Int(format.channelCount)
    /// let frameCount = Int(buffer.frameLength)
    /// ```
    /// - Retrieves the number of audio channels (typically 1 for mono or 2 for stereo).
    /// - Gets how many frames are present (i.e., number of audio samples per channel).
    ///
    /// 3. > Convert Float32 to Int16PCM.:
    /// ```swift
    /// var int16Buffer = [Int16](repeating: 0, count: frameCount * numChannels)
    /// ```
    /// - Initializes a flat array to hold interleaved PCM samples (frame1L, frame1R, frame2L, frame2R...).
    /// ```swift
    /// for frame in 0..<frameCount {
    ///  for channel in 0..<numChannels {
    ///    let floatSample = channelData[channel][frame]
    ///    let clipped = max(-1.0, min(1.0, floatSample))
    ///    let intSample = Int16(clipped * Float(Int16.max))
    ///    int16Buffer[frame * numChannels + channel] = intSample
    ///  }
    /// }
    /// ```
    /// - For each sample:
    ///    - Extracts the float sample from the buffer.
    ///    - Clamps it to the valid range [-1.0, 1.0] to avoid overflow.
    ///    - Converts the value to 16-bit interger PCM format.
    ///    - Sotres it in interleaved` int16Buffer`.
    ///
    /// 4. >Create Data from Buffer.:
    /// ```swift
    /// let audioData = int16Buffer.withUnsafeBufferPointer { buffer in
    /// Data(buffer: buffer)
    ///}
    /// ```
    /// - Wraps the raw audio into a Data object so it can be sent over the network
    ///
    /// 5. >Send to Backend.:
    /// ```swift
    ///if webSocketTask?.state == .running {
    ///    webSocketTask?.send(.data(audioData)) { error in
    ///        if let error = error {
    ///            print("❌ Failed to send merged buffer: \(error)")
    ///        } else {
    ///            print("✅ Sent merged WAV chunk (\(audioData.count) bytes)")
    ///        }
    ///    }
    ///} else {
    ///    print("⚠️ WebSocket is not open.")
    ///}
    /// ```
    /// - If the Websocket is connected:
    ///   - Send the `audioData.`
    ///   - Log the results or any errors.
    /// - Otherwise, warn that the connection is unavailable.
    private func sendMergedBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else {
            print("❌ Failed to encode buffer: no channel data")
            return
        }
        
        let numChannels = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var int16Buffer = [Int16](repeating: 0, count: frameCount * numChannels)
        
        for frame in 0..<frameCount {
            for channel in 0..<numChannels {
                let floatSample = channelData[channel][frame]
                let clipped = max(-1.0, min(1.0, floatSample))
                let intSample = Int16(clipped * Float(Int16.max))
                int16Buffer[frame * numChannels + channel] = intSample
            }
        }
        
        let audioData = int16Buffer.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        
        
        if webSocketTask?.state == .running {
            webSocketTask?.send(.data(audioData)) { error in
                if let error = error {
                    print("❌ Failed to send merged buffer: \(error)")
                } else {
                    print("✅ Sent merged WAV chunk (\(audioData.count) bytes)")
                }
            }
        } else {
            print("⚠️ WebSocket is not open.")
        }
    }
    
    /// This function initializes or re-initializes a WebSocket connection to the FastAPI backend, ensuring a persistent
    /// bi-directional communication channel for audio streaming and analysis results.
    ///
    /// This private method is only accessible inside the ``AudioStreamUp`` class.
    ///
    /// 1. >Cancel Existing Connection if Needed.:
    /// ```swift
    /// if let existing = webSocketTask {
    ///  let reason = "Restarting connection".data(using: .utf8)
    ///  existing.cancel(with: .goingAway, reason: reason)
    ///  webSocketTask = nil
    ///}
    /// ```
    /// - Checks if an old WebSocket connection exists.
    /// - If yes:
    ///   - Send  close frame to the server with reason "Restarting connection".
    ///   - Cancels the connection cleanly using `.goingAway` status (code 1001)
    ///   - Sets `webSocketTask` to `nil` to fully reset the state.
    ///
    /// 2.  >Validate and Create URL.:
    ///```swift
    ///guard let url = URL(string: "wss://koma-fastapi-243442529943.us-east1.run.app/ws/audio") else {
    ///    print("❌ Invalid WebSocket URL")
    ///    return
    ///}
    ///```
    /// - Safely attempts to create a valid WebSocket Url.
    /// - If invalid (e.g., malformed or empty string), logs an error and exits the function.
    ///
    /// 3. >Create and Start WebSocket Task.:
    ///```swift
    ///let session = URLSession(configuration: .default)
    ///let task = session.webSocketTask(with: url)
    ///webSocketTask = task
    ///
    ///print("🔌 Connecting to WebSocket...")
    ///task.resume()
    ///```
    /// - Initializes a default `URLSession`.
    /// - Creates a WebSocket task using the valid URL.
    /// - Assigns the task to the webSocketTask property for reference.
    /// - Starts the connection by calling resume().
    ///
    /// 4. >Start Listening After Delay.:
    /// ```swift
    ///DispatchQueue.main.asyncAfter(deadline: .now() + 0.5){
    ///   self.listenForMessages()
    ///}
    /// ```
    /// - Adds a slight delay(0.5 seconds) before starting to listen fro incoming messages.
    ///   - Ensures the connection has time to establish before message handling begins
    /// - Calls `listenForMessages()` to begin receiving JSON messages from the backend like
    /// BPM, KEY and STRENGTH.
    ///
    /// >Important: This is called during class initialization ``init(completion:)``, or anytime you need to
    /// restart the WebSocket.
    ///
    /// >Warning: If the user loses Wi-Fi or cellular data, the connection might silently fail.
    ///
    private func connectWebSocket() {
        if let existing = webSocketTask {
            let reason = "Restarting connection".data(using: .utf8)
            existing.cancel(with: .goingAway, reason: reason)
            webSocketTask = nil
        }
        guard let url = URL(string: "wss://koma-fastapi-243442529943.us-east1.run.app/ws/audio") else {
            print("❌ Invalid WebSocket URL")
            return
        }
        
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        
        print("🔌 Connecting to WebSocket...")
        task.resume()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5){
            self.listenForMessages()
        }
    }
    
    /// This function continuously listens for incoming messages over a WebSocket connection. When a message is
    /// received (or failure occurs), it processes the results and recursively calls itself to keep the connection
    /// alive.
    ///
    /// - Calls `.receive` on the WebSocket to wait for the next message from the server.
    /// - `[weak self]` prevents retain cycles and avoids memory leaks in case the instance is
    /// deallocated while the connection is active.
    /// 1. >Start Listening on the WebSocket:
    /// ```swift
    ///webSocketTask?.receive { [weak self] result in
    /// ```
    /// - This line tells the WebSocket to wait for the next message.
    /// - It uses a closer with [weak self] to avoid memory leaks or retain cycles.
    ///
    /// 2. >Safely Unwrapping:
    /// ```swift
    ///        guard let self = self else { return }
    /// ```
    /// Ensures self still exists and if not, exits early to avoid a crash.
    ///
    /// 3. >Handle Results from WebSocket.:
    /// ```swift
    ///switch result {
    /// ```
    /// - `result` contains either:
    ///  - `.success(message)` - a message was received.
    ///  - `.failure(error)` - something went wrong.
    ///
    /// 4. >Handle Errors.:
    ///  ```swift
    ///case .failure(let error):
    ///    print("❌ WebSocket receive error: \(error)")
    ///  ```
    ///  If something goes wrong during receiving, log the error.
    ///
    ///  ```swift
    ///if case URLError.networkConnectionLost = error {
    ///    DispatchQueue.main.asyncAfter(deadline: .now() + 1){
    ///        self.connectWebSocket()
    ///    }
    ///}
    ///```
    ///if the error was `networkConnectionLost`, attemt to reconnect after 1 second.
    ///
    /// 5. >Handle Received Messages.:
    /// ```swift
    ///case .success(let message):
    ///    switch message {
    /// ```
    /// if a message was received successfully, check its type.
    ///
    ///6. >Handle String Message (Expected Case).:
    ///```swift
    ///case .string(let json):
    ///    if let data = json.data(using: .utf8) {
    ///        do {
    ///            let response = try JSONDecoder().decode([String: String].self, from: data)
    ///```
    /// IF the server sent a JSON string, try to decode it. Then converts the string into Data and decode it into a
    /// [String:String] dictionary.
    ///
    /// 7. >Extract Bpm, Key, Status.:
    /// ```swift
    ///let bpm = response["bpm"] ?? "Unknown"
    ///let key = response["key"] ?? "Unknown"
    ///let status = response["status"] ?? "Detected"
    /// ```
    /// Retrieves values from the dictionary with default fallbacks like "Unkown" and "Detected".
    ///
    /// 8. >Call Completion Handler.:
    /// ```swift
    ///DispatchQueue.main.async {
    ///    self.completion(bpm, key, status)
    ///}
    /// ```
    ///Execute the callback to update the UI with the results on the main thread.
    ///
    ///9. > Handle Unexpected Binary Data and Unknow Message Types.:
    ///```swift
    ///case .data:
    ///    print("⚠️ Unexpected binary message")
    ///@unknown default:
    ///    break
    ///```
    /// - If binary data is received, log a warning.
    /// Handles new cases of WebSocketMessage that may be added later
    ///
    /// 10. >Restart The Listening Loop.:
    /// ```swift
    /// self.listenForMessages()
    /// ```
    /// After finishing one message, restart the listening process to wait for the next
    ///
    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                if case URLError.networkConnectionLost = error {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1){
                        self.connectWebSocket()
                    }
                }
            case .success(let message):
                switch message {
                case .string(let json):
                    if let data = json.data(using: .utf8) {
                        do {
                            let response = try JSONDecoder().decode([String: String].self, from: data)
                            let bpm = response["bpm"] ?? "Unknown"
                            let key = response["key"] ?? "Unknown"
                            let status = response["status"] ?? "Detected"
                            DispatchQueue.main.async {
                                self.completion(bpm, key, status)
                            }
                        } catch {
                            print("❌ JSON decode error: \(error)")
                        }
                    }
                case .data:
                    print("⚠️ Unexpected binary message")
                @unknown default:
                    break
                }
            }
            
            self.listenForMessages()
        }
    }
    
    /// This method is used to manually terminate the audio capture session and WebSocket connection.
    /// It ensures that all resources are released cleanly.
    ///
    /// 1. >Removing Audio Tap.:
    /// ```swift
    ///audioEngine.inputNode.removeTap(onBus: 0)
    /// ```
    /// This removes the audio tap from the input bus. It is important to stop audio capture and prevent
    /// further data from flowing into your app.
    ///
    /// 2. >Stop AVAudioEngine.:
    /// ```swift
    ///if audioEngine.isRunning {
    ///    audioEngine.stop()
    ///}
    /// ```
    ///Stops the `AVAudioEngine` only if it's actively running. This ensures safe shutdown
    ///and prevents calling ``stop()`` unnecessarily.
    ///
    /// 3. Graceful closure of WebSocket
    /// ```swift
    ///webSocketTask?.cancel(with: .goingAway, reason: nil)
    /// ```
    ///Gracefully closes the WebSocket using the `.goingAway` to close code. This is a standard way
    ///to indicate that the client is intentionally ending the session.
    ///```swift
    ///webSocketTask = nil
    ///```
    ///Cleans up the WebSocket reference to free memory and allow the object ot be reused or deallocated.
    ///4.>deinit.:
    ///```swift
    ///audioEngine.stop()
    ///webSocketTask?.cancel(with: .goingAway, reason: nil)
    ///```
    ///This destructor is automatically called when the ``AudioStreamUp`` instance is being deallocated.
    ///- It stops the audio engine again as a safety net in case ``stop()`` was never called manually.
    ///- Ensures the WebSocket is closed even if the instance is destroyed without explicity calling ``stop()``
    private var isStopped = false
    //clears buffers,cancels the timer, and releases websocket audio
    //update doc-c
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        print("Stopping audio stream...")
        
        detectionTimer?.invalidate()
        detectionTimer = nil
        
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        bufferQueueLock.sync {
            audioBufferQueue.removeAll()
            totalFrameCount = 0
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
            print("AVAudioSession deactivated")
        } catch {
            print("Error deactivating AVAudioSession: \(error)")
        }
    }
    
    deinit {
        print("Deinitialiizing AudioStreamUp...")
        stop()
    }
}
