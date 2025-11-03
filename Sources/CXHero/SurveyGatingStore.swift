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
    struct Record: Codable { 
        var lastShownAt: Date
        var shownOnce: Bool
        var attemptCount: Int = 0
        var completedOnce: Bool = false
    }

    func canShow(ruleId: String, forUser userId: String?, oncePerUser: Bool?, cooldownSeconds: TimeInterval?, maxAttempts: Int?, attemptCooldownSeconds: TimeInterval?) async -> Bool {
        let path = gatingURL(for: userId)
        let file = path
        guard let gating = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(Gating.self, from: $0) }) else {
            // No history -> allow
            return true
        }
        if let rec = gating.rules[ruleId] {
            // If survey was completed, don't show again
            if rec.completedOnce { return false }
            
            // Check if max attempts reached
            if let max = maxAttempts, rec.attemptCount >= max {
                return false
            }
            
            // Check oncePerUser (blocks after first attempt, not completion)
            if oncePerUser ?? false { return false }
            
            // Check cooldown - use attemptCooldownSeconds if available, otherwise cooldownSeconds
            let cooldown = attemptCooldownSeconds ?? cooldownSeconds
            if let cd = cooldown {
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
            
            if var existingRec = gating.rules[ruleId] {
                // Increment attempt count
                existingRec.attemptCount += 1
                existingRec.lastShownAt = Date()
                existingRec.shownOnce = true
                gating.rules[ruleId] = existingRec
            } else {
                // First time showing
                let rec = Record(lastShownAt: Date(), shownOnce: true, attemptCount: 1, completedOnce: false)
                gating.rules[ruleId] = rec
            }
            
            let data = try encoder.encode(gating)
            try data.write(to: url, options: .atomic)
        } catch {
            // ignore errors
        }
    }
    
    func markCompleted(ruleId: String, forUser userId: String?) async {
        let url = gatingURL(for: userId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var gating = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Gating.self, from: $0) } ?? Gating()
            
            if var existingRec = gating.rules[ruleId] {
                existingRec.completedOnce = true
                gating.rules[ruleId] = existingRec
            } else {
                // Shouldn't happen, but handle gracefully
                let rec = Record(lastShownAt: Date(), shownOnce: true, attemptCount: 1, completedOnce: true)
                gating.rules[ruleId] = rec
            }
            
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

