// Tests/TranslatorAppTests/WindowPreview.swift
import AppKit
import SwiftUI
import Testing
@testable import TranslationCore
@testable import TranslatorApp

/// The main window, hosted on a real on-screen window with the real models, photographed — so the
/// toolbar, the pane headers and the status bar can be judged from pictures, in both appearances,
/// without anyone opening the app.
///
/// **Not a test, and off unless asked for** — the contract `renderPreview` keeps: it writes files,
/// it shows a window for a moment, and its outcome is a judgement. Run it as:
///
///     RENDER_PREVIEW_WINDOW=/tmp/preview swift test --filter renderWindowPreview
///
/// The toolbar is SwiftUI's own, bridged to the window through `sceneBridgingOptions`, so what it
/// draws is what the `Window` scene draws; the scene's `.windowToolbarStyle(.unifiedCompact)` and
/// the hidden title are set on the window by hand, as the scene and `WindowTitleHidden` set them.
/// The capture is `screencapture -l` of this window alone, so nothing of another application is in
/// the picture. Twelve images: a finished перевод, a finished правка, a translated two-file queue
/// and the empty window at 1100 × 640, and the перевод and the правка at the window's 700 pt
/// minimum, each light and dark.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RENDER_PREVIEW_WINDOW"] != nil))
func renderWindowPreview() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_PREVIEW_WINDOW"] ?? ".")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSApplication.shared.setActivationPolicy(.regular)

    let source = """
        Hi Anna! I'm sending you the August report — please have a look before Friday. \
        The details are on the website, and the comments are at the bottom.

        If anything is unclear, write to me; I'm in touch all week.
        """
    let reply = """
        Добрый день, Анна! Высылаю вам отчёт за август — посмотрите, пожалуйста, до пятницы. \
        Подробности на сайте, комментарии внизу.

        Если что-то будет непонятно, пишите: я на связи всю неделю.
        """

    for (name, operation, width, sourceMode) in [
        ("translate", TextOperation.translate, CGFloat(1100), SourceMode.text),
        ("proofread", .proofread, 1100, .text),
        ("files", .translate, 1100, .files),
        ("empty", .translate, 1100, .text),
        ("translate-700", .translate, 700, .text),
        ("proofread-700", .proofread, 700, .text),
    ] {
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let settings = AppSettings(defaults: InMemoryDefaults(prefix: "window-\(name)-\(look)"))
            let model = TranslationViewModel(
                translator: Translator(client: QueueClient(replies: [reply, reply, reply])),
                settings: settings, glossary: scratchGlossary(),
                pasteboard: NSPasteboard(name: .init("window-preview-\(name)-\(look)")))
            model.operation = operation
            if name != "empty" {
                model.sourceText = operation == .translate
                    ? source : reply.replacingOccurrences(of: "отчёт", with: "отчет")
                if operation == .translate { model.targetOverride = .ru }
                await model.run()
            }
            let queue = makeQueueModel(QueueClient(replies: [reply, reply]),
                                       prefix: "window-queue-\(name)-\(look)")
            if sourceMode == .files {
                queue.add([queueJob("august-report.md", source), queueJob("release-notes.md", source)])
                await queue.run()
                queue.selection = queue.jobs.first?.id
            }

            let root = MainWindowView(model: model, glossary: scratchGlossary(),
                                      status: .running(modelResident: true), engineName: "Ollama",
                                      onRunFinished: {}, queue: queue, panelModel: nil,
                                      settings: settings, mode: .constant(sourceMode))
            let host = NSHostingView(rootView: root)
            host.sceneBridgingOptions = [.toolbars]
            let window = ActiveWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            // Out of Stage Manager's reach: with it on, a window of an application that is not in
            // front is drawn as a tilted thumbnail in the strip, and that is what a capture of it
            // returns. `.stationary` was measured to keep it a window (2026-10-29).
            window.collectionBehavior = [.stationary]
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(900))

            let file = directory.appendingPathComponent("window-\(name)-\(look).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
            try capture.run()
            capture.waitUntilExit()
            window.orderOut(nil)
        }
    }
}

/// A window AppKit draws as the active one. A test process is not a foreground application, so its
/// windows never become key and every control in them draws in the inactive state — grey
/// traffic lights, a grey prominent button — which is not what anyone judging colours needs to see.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
