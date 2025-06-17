//  PythonBridge.swift
//  Created by ike iloegbu on 5/5/25.
//
import Foundation
import Combine
#if canImport(PythonKit)
import PythonKit
#endif
import AVFoundation

class PythonBridge: ObservableObject, PythonBridgeProtocol {
    @Published var bpm: String = "Unknown"
    @Published var keysig: String = "Unknown"
    @Published var samples: [Float] = []
    @Published var recordStatus: String = "Not Detecting"
    
    
    private var audioStream: AudioStreamUp?
    
    init() {
#if os(macOS)
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            setupPython()
        }
#endif
    }
#if os(macOS)
    private func setupPython() {
        let sys = Python.import("sys")
        sys.path.append(PythonObject("/Users/ikeiloegbu/Documents/SOFTWARE DESIGN/Konekt Music Anaylizer/"))
        _ = Python.import("Music_Analyzer")
    }
#endif
    
    
    func startRecording() {
        if recordStatus == "Detecting"{
            print("Already detecting")
            return
        }
        
        recordStatus = "Detecting"
        audioStream = AudioStreamUp { bpm, key, status in
            DispatchQueue.main.async {
                self.bpm = bpm
                self.keysig = key
                self.recordStatus = status
                
                print("🎯 Detected BPM = \(bpm), Key = \(key), Status = \(status)")
                
                if status == "Detected" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5){
                        if self.recordStatus == "Detected" {
                            self.stopRecording()
                            self.recordStatus = "Detected"
                            print("🛑 Audio stream stopped after detection.")
                        }
                        
                    }
                }
    
            }
        }

    }
    func stopRecording() {
        audioStream?.stop()
        print("Recording manually stopped")
        audioStream = nil
        recordStatus = "Not Detecting"
    }
}
