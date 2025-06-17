//  Untitled.swift
//  KOMA
//  Created by ike iloegbu on 5/20/25.
//

import AVFoundation

class PianoSoundPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private var audioBuffers: [String: AVAudioPCMBuffer] = [:]
    private var format: AVAudioFormat?

    init() {
        setupAudioSession()
        loadSamples()
    }

    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("❌ Audio session error: \(error)")
        }
    }

    private func loadSamples() {
        let notes = (1..<8).flatMap { octave in
            ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"].map {"\($0)\(octave)"}
        }

        for note in notes {
            guard let url = Bundle.main.url(forResource: note, withExtension: "aiff") else {
                print("Missing sample for \(note)")
                continue
            }

            do {
                let file = try AVAudioFile(forReading: url)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                audioBuffers[note] = buffer
                format = file.processingFormat
            } catch {
                print("Error loading buffer for \(note): \(error)")
            }
        }
    }

    func play(note: String) {
        guard let buffer = audioBuffers[note], let format = format else {
            print("No buffer for note \(note)")
            return
        }

        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Failed to start engine: \(error)")
                return
            }
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: []) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.engine.detach(playerNode)
            }
        }
        playerNode.volume = 5.0
        playerNode.play()
    }
}
