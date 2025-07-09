import SwiftUI

@main
struct KOMAApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var pybridge = AnyPythonBridge(PythonBridge())
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}

