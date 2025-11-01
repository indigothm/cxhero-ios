import Foundation
import Testing
@testable import CXHero

@Test("Start session (with user), record and read session-scoped events")
func sessionRecordAndRead() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    let session = await recorder.startSession(userID: "user 123", metadata: ["plan": .string("pro")])

    // Act
    recorder.record("test_event", properties: [
        "s": .string("ok"),
        "i": .int(42),
        "d": .double(3.14),
        "b": .bool(true)
    ])

    try await Task.sleep(nanoseconds: 150_000_000)

    let currentEvents = await recorder.eventsInCurrentSession()
    let all = await recorder.allEvents()

    // Assert
    #expect(currentEvents.count == 1)
    #expect(all.count == 1)
    #expect(currentEvents.first?.name == "test_event")
    #expect(currentEvents.first?.properties?["i"] == .int(42))
    #expect(currentEvents.first?.sessionId == session.id)
    #expect(currentEvents.first?.userId == session.userId)

    // Clear everything
    await recorder.clear()
    let afterClear = await recorder.allEvents()
    #expect(afterClear.isEmpty)
}

@Test("List sessions and fetch per-session events")
func listSessionsAndEvents() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    let s1 = await recorder.startSession(userID: "u1", metadata: nil)
    recorder.record("e1")
    try await Task.sleep(nanoseconds: 120_000_000)
    await recorder.endSession()

    let s2 = await recorder.startSession(userID: "u2", metadata: nil)
    recorder.record("e2")
    try await Task.sleep(nanoseconds: 120_000_000)

    let allSessions = await recorder.listAllSessions()
    let u1Sessions = await recorder.listSessions(forUserID: "u1")
    let eventsInS1 = await recorder.events(forSessionID: s1.id)
    let eventsInS2 = await recorder.events(forSessionID: s2.id)

    #expect(allSessions.count >= 2)
    #expect(u1Sessions.contains(where: { $0.id == s1.id }))
    #expect(eventsInS1.count == 1)
    #expect(eventsInS2.count == 1)
}
