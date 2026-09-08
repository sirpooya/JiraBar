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
    private let keysKey: String
    private let seededKey: String
    private var order: [String]
    private var index: Set<String>

    /// One set per namespace. Each board column keeps its own, because switching columns would
    /// otherwise diff the new column's issues against the old column's set and notify for all of
    /// them at once.
    init(namespace: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keysKey = Keys.seenIssueKeys + "." + namespace
        self.seededKey = Keys.seenSetSeeded + "." + namespace
        self.order = defaults.stringArray(forKey: keysKey) ?? []
        self.index = Set(order)
    }

    var isSeeded: Bool { defaults.bool(forKey: seededKey) }

    var count: Int { order.count }

    /// First run only. Records the existing backlog without notifying for any of it.
    func seed(with keys: [String]) {
        order = []
        index = []
        insert(keys)
        defaults.set(true, forKey: seededKey)
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
        defaults.set(false, forKey: seededKey)
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
        defaults.set(order, forKey: keysKey)
    }
}
