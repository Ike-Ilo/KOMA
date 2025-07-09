import AVFoundation
import Accelerate
import Combine

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
    let audioEngine = AVAudioEngine()
    /// Persistent connection to the backend
    private var webSocketTask: URLSessionWebSocketTask?
    /// Times out audio collection after 5 seconds for consistent detection time.
    private var detectionTimer: Timer?
    
    private let webSocketLock = DispatchQueue(label: "WebSocketLock")

    /// track how many audio frames have been collected so far during a streaming session.
    private var totalFrameCount = 0
    /// Controls batching: 5 seconds of audio at 44.1kHz.
    private let targetFrameCount = 44100 * 7
    
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
    
    private var lastSampleUpdate = Date()
    
    private var isTapInstalled = false
    
    private let processingQueue = DispatchQueue(label: "audio.processing.queue", qos: .userInitiated)

    let waveformBuffer = WaveformBuffer()


    
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
    }
    
    func startServices() {
        self.connectWebSocket()
        self.observeAudioInterruptions()

    }
    
    
    func startWaveformStream() {
        if audioEngine.isRunning {
            print("🎧 Audio engine already running")
            return
        }

    }
    func prepare() {
        bufferQueueLock.sync {
            DispatchQueue.main.async {  // ✅ AVAudioSession must be on main thread
                self.startAudioSession()
            }
        }
    }
    
    private func safeBufferAccess<T>(_ work: () -> T) -> T {
        bufferQueueLock.sync {
            return work()
        }
    }
        //Notified when another session interrupts the stream
    private func observeAudioInterruptions() {
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
            if type == .began {
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
        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth])
                try session.setActive(true)
                print("✅ AVAudioSession activated")
            } catch {
                print("❌ Audio session error: \(error)")
                return
            }
            
            // ✅ Now inside main thread, lock tap installation
            self.bufferQueueLock.sync {
                let inputNode = self.audioEngine.inputNode
                let format = inputNode.inputFormat(forBus: 0)

                if self.isTapInstalled {
                    print("🔁 Tap already installed, skipping tap setup.")
                } else {
                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        guard let self = self else { return }

                        // ✅ Throttled Waveform Capture (Runs Continuously, Max 10 FPS)
                        if Date().timeIntervalSince(self.lastSampleUpdate) > 0.2 {
                            self.lastSampleUpdate = Date()
                            
                            if let channelData = buffer.floatChannelData?[0] {
                                let frameLength = Int(buffer.frameLength)
                                let downsampled = stride(from: 0, to: frameLength, by: 10).map { i in
                                    min(1.0, abs(channelData[i]) * 10)
                                }
                                
                                DispatchQueue.main.async {
                                    self.samples = downsampled
                                }
                            }
                        }

                        // ✅ Detection Buffering (Only Runs When Active)
                        let detectionActive = self.safeBufferAccess { self.isDetectionActive }
                        if detectionActive {
                            let bufferCopy = self.copyBuffer(buffer)
                            self.processingQueue.async {
                                guard let copiedBuffer = bufferCopy else { return }
                                self.enqueueAndBatchBuffer(copiedBuffer, format: format)
                            }
                        }
                    }

                    self.isTapInstalled = true
                    print("🎙️ Installed audio tap")
                }
            }

            // ✅ Safely start the engine (can be outside lock per Apple docs)
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                    print("✅ Audio Engine Started")
                } catch {
                    print("❌ Audio Engine Failed to Start: \(error)")
                }
            }
        }
    }


    
    func performDetectionCycle() {
        var buffersToMerge: [AVAudioPCMBuffer] = []
        var format: AVAudioFormat?

        bufferQueueLock.sync {
            if !audioBufferQueue.isEmpty {
                let maxBuffers = min(audioBufferQueue.count, 220)
                let clippedQueue = Array(audioBufferQueue.prefix(maxBuffers))
                format = clippedQueue.first?.format
                buffersToMerge = clippedQueue
                audioBufferQueue.removeAll()
                totalFrameCount = 0
            }
        }

        guard let fmt = format, !buffersToMerge.isEmpty else {
            print("❌ Cannot perform detection — format or buffers are nil.")
            return
        }
        let stopped = bufferQueueLock.sync { self.isStopped }
        guard !stopped else { return }
        
        processingQueue.async {
            let mergedBuffer = self.mergeBuffers(buffersToMerge, format: fmt)
            self.sendMergedBuffer(mergedBuffer, format: fmt)
        }
    }
    

    private func enqueueAndBatchBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        safeBufferAccess {
            self.audioBufferQueue.append(buffer)
            self.totalFrameCount += Int(buffer.frameLength)

            if self.totalFrameCount >= targetFrameCount {
                let buffersToMerge = self.audioBufferQueue
                let formatToUse = buffer.format
                self.audioBufferQueue.removeAll()
                self.totalFrameCount = 0

                self.processingQueue.async {
                    let mergedBuffer = self.mergeBuffers(buffersToMerge, format: formatToUse)
                    self.sendMergedBuffer(mergedBuffer, format: formatToUse)
                    
                    DispatchQueue.main.async {
                        self.safeBufferAccess {
                            self.audioBufferQueue.removeAll()
                        }
                    }
                }
            }
        }
    }


  
    private func mergeBuffers(_ buffers: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let totalFrameCount = buffers.reduce(0) { $0 + Int($1.frameLength) }

        guard let mergedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrameCount)) else {
            fatalError("❌ Failed to allocate merged buffer.")
        }

        mergedBuffer.frameLength = AVAudioFrameCount(totalFrameCount)

        guard let mergedChannels = mergedBuffer.floatChannelData else {
            fatalError("❌ Merged buffer has no channel data.")
        }

        let channelCount = Int(format.channelCount)

        for channel in 0..<channelCount {
            var offset = 0

            for buffer in buffers {
                let frameLength = Int(buffer.frameLength)

                guard frameLength > 0,
                      let srcChannels = buffer.floatChannelData,
                      channel < Int(buffer.format.channelCount) else {
                    print("⚠️ Skipping buffer: bad format or empty.")
                    continue
                }

                let src = srcChannels[channel]
                let dst = mergedChannels[channel]

                // ✅ Bounds check before copying
                if offset + frameLength > Int(mergedBuffer.frameCapacity) {
                    print("⚠️ Skipping buffer: would overflow merged buffer.")
                    break
                }

                // ✅ Safe copy
                memcpy(dst + offset, src, frameLength * MemoryLayout<Float>.size)
                offset += frameLength
            }
        }

        return mergedBuffer
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 && frameLength <= Int(buffer.frameCapacity) else {
            print("❌ Invalid frame length in copyBuffer")
            return nil
        }

        guard buffer.format.commonFormat == .pcmFormatFloat32 else {
            print("❌ Only float32 buffers are supported")
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            print("❌ Invalid channel count")
            return nil
        }

        guard let format = AVAudioFormat(commonFormat: buffer.format.commonFormat,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount,
                                         interleaved: false),
              let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            print("❌ Failed to allocate buffer copy")
            return nil
        }

        newBuffer.frameLength = buffer.frameLength

        guard let src = buffer.floatChannelData, let dst = newBuffer.floatChannelData else {
            print("❌ Missing channel data")
            return nil
        }

        for i in 0..<channelCount {
            memcpy(dst[i], src[i], frameLength * MemoryLayout<Float>.size)
        }

        return newBuffer
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
        webSocketLock.sync {
            if let existing = self.webSocketTask {
                let reason = "Restarting connection".data(using: .utf8)
                existing.cancel(with: .goingAway, reason: reason)
                self.webSocketTask = nil
            }
        }
        
        guard let url = URL(string: "wss://koma-fastapi-243442529943.us-east1.run.app/ws/audio") else {
            print("❌ Invalid WebSocket URL")
            return
        }
        
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        
        webSocketLock.sync {
            self.webSocketTask = task
        }
        
        print("🔌 Connecting to WebSocket...")
        task.resume()
        
        processingQueue.asyncAfter(deadline: .now() + 0.05) {
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
        var task: URLSessionWebSocketTask?
        webSocketLock.sync {
            task = self.webSocketTask
        }
        
        task?.receive { [weak self] result in
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
                                
                                if status == "Detected" || status == "Success" {
                                    print("✅ Detection complete, stopping detection cycle")
                                    self.stopDetectionOnly()
                                }
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
    
    private var isDetectionActive: Bool = false
    
    func stop() {
        bufferQueueLock.sync {
            guard !isStopped else { return }
            isStopped = true
            print("Stopping detection cycle...")

            detectionTimer?.invalidate()
            detectionTimer = nil

            DispatchQueue.main.async {
                self.safeBufferAccess {
                    self.audioBufferQueue.removeAll()
                    self.totalFrameCount = 0
                }

                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                print("🛑 WebSocket closed")
            }
        }
    }



    

    func startDetection() {
        safeBufferAccess {
            isDetectionActive = true
            print("🔍 Starting manual detection")
            self.audioBufferQueue.removeAll()
            self.totalFrameCount = 0
        }
    }
    func stopDetectionOnly() {
        safeBufferAccess {
            detectionTimer?.invalidate()
            detectionTimer = nil
            isDetectionActive = false
            audioBufferQueue.removeAll()
            totalFrameCount = 0
            
            DispatchQueue.main.async {
                self.samples = [] // ✅ flush waveform data
            }
        }
    }
    deinit {
        stop()
    }
}

class AudioStreamHolder: ObservableObject {
    @Published var stream: AudioStreamUp?
    @Published var samples: [Float] = []

    private var cancellables = Set<AnyCancellable>()
    
    let pybridge: AnyPythonBridge
    
    init(pybridge: AnyPythonBridge) {
        self.pybridge = pybridge
        
        self.stream = AudioStreamUp { bpm, key, status in
            print("📬 Received from backend: BPM = \(bpm), Key = \(key), Status = \(status)")
            
            DispatchQueue.main.async {
                // ✅ Set values directly on the AnyPythonBridge instance
                self.pybridge.bpm = bpm
                self.pybridge.keysig = key
                self.pybridge.recordStatus = status
                
            }
        }
        self.stream?.prepare()
        self.stream?.$samples
            .receive(on: DispatchQueue.main)
            .sink { [weak self] samples in
                self?.samples = samples
            }
            .store(in: &cancellables)
    }
    func startAllServices() {
        stream?.startServices()
    }
    
    func prepareAudioStream() {
        stream?.prepare()
    }
    
    
    // ✅ Warm up audio engine early
    //        self.stream = stream
    //        DispatchQueue.global(qos: .userInitiated).async {
    //            // Slight delay, still on background thread
    //            usleep(500_000)  // 0.5s
    //            stream.prepare()
    
    
    func startDetection() {
        stream?.startDetection()
    }
    
    func stopDetectionOnly() {
        stream?.stopDetectionOnly()
    }
    
    func restartServices() {
        stream?.startServices()  // ✅ Restart WebSocket + observers
//        stream?.startDetection()  // ✅ Start detection
    }

    private func requestMicrophoneAccessAndStartDetection() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted {
                    self.prepareAudioStream()  // ✅ Prepare only after permission
                    self.startDetection()
                } else {
                    print("❌ Microphone access denied")
                }
            }
        }
    }
}
    
class WaveformBuffer: ObservableObject {
    private let lock = NSLock()
    private var samples: [Float] = Array(repeating: 0, count: 64)
    
    func update(with newSamples: [Float]) {
        lock.lock()
        samples = newSamples
        lock.unlock()
    }
    
    func currentSamples() -> [Float] {
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }
}

