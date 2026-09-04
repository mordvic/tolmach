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
/// The built CLI, or nil when this checkout has not built it. A **trait**, not a recorded
/// issue: `swift test` builds the test targets and their dependencies, and `translate-cli` is an
/// executable product nothing in the tests depends on — so after a partial build the binary is
/// legitimately absent and a failure here would be about the build order, not about the flag.
/// CI runs `swift build --build-tests` first, which builds every product, so there the test
/// runs; a `--filter` run on a fresh clone skips it and says so in the test log.
private let cliBinary: URL? = {
    let url = RepoRoot.url.appendingPathComponent(".build/debug/translate-cli")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}()

@Test(.enabled(if: cliBinary != nil, "translate-cli is not built; run swift build --build-tests"))
func explainWithoutProofreadIsRefusedByTheCLI() throws {
    let binary = try #require(cliBinary)
    let (status, stderr) = try run(binary, arguments: ["--to", "ru", "--explain", "hello"])
    // `fail()`'s own exit code — the same one `--to`, `--chunk` and every other rejected flag
    // in this file uses, not a code invented for this one.
    #expect(status == 2)
    #expect(stderr.contains("--explain applies to --proofread only"))
}

/// The mirror case: `--format-only` is its own operation, and `--explain` is refused there too
/// rather than silently answering about a change set `--format-only` never computes.
@Test(.enabled(if: cliBinary != nil, "translate-cli is not built; run swift build --build-tests"))
func explainUnderFormatOnlyIsAlsoRefused() throws {
    let binary = try #require(cliBinary)
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
