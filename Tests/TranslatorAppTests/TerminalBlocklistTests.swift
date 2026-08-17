import Testing
@testable import TranslatorApp

@Test func everyListedTerminalIsBlocked() {
    // Named individually rather than counting the set, so a copy-paste error in one
    // identifier fails on the specific one rather than only moving the count.
    let terminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
        "co.zeit.hyper", "com.mitchellh.ghostty", "org.tabby",
    ]
    for id in terminals {
        #expect(TerminalBlocklist.isBlocked(id), "\(id) should be blocked")
    }
}

@Test func ordinaryApplicationsAreNotBlocked() {
    #expect(!TerminalBlocklist.isBlocked("com.apple.Safari"))
    #expect(!TerminalBlocklist.isBlocked("com.apple.TextEdit"))
    #expect(!TerminalBlocklist.isBlocked("com.microsoft.teams2"))
}

@Test func nilIsNotBlocked() {
    // No frontmost application, or one that answered no bundle identifier, is not something
    // this list has been told to recognise as a terminal — a blocklist that refused on `nil`
    // would disable «Заменить» everywhere it doesn't have an answer, which is a whitelist.
    #expect(!TerminalBlocklist.isBlocked(nil))
}
