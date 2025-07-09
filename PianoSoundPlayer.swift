//  Untitled.swift
//  KOMA
//  Created by ike iloegbu on 5/20/25.
//

import AVFoundation
import Foundation

class PianoSoundPlayer: ObservableObject {
    private let engine: AVAudioEngine
    private var audioBuffers: [String: AVAudioPCMBuffer] = [:]
    private var format: AVAudioFormat?

    init(sharedEngine: AVAudioEngine) {
        self.engine = sharedEngine
        loadSamples()
    }

    private func loadSamples() {
        let noteNames = ["C4", "D4", "E4", "F4", "G4", "A4", "B4"]  // Add all your notes here
        for note in noteNames {
            guard let url = Bundle.main.url(forResource: note, withExtension: "wav") else {
                print("❌ Missing sample for \(note)")
                continue
            }
            
            do {
                let file = try AVAudioFile(forReading: url)
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                )!
                try file.read(into: buffer)
                audioBuffers[note] = buffer
            } catch {
                print("❌ Failed to load \(note): \(error)")
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

        playerNode.scheduleBuffer(buffer, at: nil, options: []) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.engine.detach(playerNode)
            }
        }
        playerNode.volume = 5.0
        playerNode.play()
    }
}
