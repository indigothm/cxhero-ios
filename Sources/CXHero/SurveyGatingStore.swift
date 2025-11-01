import Foundation

actor SurveyGatingStore {
    private let baseDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    struct Gating: Codable { var rules: [String: Record] = [:] }
    struct Record: Codable { var lastShownAt: Date; var shownOnce: Bool }

    func canShow(ruleId: String, forUser userId: String?, oncePerUser: Bool?, cooldownSeconds: TimeInterval?) async -> Bool {
        let path = gatingURL(for: userId)
        let file = path
        guard let gating = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(Gating.self, from: $0) }) else {
            // No history -> allow
            return true
        }
        if let rec = gating.rules[ruleId] {
            if oncePerUser ?? false { return false }
            if let cd = cooldownSeconds {
                let next = rec.lastShownAt.addingTimeInterval(cd)
                if Date() < next { return false }
            }
        }
        return true
    }

    func markShown(ruleId: String, forUser userId: String?) async {
        let url = gatingURL(for: userId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var gating = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Gating.self, from: $0) } ?? Gating()
            let rec = Record(lastShownAt: Date(), shownOnce: true)
            gating.rules[ruleId] = rec
            let data = try encoder.encode(gating)
            try data.write(to: url, options: .atomic)
        } catch {
            // ignore errors
        }
    }

    // MARK: - Paths
    private func gatingURL(for userId: String?) -> URL {
        let userFolder = safeUserFolder(for: userId)
        return baseDirectory
            .appendingPathComponent("users")
            .appendingPathComponent(userFolder)
            .appendingPathComponent("surveys")
            .appendingPathComponent("gating.json")
    }

    private func safeUserFolder(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "anon" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_@."))
        let cleaned = userId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
        return cleaned
    }
}

