// Sources/TranslatorApp/DisplayContrast.swift
import AppKit
import Observation

/// Whether the system's Increase Contrast is on, as a value SwiftUI can observe.
///
/// **The change marks need it passed in, because the appearance cannot carry it.** A high-contrast
/// appearance cannot be built offscreen — `NSAppearance(named: .accessibilityHighContrastAqua)`
/// answers `.aqua` to `bestMatch(from:)` and resolves every system colour as `.aqua` does
/// (measured 2026-10-29) — and the marks' *weight* is an attribute, not a dynamic colour, so a
/// change of the setting needs the storage rebuilt rather than merely redrawn. `NSWorkspace`'s
/// property and its notification are the documented source (`NSAccessibility.h`); the views read
/// `isIncreased` in their `body`, so a change of it re-runs them and the coordinators rebuild on
/// the new key.
@MainActor
@Observable
final class DisplayContrast {
    static let shared = DisplayContrast()

    private(set) var isIncreased: Bool

    @ObservationIgnored private let read: @MainActor () -> Bool
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - center: where `accessibilityDisplayOptionsDidChangeNotification` is posted —
    ///     `NSWorkspace`'s own centre, not `NotificationCenter.default`.
    ///   - read: the setting. A parameter so a test can flip it: the system's cannot be.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         read: @escaping @MainActor () -> Bool = {
             NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
         }) {
        self.read = read
        isIncreased = read()
        observer = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                // `queue: .main` delivers on the main thread; the closure is not isolated by its
                // type, so it says so.
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    private func refresh() {
        let now = read()
        if now != isIncreased { isIncreased = now }
    }
}
