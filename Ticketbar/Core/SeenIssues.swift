import Foundation

/// The set of issue keys the user has already been told about.
///
/// Seeding is an explicit, named step, deliberately not a side effect of the first fetch. If the
/// diff were allowed to run before the set existed, the entire existing backlog would arrive as
/// notifications the first time the app launched, which is the one first-run bug nobody forgives.
final class SeenIssues {
    /// Keys are kept in insertion order and capped. Without a cap the list grows for the life of
    /// the install; pruning by "no longer assigned" instead would re-notify an issue that briefly
    /// left the result set and came back.
    private static let capacity = 1000

    private let defaults: UserDefaults
    private var order: [String]
    private var index: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.order = defaults.stringArray(forKey: Keys.seenIssueKeys) ?? []
        self.index = Set(order)
    }

    var isSeeded: Bool { defaults.bool(forKey: Keys.seenSetSeeded) }

    var count: Int { order.count }

    /// First run only. Records the existing backlog without notifying for any of it.
    func seed(with keys: [String]) {
        order = []
        index = []
        insert(keys)
        defaults.set(true, forKey: Keys.seenSetSeeded)
        persist()
    }

    /// The keys in `keys` that have never been recorded. Read-only: call `markSeen` after the
    /// notifications actually go out, so a crash between the two does not silently swallow them.
    func unseen(among keys: [String]) -> [String] {
        keys.filter { !index.contains($0) }
    }

    func markSeen(_ keys: [String]) {
        insert(keys)
        persist()
    }

    /// For the "notify me about everything again" reset in Settings.
    func forgetAll() {
        order = []
        index = []
        defaults.set(false, forKey: Keys.seenSetSeeded)
        persist()
    }

    private func insert(_ keys: [String]) {
        for key in keys where !index.contains(key) {
            index.insert(key)
            order.append(key)
        }
        if order.count > Self.capacity {
            let dropped = order.prefix(order.count - Self.capacity)
            order.removeFirst(order.count - Self.capacity)
            index.subtract(dropped)
        }
    }

    private func persist() {
        defaults.set(order, forKey: Keys.seenIssueKeys)
    }
}
