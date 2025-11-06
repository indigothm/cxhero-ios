import Foundation
import Combine

/// Actor-backed store that persists events as JSON lines to a specific file.
actor EventStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        // Human-friendly but consistent ISO 8601 timestamps
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ event: Event) async {
        do {
            // Ensure parent directory exists
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let data = try encoder.encode(event)
            var toWrite = data
            toWrite.append(0x0A) // Newline for JSONL

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: toWrite)
                try handle.close()
            } else {
                try toWrite.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Intentionally avoid throwing to keep recording non-intrusive.
            // Consider logging in host app.
        }
    }

    func readAll() async -> [Event] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }
            // Parse line-delimited JSON
            var events: [Event] = []
            data.split(separator: 0x0A).forEach { line in
                if line.isEmpty { return }
                if let event = try? decoder.decode(Event.self, from: Data(line)) {
                    events.append(event)
                }
            }
            return events
        } catch {
            return []
        }
    }

    func clear() async {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // swallow errors; clearing is best-effort
        }
    }
}

// Coordinates session lifecycle and per-session event store.
actor SessionCoordinator {
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let retentionPolicy: RetentionPolicy

    private var currentSession: EventSession?
    private var currentStore: EventStore?

    init(baseDirectory: URL, retentionPolicy: RetentionPolicy = .standard) {
        self.baseDirectory = baseDirectory
        self.retentionPolicy = retentionPolicy
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func startSession(userID: String?, metadata: [String: EventValue]?) async -> EventSession {
        // Run automatic cleanup if enabled
        if retentionPolicy.automaticCleanupEnabled {
            await applyRetentionPolicy()
        }
        
        let session = EventSession(userId: userID, metadata: metadata)
        let dirs = paths(for: session)

        do {
            try FileManager.default.createDirectory(at: dirs.sessionDir, withIntermediateDirectories: true)
            // Persist session metadata
            let data = try encoder.encode(session)
            try data.write(to: dirs.sessionMetaURL, options: .atomic)
        } catch {
            // ignore errors to keep API non-throwing
        }

        self.currentSession = session
        self.currentStore = EventStore(fileURL: dirs.eventsURL)
        return session
    }

    func endSession() async {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        let dirs = paths(for: session)
        do {
            let data = try encoder.encode(session)
            try data.write(to: dirs.sessionMetaURL, options: .atomic)
        } catch {
            // ignore errors
        }
        self.currentSession = nil
        self.currentStore = nil
    }

    func currentSessionInfo() -> EventSession? { currentSession }

    func record(name: String, properties: [String: EventValue]?) async -> (event: Event?, autoStartedSession: EventSession?) {
        // Ensure we have a session; start an anonymous one if needed
        var autoStartedSession: EventSession? = nil
        if currentSession == nil || currentStore == nil {
            autoStartedSession = await startSession(userID: nil, metadata: nil)
        }
        guard let session = currentSession, let store = currentStore else { return (nil, nil) }

        let event = Event(
            name: name,
            properties: properties,
            sessionId: session.id,
            userId: session.userId
        )
        await store.append(event)
        return (event, autoStartedSession)
    }

    func eventsInCurrentSession() async -> [Event] {
        guard let store = currentStore else { return [] }
        return await store.readAll()
    }

    func allEvents() async -> [Event] {
        // Aggregate events across all session files under baseDirectory
        var all: [Event] = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "events.jsonl" {
                let store = EventStore(fileURL: url)
                let events = await store.readAll()
                all.append(contentsOf: events)
            }
        }
        return all
    }

    func clearAll() async {
        do {
            if FileManager.default.fileExists(atPath: baseDirectory.path) {
                try FileManager.default.removeItem(at: baseDirectory)
            }
        } catch {
            // ignore
        }
        self.currentSession = nil
        self.currentStore = nil
    }

    func baseDir() -> URL { baseDirectory }

    // MARK: - Session listing
    func listAllSessions() async -> [EventSession] {
        var sessions: [EventSession] = []
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "session.json" {
                if let data = try? Data(contentsOf: url), let session = try? decoder.decode(EventSession.self, from: data) {
                    sessions.append(session)
                }
            }
        }
        return sessions.sorted(by: { $0.startedAt < $1.startedAt })
    }

    func listSessions(forUserID userId: String?) async -> [EventSession] {
        let userFolder = safeUserFolder(for: userId)
        let sessionsDir = baseDirectory.appendingPathComponent("users").appendingPathComponent(userFolder).appendingPathComponent("sessions")
        var result: [EventSession] = []
        if let items = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) {
            for dir in items {
                let meta = dir.appendingPathComponent("session.json")
                if let data = try? Data(contentsOf: meta), let session = try? decoder.decode(EventSession.self, from: data) {
                    result.append(session)
                }
            }
        }
        return result.sorted(by: { $0.startedAt < $1.startedAt })
    }

    func events(forSessionID id: UUID) async -> [Event] {
        // Search across users
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == id.uuidString {
                let eventsURL = url.appendingPathComponent("events.jsonl")
                let store = EventStore(fileURL: eventsURL)
                return await store.readAll()
            }
        }
        return []
    }

    // MARK: - Paths
    private struct Paths { let sessionDir: URL; let eventsURL: URL; let sessionMetaURL: URL }

    private func paths(for session: EventSession) -> Paths {
        let userFolder = safeUserFolder(for: session.userId)
        let sessionDir = baseDirectory
            .appendingPathComponent("users")
            .appendingPathComponent(userFolder)
            .appendingPathComponent("sessions")
            .appendingPathComponent(session.id.uuidString)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        let sessionMetaURL = sessionDir.appendingPathComponent("session.json")
        return Paths(sessionDir: sessionDir, eventsURL: eventsURL, sessionMetaURL: sessionMetaURL)
    }

    fileprivate func safeUserFolder(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "anon" }
        // Restrict to a safe subset for filesystem names
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_@."))
        let cleaned = userId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
        return cleaned
    }
    
    // MARK: - Retention Policy
    
    /// Apply retention policy by cleaning up old sessions and events
    func applyRetentionPolicy() async {
        let fm = FileManager.default
        let usersURL = baseDirectory.appendingPathComponent("users")
        
        guard let userDirs = try? fm.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for userDir in userDirs {
            let sessionsURL = userDir.appendingPathComponent("sessions")
            await cleanupUserSessions(at: sessionsURL)
        }
    }
    
    private func cleanupUserSessions(at sessionsURL: URL) async {
        let fm = FileManager.default
        
        guard let sessionDirs = try? fm.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        var sessions: [(url: URL, session: EventSession)] = []
        let currentSessionId = currentSession?.id
        
        // Load all session metadata
        for sessionDir in sessionDirs {
            let metaURL = sessionDir.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let session = try? decoder.decode(EventSession.self, from: data) else {
                continue
            }
            sessions.append((url: sessionDir, session: session))
        }
        
        // Apply age-based retention
        if let maxAge = retentionPolicy.maxAge {
            let cutoffDate = Date().addingTimeInterval(-maxAge)
            for (url, session) in sessions {
                // Don't delete current session
                if session.id == currentSessionId { continue }
                
                if session.startedAt < cutoffDate {
                    try? fm.removeItem(at: url)
                }
            }
            
            // Remove deleted sessions from array
            sessions.removeAll { (url, session) in
                session.startedAt < cutoffDate
            }
        }
        
        // Apply count-based retention (keep newest N sessions)
        if let maxCount = retentionPolicy.maxSessionsPerUser, sessions.count > maxCount {
            // Sort by start date (newest first)
            let sorted = sessions.sorted { $0.session.startedAt > $1.session.startedAt }
            
            // Delete sessions beyond the limit (but never delete current session)
            for i in maxCount..<sorted.count {
                // Skip current session
                if sorted[i].session.id == currentSessionId { continue }
                try? fm.removeItem(at: sorted[i].url)
            }
        }
    }
}

/// Session lifecycle events published by EventRecorder
public enum SessionLifecycleEvent {
    case started(session: EventSession)
    case ended(session: EventSession?)
}

/// Public singleton interface for recording and inspecting events with session scoping.
public final class EventRecorder: @unchecked Sendable {
    public static let shared = EventRecorder()

    private let coordinator: SessionCoordinator
    private let baseDirectoryURL: URL
    private let subject = PassthroughSubject<Event, Never>()
    private let sessionSubject = PassthroughSubject<SessionLifecycleEvent, Never>()
    
    /// Current retention policy
    public let retentionPolicy: RetentionPolicy

    /// Designated initializer.
    /// - Parameters:
    ///   - directory: Base directory to store user/session-scoped data. Defaults to the app's Documents/CXHero directory.
    ///   - retentionPolicy: Policy for automatic cleanup of old data. Defaults to `.standard` (30 days, 50 sessions).
    public init(directory: URL? = nil, retentionPolicy: RetentionPolicy = .standard) {
        let base: URL
        if let directory {
            base = directory
        } else {
            #if os(iOS) || os(tvOS) || os(watchOS)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            base = docs.appendingPathComponent("CXHero")
            #else
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            base = docs.appendingPathComponent("CXHero")
            #endif
        }
        self.baseDirectoryURL = base
        self.retentionPolicy = retentionPolicy
        self.coordinator = SessionCoordinator(baseDirectory: base, retentionPolicy: retentionPolicy)
    }

    // MARK: - Session API
    @discardableResult
    public func startSession(userID: String? = nil, metadata: [String: EventValue]? = nil) async -> EventSession {
        let session = await coordinator.startSession(userID: userID, metadata: metadata)
        await MainActor.run {
            sessionSubject.send(.started(session: session))
        }
        return session
    }

    public func endSession() async {
        let session = await coordinator.currentSessionInfo()
        await coordinator.endSession()
        await MainActor.run {
            sessionSubject.send(.ended(session: session))
        }
    }

    public func currentSession() async -> EventSession? {
        await coordinator.currentSessionInfo()
    }

    // MARK: - Event API
    public func record(_ name: String, properties: [String: EventValue]? = nil) {
        Task {
            let (event, autoStartedSession) = await coordinator.record(name: name, properties: properties)
            
            // If a session was auto-started, publish the lifecycle event
            if let session = autoStartedSession {
                await MainActor.run {
                    sessionSubject.send(.started(session: session))
                }
            }
            
            // Publish the event
            if let event = event {
                subject.send(event)
            }
        }
    }

    public func eventsInCurrentSession() async -> [Event] {
        await coordinator.eventsInCurrentSession()
    }

    /// Returns all events across all users and sessions under the base directory.
    public func allEvents() async -> [Event] {
        await coordinator.allEvents()
    }

    /// Clears all stored users, sessions and events.
    public func clear() async { await coordinator.clearAll() }

    // MARK: - Event stream
    public var eventsPublisher: AnyPublisher<Event, Never> { subject.eraseToAnyPublisher() }
    
    /// Publisher for session lifecycle events (started, ended)
    public var sessionPublisher: AnyPublisher<SessionLifecycleEvent, Never> { sessionSubject.eraseToAnyPublisher() }
    
    /// Check if there are any scheduled surveys for a user
    public func hasScheduledSurveys(for userId: String?) async -> Bool {
        let store = ScheduledSurveyStore(baseDirectory: storageBaseDirectoryURL)
        let triggered = await store.getAllTriggeredSurveys(for: userId)
        let pending = await store.getAllPendingSurveys(for: userId)
        return !triggered.isEmpty || !pending.isEmpty
    }
    
    /// Clean up old scheduled surveys
    public func cleanupOldScheduledSurveys(olderThan seconds: TimeInterval = 86400) async {
        let store = ScheduledSurveyStore(baseDirectory: storageBaseDirectoryURL)
        await store.cleanupOldScheduled(olderThan: seconds)
    }
    
    /// Manually apply retention policy to clean up old sessions and events
    public func applyRetentionPolicy() async {
        await coordinator.applyRetentionPolicy()
    }

    // MARK: - Storage & Analytics helpers
    public var storageBaseDirectoryURL: URL { baseDirectoryURL }
    public func storageBaseDirectory() async -> URL { baseDirectoryURL }
    public func listAllSessions() async -> [EventSession] { await coordinator.listAllSessions() }
    public func listSessions(forUserID userId: String?) async -> [EventSession] { await coordinator.listSessions(forUserID: userId) }
    public func events(forSessionID id: UUID) async -> [Event] { await coordinator.events(forSessionID: id) }
    
}
