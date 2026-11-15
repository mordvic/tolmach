/// One executor for every MarkupKit test that builds `NSFont` / `NSAttributedString` values.
///
/// UIFoundation's attribute-dictionary table and font cache crashed the test process (about 14 of
/// 100 loaded runs) when many of these tests ran at once on swift-testing's parallel pool. A
/// global actor serialises them among themselves, so at most one is inside AppKit at a time,
/// without queueing them behind the `@MainActor` tests of the other targets.
@globalActor
actor MarkupTestActor {
    static let shared = MarkupTestActor()
}
