import Testing
import Foundation

/// `--explain` is a `--proofread`-only flag (`Sources/translate-cli/main.swift`'s operation
/// split, the same shape `--changes-json` and `--level`/`--style` already follow: an
/// inapplicable flag is refused, never silently ignored, so a mistyped measurement cannot look
/// like a result).
///
/// A black-box subprocess test, not a unit test of `parse(_:)`, because `main.swift`'s
/// top-level statements run at import time and exit the process — there is no way to link that
/// code into a test target and call a function in it. Still an offline test: the operation
/// split runs and calls `fail()` before any network call is ever attempted, on either flag
/// combination below, so this passes with no engine running and costs nothing over the two
/// process launches. The binary itself is a side effect of `swift test`'s own build step (see
/// `.github/workflows/ci.yml`'s "Build (including tests)" before "Test"), not something this
/// test builds.
@Test func explainWithoutProofreadIsRefusedByTheCLI() throws {
    let binary = RepoRoot.url.appendingPathComponent(".build/debug/translate-cli")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        Issue.record("translate-cli binary not found at \(binary.path) — build the package first (swift build --build-tests)")
        return
    }
    let (status, stderr) = try run(binary, arguments: ["--to", "ru", "--explain", "hello"])
    // `fail()`'s own exit code — the same one `--to`, `--chunk` and every other rejected flag
    // in this file uses, not a code invented for this one.
    #expect(status == 2)
    #expect(stderr.contains("--explain applies to --proofread only"))
}

/// The mirror case: `--format-only` is its own operation, and `--explain` is refused there too
/// rather than silently answering about a change set `--format-only` never computes.
@Test func explainUnderFormatOnlyIsAlsoRefused() throws {
    let binary = RepoRoot.url.appendingPathComponent(".build/debug/translate-cli")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        Issue.record("translate-cli binary not found at \(binary.path) — build the package first (swift build --build-tests)")
        return
    }
    let (status, stderr) = try run(binary, arguments: ["--format-only", "--explain", "hello"])
    #expect(status == 2)
    #expect(stderr.contains("--explain applies to --proofread only"))
}

private func run(_ binary: URL, arguments: [String]) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
