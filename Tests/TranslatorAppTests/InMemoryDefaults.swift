import Foundation

/// A `UserDefaults` that keeps everything in memory, so a test can hand one to
/// `AppSettings(defaults:)` without leaving anything behind on disk.
///
/// The obvious way to isolate a test from the developer's real preferences is
/// `UserDefaults(suiteName:)` with a fresh UUID, and that is what these tests used
/// to do. The problem is that such a suite is durable: any test that writes a key
/// deposits `~/Library/Preferences/<suite>.plist`, and nothing ever removes it, so
/// the directory accumulates one file per writing test per run indefinitely.
///
/// Cleaning up afterwards does not work, and it is worth recording why so nobody
/// re-attempts it. `cfprefsd` — not this process — owns the file. Emptying the
/// domain and deleting the plist in a `deinit` was measured against a standalone
/// probe: the values do get cleared, but roughly ten seconds later, *after the
/// process has exited*, the daemon writes the file back out from its own cache.
/// Four variants were tried — `removePersistentDomain` plus a synchronise, removing
/// each key first, clearing the domain through `CFPreferencesSetMultiple`, and
/// dropping the suite from the search list — and all four left a fresh empty plist
/// behind (a suite left entirely alone kept its real values, confirming the probe
/// could tell the difference). There is no in-process moment late enough to delete
/// the file, because the write happens after the last one.
///
/// So the only way not to leak is never to let a write reach the daemon. These
/// three methods are the whole of what `AppSettings` calls — `string(forKey:)` for
/// strings and `object(forKey:)` for its int, double and bool reads — and
/// overriding them keeps every value in the dictionary below.
///
/// The superclass is still initialised with a unique throwaway suite rather than
/// with `nil`. `nil` would make the standard domain the backing store, so anything
/// this class fails to intercept would read and write the developer's actual
/// preferences. Pointing it at a scratch suite instead means a missed override is
/// harmless *and* visible: it would deposit a `<prefix>-<uuid>.plist`, which is
/// exactly what the file count in that directory is checked for. Nothing is ever
/// written to that suite in practice, and a suite that is only created and never
/// written produces no file.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    /// - Parameter prefix: leading component of the throwaway backing suite name, so
    ///   that a file appearing from a missed override can be traced to its tests.
    init(prefix: String) {
        super.init(suiteName: "\(prefix)-\(UUID().uuidString)")!
    }

    override func object(forKey key: String) -> Any? { storage[key] }
    override func set(_ value: Any?, forKey key: String) { storage[key] = value }
    override func string(forKey key: String) -> String? { storage[key] as? String }
}
