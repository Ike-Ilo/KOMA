//  KOMAApp.swift
//  KOMA
//  Created by ike iloegbu on 5/9/25.

import SwiftUI

@main
struct KOMAApp: App {
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var pybridge = AnyPythonBridge(PythonBridge())
    var body: some Scene {
        WindowGroup {
            ContentView(pybridge: pybridge)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
    }
}
