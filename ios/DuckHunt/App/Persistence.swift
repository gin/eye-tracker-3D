import DuckHuntCore
import Foundation

@MainActor
enum GazeModelStore {
    private static let key = "duckHunt.gazeModel.v2"

    static func load(from defaults: UserDefaults = .standard) -> GazeModel? {
        guard
            let data = defaults.data(forKey: key),
            let model = try? JSONDecoder().decode(GazeModel.self, from: data),
            model.isValid
        else { return nil }
        return model
    }

    static func save(_ model: GazeModel, to defaults: UserDefaults = .standard) {
        guard model.isValid, let data = try? JSONEncoder().encode(model) else { return }
        defaults.set(data, forKey: key)
    }

}

struct ScoreRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let score: Int
    let playedAt: Date
}

@MainActor
enum ScoreStore {
    private static let key = "duckHunt.scores.v1"
    private static let maximumEntries = 10

    static func load(from defaults: UserDefaults = .standard) -> [ScoreRecord] {
        guard
            let data = defaults.data(forKey: key),
            let records = try? JSONDecoder().decode([ScoreRecord].self, from: data)
        else { return [] }
        return Array(records.sorted(by: scoreOrder).prefix(maximumEntries))
    }

    @discardableResult
    static func record(
        score: Int,
        in records: inout [ScoreRecord],
        defaults: UserDefaults = .standard
    ) -> Int {
        let record = ScoreRecord(id: UUID(), score: score, playedAt: Date())
        records.append(record)
        records.sort(by: scoreOrder)
        records = Array(records.prefix(maximumEntries))
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
        return records.firstIndex(where: { $0.id == record.id }).map { $0 + 1 } ?? records.count + 1
    }

    nonisolated private static func scoreOrder(_ lhs: ScoreRecord, _ rhs: ScoreRecord) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.playedAt < rhs.playedAt
    }
}
