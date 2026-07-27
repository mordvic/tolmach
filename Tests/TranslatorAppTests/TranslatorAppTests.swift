// Tests/TranslatorAppTests/TranslatorAppTests.swift
//
// TranslatorApp has no testable logic of its own yet (Task 1 only adds the
// bundle scaffold and menu bar scene), so this placeholder simply asserts
// that the app target's own bundle resolves to a real, non-empty path —
// enough to keep the test target non-empty until real view models land.
import Foundation
import Testing
@testable import TranslatorApp

@Test func mainBundlePathResolves() {
    #expect(!Bundle.main.bundlePath.isEmpty)
}
