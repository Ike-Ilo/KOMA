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
    @Published var recordStatus: String = "Not Detecting"
    weak var audioStreamHolder: AudioStreamHolder?
    
    init() {
#if os(macOS)
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            setupPython()
        }
#endif
    }
    func startRecording() {
        audioStreamHolder?.startDetection()
    }
    
    func stopRecording() {
        audioStreamHolder?.stopDetectionOnly()
    }

#if os(macOS)
    private func setupPython() {
        let sys = Python.import("sys")
        sys.path.append(PythonObject("/Users/ikeiloegbu/Documents/SOFTWARE DESIGN/Konekt Music Anaylizer/"))
        _ = Python.import("Music_Analyzer")
    }
#endif
    
    
}
