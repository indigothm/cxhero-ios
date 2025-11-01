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

    private var currentSession: EventSession?
    private var currentStore: EventStore?

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func startSession(userID: String?, metadata: [String: EventValue]?) async -> EventSession {
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

    func record(name: String, properties: [String: EventValue]?) async -> Event? {
        // Ensure we have a session; start an anonymous one if needed
        if currentSession == nil || currentStore == nil {
            _ = await startSession(userID: nil, metadata: nil)
        }
        guard let session = currentSession, let store = currentStore else { return nil }

        let event = Event(
            name: name,
            properties: properties,
            sessionId: session.id,
            userId: session.userId
        )
        await store.append(event)
        return event
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

    private func safeUserFolder(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else { return "anon" }
        // Restrict to a safe subset for filesystem names
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_@."))
        let cleaned = userId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "", { $0.append($1) })
        return cleaned
    }
}

/// Public singleton interface for recording and inspecting events with session scoping.
public final class EventRecorder: @unchecked Sendable {
    public static let shared = EventRecorder()

    private let coordinator: SessionCoordinator
    private let baseDirectoryURL: URL
    private let subject = PassthroughSubject<Event, Never>()

    /// Designated initializer.
    /// - Parameters:
    ///   - directory: Base directory to store user/session-scoped data. Defaults to the app's Documents/CXHero directory.
    public init(directory: URL? = nil) {
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
        self.coordinator = SessionCoordinator(baseDirectory: base)
    }

    // MARK: - Session API
    @discardableResult
    public func startSession(userID: String? = nil, metadata: [String: EventValue]? = nil) async -> EventSession {
        await coordinator.startSession(userID: userID, metadata: metadata)
    }

    public func endSession() async {
        await coordinator.endSession()
    }

    public func currentSession() async -> EventSession? {
        await coordinator.currentSessionInfo()
    }

    // MARK: - Event API
    public func record(_ name: String, properties: [String: EventValue]? = nil) {
        Task {
            if let event = await coordinator.record(name: name, properties: properties) {
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

    // MARK: - Storage & Analytics helpers
    public var storageBaseDirectoryURL: URL { baseDirectoryURL }
    public func storageBaseDirectory() async -> URL { baseDirectoryURL }
    public func listAllSessions() async -> [EventSession] { await coordinator.listAllSessions() }
    public func listSessions(forUserID userId: String?) async -> [EventSession] { await coordinator.listSessions(forUserID: userId) }
    public func events(forSessionID id: UUID) async -> [Event] { await coordinator.events(forSessionID: id) }
}
