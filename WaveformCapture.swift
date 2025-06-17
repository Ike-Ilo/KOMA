import AVFoundation

class WaveformCapture: ObservableObject {
    private let audioEngine = AVAudioEngine()
    @Published var samples: [Float] = []

    init() {
        startAudio()
    }

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("❌ Session error: \(error)")
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
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

        do {
            try audioEngine.start()
            print("🎧 WaveformCapture started")
        } catch {
            print("❌ Engine error: \(error)")
        }
    }

    deinit {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }
}

