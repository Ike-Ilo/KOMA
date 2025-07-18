// uvicorn main:app --reload --host 0.0.0.0 --port 8080
//  ContentView.swift
//  KOMA 
//  Created by ike iloegbu on 5/9/25.

import SwiftUI
import Combine

// MARK: - Protocol

/// ]A protocol that defines the interface between SwiftUI views and a backend audio analysis service (e.g., Python-based).
///
/// Conforming types are expected to serve as a bridge that can start and stop audio detection,
/// and expose the latest BPM, key signature, and recording status.
///
/// This protocol is ideal for use with SwiftUI views that observe the `ObservableObject` to
/// dynamically reflect real-time audio analysis results.
///
/// - Note: This protocol is typically implemented by classes handling audio processing
///         or backend communication (e.g., over WebSockets or gRPC).
///
protocol PythonBridgeProtocol: ObservableObject {

    var bpm: String { get }
    var keysig: String { get }
    var recordStatus: String { get }
    func startRecording()
    func stopRecording()
}

// MARK: - Mock Bridge

class MockPythonBridge: PythonBridgeProtocol {
    @Published var bpm: String = "120"
    @Published var keysig: String = "Fminor"
    @Published var recordStatus: String = "Preview Mode"
    func startRecording() {}
    func stopRecording() {}
}

// MARK: - AnyPythonBridge

class AnyPythonBridge: PythonBridgeProtocol {
    @Published var bpm: String = "Unknown"
    @Published var keysig: String = "Unknown"
    @Published var recordStatus: String = ""

    private let _startRecording: () -> Void
    private let _stopRecording: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init<Bridge: PythonBridgeProtocol>(_ bridge: Bridge) {
        _startRecording = bridge.startRecording
        _stopRecording = bridge.stopRecording
        
        bridge.objectWillChange
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.bpm = bridge.bpm
                self.keysig = bridge.keysig
                self.recordStatus = bridge.recordStatus
            }
            .store(in: &cancellables)
    }

    func startRecording() { _startRecording() }
    func stopRecording() { _stopRecording() }
}

// MARK: - WaveformView

struct WaveformView: View {
    var samples: [Float]

    var body: some View {
        GeometryReader { geo in
            let safeSamples = samples // ✅ Defensive copy
            let height = geo.size.height
            let width = geo.size.width / CGFloat(max(safeSamples.count, 1))
            
            HStack(alignment: .center, spacing: 1) {
                ForEach(safeSamples.indices, id: \.self) { i in
                    let amp = CGFloat(safeSamples[i])
                    let safeAmp = amp.clampToRange(0...1)
                    let barHeight = max(1, safeAmp * height)
                    let safeHue = Double(1 - safeAmp).clamped(to: 0...1)
                    let finalHue = safeHue.isFinite ? safeHue : 0.0
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(hue: finalHue, saturation: 0.9, brightness: 1),
                                    Color.blue.opacity(0.6)
                                ]),
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: width, height: barHeight)
                        .cornerRadius(width / 2)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
                        .animation(.easeOut(duration: 0.05), value: safeSamples[i])
                }
            }
        }
    }
}


extension BinaryFloatingPoint {
    func clampToRange(_ limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}


struct ContentView: View {
    @State private var isRecording = false
    @State private var touchedNotes: Set<String> = []
    @State private var currentDetectedKey: String = ""
    @StateObject private var pianoPlayer: PianoSoundPlayer
    @StateObject private var audioStreamHolder: AudioStreamHolder
//    @StateObject private var waveformCapture = WaveformCapture()
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDetectionActive = false
    @State private var currentBPM: String = ""
    @State private var currentKeySig: String = ""
    @State private var bpmCancellable: AnyCancellable?
    @State private var keyCancellable: AnyCancellable?
    @State private var waveformTimer: Timer?
    @State private var samples: [Float] = []

    
    init() {
        let pybridge = PythonBridge()
        let holder = AudioStreamHolder(pybridge: AnyPythonBridge(pybridge))
        pybridge.audioStreamHolder = holder
        _audioStreamHolder = StateObject(wrappedValue: holder)
        
        guard let engine = holder.stream?.audioEngine else {
            fatalError("Audio engine not initialized")
        }
        _pianoPlayer = StateObject(wrappedValue: PianoSoundPlayer(sharedEngine: engine))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                
                // ✅ BPM + Key + Logo
                HStack {
                    VStack(alignment: .leading) {
                        Text("BPM:")
                            .font(.caption)
                            .foregroundColor(Color(.secondaryLabel))
                        Text(currentBPM)
                            .font(.title3)
                            .foregroundColor(Color.accentColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack {
                        Image("konekt_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 60)
                            .padding(.top, 4)
                    }
                    
                    VStack(alignment: .trailing) {
                        Text("KEY:")
                            .font(.caption)
                            .foregroundColor(Color.secondary)
                        Text(currentKeySig)
                            .font(.title3)
                            .foregroundColor(Color.accentColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal)
                .padding(.top, 40)
                
                // ✅ Waveform Display
                WaveformView(samples: audioStreamHolder.samples)
                    .frame(height: 100)
                    .padding(.bottom, 10)
                
                // ✅ Detection Button
                VStack(spacing: 12) {
                    Button(action: {
                        print("Toggle tapped - isRecording:", isRecording)
                        
                        // ✅ Defer ALL state changes to next runloop cycle
                        guard !isRecording && !isDetectionActive else { return }
                        

                        isRecording = true
                        isDetectionActive = true
                        audioStreamHolder.pybridge.recordStatus = "Listening..."
                        audioStreamHolder.pybridge.startRecording()
                        audioStreamHolder.startDetection()
                        
                    }) {
                        Text(isRecording ? "Stop Detecting" : "Start Detection")
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: isRecording ? [Color.gray, Color(white: 0.5)] : [Color.blue, Color.cyan]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                        )
                                        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 3)
                                    
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: [Color.white.opacity(0.35), Color.clear]),
                                                startPoint: .top,
                                                endPoint: .center
                                            )
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            )
                    } .disabled(isDetectionActive)

                }
                .padding(.bottom, 60)
                
                // ✅ Piano Interface
                PianoRollView(
                    keySignature: currentDetectedKey,
                    touchedNotes: $touchedNotes,
                    soundPlayer: pianoPlayer
                )
                .frame(height: 200)
            }
            .padding()
            .ignoresSafeArea(.keyboard)
            .onAppear {
                audioStreamHolder.restartServices()

                bpmCancellable = audioStreamHolder.pybridge.$bpm
                    .receive(on:DispatchQueue.main)
                    .sink { bpm in
                        currentBPM = bpm
                        
                    }
                
                keyCancellable = audioStreamHolder.pybridge.$keysig
                    .receive(on:DispatchQueue.main)
                    .sink { keysig in
                        currentKeySig = keysig
                        let cleaned = cleanKeySignature(keysig)
                        if cleaned.contains("Major") || cleaned.contains("Minor") {
                            currentDetectedKey = cleaned
                        } else {
                            currentDetectedKey = ""  // optional fallback
                        }
                    }
                waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    self.samples = audioStreamHolder.stream?.waveformBuffer.currentSamples() ?? []
                }
            }
            .onDisappear {
                bpmCancellable?.cancel()
                keyCancellable?.cancel()
                waveformTimer?.invalidate()
                waveformTimer = nil
            }
            .onReceive(
                audioStreamHolder.pybridge.$recordStatus
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
            ) { status in
                guard isRecording else { return }
                if ["Detected", "Timeout"].contains(status) {
                    
                        stopDetection()
                    
                }
            }
        }
    }
        // ✅ Start detection session
    private func startDetection() {
        DispatchQueue.main.async {
            isRecording = true
            guard !isDetectionActive else { return }
            isDetectionActive = true
        }
        audioStreamHolder.pybridge.recordStatus = "Listening..."

        // Start recording immediately, but wait 5s before calling detection
        audioStreamHolder.pybridge.startRecording()

        // Trigger backend detection cycle
        DispatchQueue.global(qos: .userInitiated).async {
            audioStreamHolder.startDetection()
        }
    }
        
        // ✅ Stop manually
    private func stopDetection() {
        DispatchQueue.main.async {
            isRecording = false
            isDetectionActive = false
            
            // Start recording immediately, but wait 5s before calling detection
            audioStreamHolder.pybridge.stopRecording()
        }
            
            // Trigger backend detection cycle
        DispatchQueue.global(qos: .userInitiated).async {
            audioStreamHolder.stopDetectionOnly()
        }
    }
}
    
    // MARK: - Piano Roll View
    
    struct PianoRollView: View {
        let keySignature: String
        @Binding var touchedNotes: Set<String>
        let soundPlayer: PianoSoundPlayer
        @Environment(\.colorScheme) private var colorScheme
        @AppStorage("isDarkMode") private var isDarkMode = false
        
        var body: some View {
            let cleaned = cleanKeySignature(keySignature)
            let notes = notesInKeySignature(cleaned)
            
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    GeometryReader { geometry in
                                        let totalWhiteKeys = 86  // Usually 52 white keys
                                        let c4Index = 39  // Approx. index of C4
                                        let keyWidth = geometry.size.width / CGFloat(totalWhiteKeys)
                                        let c4X = CGFloat(c4Index) * keyWidth
                                        
                                        Text("KOMA")
                                            .font(.headline)
                                            .foregroundColor(.blue)
                                            .shadow(radius: 1)
                                            .position(x: c4X, y: 20)  // Adjust y for positioning near the top
                                    }
                                    
                                    Spacer()
                                    
                                    Toggle(isOn: $isDarkMode) {
                                        Text("")
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                                    .labelsHidden()
                                    .padding(.trailing)
                                }
                                
                                ZStack(alignment: .topLeading) {
                                    WhiteKeyRow(
                                        highlightedNotes: notes,
                                        touchedNotes: $touchedNotes,
                                        soundPlayer: soundPlayer
                                    )
                                    BlackKeyRow(
                                        highlightedNotes: notes,
                                        touchedNotes: $touchedNotes,
                                        soundPlayer: soundPlayer
                                    )
                                }
                            }
                        }
                        .padding()
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.5), lineWidth: 3)
                        )
                        .background(colorScheme == .dark ? Color.black.opacity(0.7) : Color.clear)
                        .padding(.horizontal)
                    }
                    .onAppear {
                        withAnimation {
                            proxy.scrollTo("C4", anchor: .center)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - White Key Row
    
    struct WhiteKeyRow: View {
        let whiteKeys = ["C", "D", "E", "F", "G", "A", "B"]
        let highlightedNotes: Set<String>
        @Binding var touchedNotes: Set<String>
        let soundPlayer: PianoSoundPlayer
        @Environment(\.colorScheme) private var colorScheme
        
        var body: some View {
            HStack(spacing: 0) {
                ForEach(1..<8, id: \.self) { octave in
                    ForEach(whiteKeys, id: \.self) { key in
                        let note = "\(key)"
                        let id = "\(note)\(octave)"
                        VStack(spacing: 0) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: colorScheme == .dark ? [Color(white: 0.4), Color(white: 0.2)] : [Color.white, Color(white: 0.85)]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.4), lineWidth: 1)
                                    )
                                    .shadow(color: colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
                                
                                if touchedNotes.contains(id) {
                                    Color.gray.opacity(colorScheme == .dark ? 0.6 : 0.4).cornerRadius(4)
                                } else if highlightedNotes.contains(note.uppercased()) {
                                    Color.blue.opacity(colorScheme == .dark ? 0.4 : 0.2).cornerRadius(4)
                                }
                            }
                            .frame(width: 40, height: 180)
                            .onTapGesture {
                                touchedNotes.insert(id)
                                soundPlayer.play(note: id)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    touchedNotes.remove(id)
                                }
                            }
                            
                            Text(id)
                                .font(.caption2)
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .frame(width: 40, height: 20)
                        }
                        .id(id)
                    }
                }
            }
        }
    }
    
    // MARK: - Black Key Row
    
    struct BlackKeyRow: View {
        let blackKeys = [("C#", 30), ("D#", 70), ("", 0), ("F#", 150), ("G#", 190), ("A#", 230), ("", 0)]
        let highlightedNotes: Set<String>
        @Binding var touchedNotes: Set<String>
        let soundPlayer: PianoSoundPlayer
        @Environment(\.colorScheme) private var colorScheme
        
        var body: some View {
            ZStack {
                ForEach(1..<8, id: \.self) { octave in
                    let baseX = CGFloat(octave - 1) * 280
                    ForEach(0..<blackKeys.count, id: \.self) { i in
                        let (note, offset) = blackKeys[i]
                        let id = "\(note)\(octave)"
                        if note != "" {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            gradient: Gradient(colors: colorScheme == .dark ? [Color(white: 0.8), Color(white: 0.4)] : [Color(white: 0.1), Color(white: 0.4)]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.5), lineWidth: 0.5)
                                    )
                                    .shadow(color: colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.5), radius: 2, x: 0, y: 2)
                                
                                if touchedNotes.contains(id) {
                                    Color.gray.opacity(0.5).cornerRadius(3)
                                } else if highlightedNotes.contains(note.uppercased()) {
                                    Color.purple.opacity(0.3).cornerRadius(3)
                                }
                            }
                            .frame(width: 25, height: 120)
                            .offset(x: baseX + CGFloat(offset), y: 0)
                            .onTapGesture {
                                touchedNotes.insert(id)
                                soundPlayer.play(note: id)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    touchedNotes.remove(id)
                                }
                            }
                            .id(id)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Key Signature Map
    
    func notesInKeySignature(_ keysig: String) -> Set<String> {
        switch keysig {
        case "C Major": return ["C", "D", "E", "F", "G", "A", "B"]
        case "G Major": return ["G", "A", "B", "C", "D", "E", "F#"]
        case "F# Major": return ["F#", "G#", "A", "B", "C#", "D#", "F"]
        case "D Major": return ["D", "E", "F#", "G", "A", "B", "C#"]
        case "C# Major": return ["C#", "D#", "E", "F#", "G#", "A#", "C"]
        case "A Major": return ["A", "B", "C#", "D", "E", "F#", "G#"]
        case "Ab Major": return ["G#", "A#", "B", "C#", "D#", "F", "G"]
        case "E Major": return ["E", "F#", "G#", "A", "B", "C#", "D#"]
        case "Eb Major": return ["D#", "F", "G", "G#", "A#", "C", "D"]
        case "B Major": return ["B", "C#", "D#", "E", "F#", "G#", "A#"]
        case "F Major": return ["F", "G", "A", "A#", "C", "D", "E"]
        case "Bb Major": return ["A#", "C", "D", "Eb", "F", "G", "A"]
        case "A Minor": return ["A", "B", "C", "D", "E", "F", "G"]
        case "Ab Minor": return ["G#", "A#", "C", "C#", "D#", "F", "G"]
        case "E Minor": return ["E", "F#", "G", "A", "B", "C", "D"]
        case "Eb Minor": return ["D#", "F", "F#", "G#", "A#", "B", "C#"]
        case "B Minor": return ["B", "C#", "D", "E", "F#", "G", "A"]
        case "Bb Minor": return ["A#", "C", "D#", "F#", "F", "F#", "G#", "A"]
        case "F Minor": return ["F", "G", "G#", "A#", "C", "C#", "D#"]
        case "F# Minor": return ["F#", "G#", "A", "B", "C#", "D", "E"]
        case "C# Minor": return ["C#", "D#", "E", "F#", "G#", "A", "B"]
        case "D Minor": return ["D", "E", "F", "G", "A", "Bb", "C"]
        case "Db Minor": return ["C#", "D#", "E", "F#", "G#", "A", "B"]
        case "G Minor": return ["G", "A", "Bb", "C", "D", "Eb", "F"]
        case "C Minor": return ["C", "D", "Eb", "F", "G", "Ab", "Bb"]
        default: return []
        }
    }
    
    // MARK: - Key Signature Cleaner
    
    func cleanKeySignature(_ raw: String) -> String {
        let input = raw.components(separatedBy: CharacterSet(charactersIn: ",:")).first ?? raw
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let pattern = #"^([A-Ga-g][b#]?)(major|minor)$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        
        if let match = regex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
           let keyRange = Range(match.range(at: 1), in: trimmed),
           let typeRange = Range(match.range(at: 2), in: trimmed) {
            
            let key = trimmed[keyRange].prefix(1).uppercased() + trimmed[keyRange].dropFirst().lowercased()
            let type = trimmed[typeRange].capitalized
            return "\(key) \(type)"
        }
        
        return trimmed.capitalized
    }
    
    // MARK: - Preview
    
    struct TogglePreviewWrapper: View {
        @State private var isDark: Bool = false
        
        var body: some View {
            VStack {
                Toggle("Dark Mode", isOn: $isDark)
                    .padding()
                
                ContentView()
                    .preferredColorScheme(isDark ? .dark : .light)
            }
        }
    }
    
    #Preview {
        TogglePreviewWrapper()
    }
    
    
