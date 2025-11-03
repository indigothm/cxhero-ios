import Foundation

actor ScheduledSurveyStore {
    private let baseDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    struct ScheduledSurveys: Codable {
        var scheduled: [ScheduledSurvey] = []
    }
    
    struct ScheduledSurvey: Codable, Identifiable {
        let id: String // ruleId
        let userId: String?
        let sessionId: String
        let scheduledAt: Date
        let triggerAt: Date
        
        var isExpired: Bool {
            Date() > triggerAt
        }
        
        var remainingDelay: TimeInterval {
            max(0, triggerAt.timeIntervalSince(Date()))
        }
    }
    
    func scheduleForLater(ruleId: String, userId: String?, sessionId: String, delaySeconds: TimeInterval) async {
        let url = scheduledURL(for: userId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var surveys = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(ScheduledSurveys.self, from: $0) } ?? ScheduledSurveys()
            
            // Remove any existing scheduled survey with same rule ID for this session
            surveys.scheduled.removeAll { $0.id == ruleId && $0.sessionId == sessionId }
            
            let scheduled = ScheduledSurvey(
                id: ruleId,
                userId: userId,
                sessionId: sessionId,
                scheduledAt: Date(),
                triggerAt: Date().addingTimeInterval(delaySeconds)
            )
            surveys.scheduled.append(scheduled)
            
            let data = try encoder.encode(surveys)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silently ignore errors
        }
    }
    
    func getPendingSurveys(for userId: String?, sessionId: String) async -> [ScheduledSurvey] {
        let url = scheduledURL(for: userId)
        guard let data = try? Data(contentsOf: url),
              let surveys = try? decoder.decode(ScheduledSurveys.self, from: data) else {
            return []
        }
        
        // Return only surveys for current session that haven't triggered yet
        return surveys.scheduled.filter { 
            $0.sessionId == sessionId && !$0.isExpired 
        }
    }
    
    func getTriggeredSurveys(for userId: String?, sessionId: String) async -> [ScheduledSurvey] {
        let url = scheduledURL(for: userId)
        guard let data = try? Data(contentsOf: url),
              let surveys = try? decoder.decode(ScheduledSurveys.self, from: data) else {
            return []
        }
        
        // Return only surveys for current session that should have triggered by now
        return surveys.scheduled.filter { 
            $0.sessionId == sessionId && $0.isExpired 
        }
    }
    
    func removeScheduled(ruleId: String, sessionId: String, userId: String?) async {
        let url = scheduledURL(for: userId)
        do {
            guard var surveys = (try? Data(contentsOf: url)).flatMap({ try? decoder.decode(ScheduledSurveys.self, from: $0) }) else {
                return
            }
            
            surveys.scheduled.removeAll { $0.id == ruleId && $0.sessionId == sessionId }
            
            let data = try encoder.encode(surveys)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silently ignore errors
        }
    }
    
    func cleanupOldScheduled(olderThan: TimeInterval = 86400) async {
        // Clean up scheduled surveys older than specified time (default 24 hours)
        // This runs for all users
        let usersURL = baseDirectory.appendingPathComponent("users")
        guard let userDirs = try? FileManager.default.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for userDir in userDirs {
            let url = userDir.appendingPathComponent("surveys").appendingPathComponent("scheduled.json")
            guard var surveys = (try? Data(contentsOf: url)).flatMap({ try? decoder.decode(ScheduledSurveys.self, from: $0) }) else {
                continue
            }
            
            let cutoff = Date().addingTimeInterval(-olderThan)
            surveys.scheduled.removeAll { $0.scheduledAt < cutoff }
            
            if let data = try? encoder.encode(surveys) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    // MARK: - Paths
    private func scheduledURL(for userId: String?) -> URL {
        let userFolder = safeUserFolder(for: userId)
        return baseDirectory
            .appendingPathComponent("users")
            .appendingPathComponent(userFolder)
            .appendingPathComponent("surveys")
            .appendingPathComponent("scheduled.json")
    }
    
    private func safeUserFolder(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "anon" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_@."))
        let cleaned = userId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
        return cleaned
    }
}

