// Sources/TranslatorApp/TranslatorApp.swift
import SwiftUI

@main
struct TranslatorApp: App {
    var body: some Scene {
        MenuBarExtra("Толмач", systemImage: "character.bubble") {
            Button("Открыть окно перевода") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}
