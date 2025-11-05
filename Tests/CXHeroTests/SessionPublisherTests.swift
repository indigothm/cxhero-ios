import Foundation
import Testing
import Combine
@testable import CXHero

@MainActor
@Test("Session publisher publishes started event when session starts")
func sessionPublisherStartedEvent() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    var receivedEvents: [SessionLifecycleEvent] = []
    
    let cancellable = recorder.sessionPublisher.sink { event in
        receivedEvents.append(event)
    }
    
    // Act
    let session = await recorder.startSession(userID: "test-user", metadata: ["key": .string("value")])
    
    // Wait for publisher
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    
    // Assert
    #expect(receivedEvents.count == 1)
    
    guard case .started(let publishedSession) = receivedEvents.first else {
        throw TestError("Expected .started event")
    }
    
    #expect(publishedSession.id == session.id)
    #expect(publishedSession.userId == "test-user")
    
    cancellable.cancel()
}

@MainActor
@Test("Session publisher publishes ended event when session ends")
func sessionPublisherEndedEvent() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    var receivedEvents: [SessionLifecycleEvent] = []
    
    let cancellable = recorder.sessionPublisher.sink { event in
        receivedEvents.append(event)
    }
    
    // Act
    let session = await recorder.startSession(userID: "test-user")
    try await Task.sleep(nanoseconds: 50_000_000)
    await recorder.endSession()
    try await Task.sleep(nanoseconds: 50_000_000)
    
    // Assert
    #expect(receivedEvents.count == 2)
    
    guard case .started = receivedEvents[0] else {
        throw TestError("Expected .started as first event")
    }
    
    guard case .ended(let endedSession) = receivedEvents[1] else {
        throw TestError("Expected .ended as second event")
    }
    
    #expect(endedSession?.id == session.id)
    
    cancellable.cancel()
}

@MainActor
@Test("Session publisher publishes ended with nil when no active session")
func sessionPublisherEndedNoActiveSession() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    var receivedEvents: [SessionLifecycleEvent] = []
    
    let cancellable = recorder.sessionPublisher.sink { event in
        receivedEvents.append(event)
    }
    
    // Act - end session without starting one
    await recorder.endSession()
    try await Task.sleep(nanoseconds: 50_000_000)
    
    // Assert
    #expect(receivedEvents.count == 1)
    
    guard case .ended(let endedSession) = receivedEvents[0] else {
        throw TestError("Expected .ended event")
    }
    
    #expect(endedSession == nil)
    
    cancellable.cancel()
}

@MainActor
@Test("Multiple subscribers receive session events")
func multipleSessionPublisherSubscribers() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    
    var subscriber1Events: [SessionLifecycleEvent] = []
    var subscriber2Events: [SessionLifecycleEvent] = []
    
    let cancellable1 = recorder.sessionPublisher.sink { subscriber1Events.append($0) }
    let cancellable2 = recorder.sessionPublisher.sink { subscriber2Events.append($0) }
    
    // Act
    await recorder.startSession(userID: "test-user")
    try await Task.sleep(nanoseconds: 50_000_000)
    
    // Assert
    #expect(subscriber1Events.count == 1)
    #expect(subscriber2Events.count == 1)
    
    guard case .started = subscriber1Events[0], case .started = subscriber2Events[0] else {
        throw TestError("Both subscribers should receive .started")
    }
    
    cancellable1.cancel()
    cancellable2.cancel()
}

@MainActor
@Test("Session publisher publishes started event when auto-starting via record")
func sessionPublisherAutoStartOnRecord() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    var receivedEvents: [SessionLifecycleEvent] = []
    
    let cancellable = recorder.sessionPublisher.sink { event in
        receivedEvents.append(event)
    }
    
    // Act - record event WITHOUT explicitly starting session
    // This should auto-start an anonymous session
    recorder.record("test_event", properties: ["key": .string("value")])
    
    // Wait for auto-start and publisher
    try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
    
    // Assert - should receive .started event from auto-start
    #expect(receivedEvents.count == 1)
    
    guard case .started(let session) = receivedEvents.first else {
        throw TestError("Expected .started event from auto-start")
    }
    
    // Auto-started session should be anonymous
    #expect(session.userId == nil)
    
    cancellable.cancel()
}

@MainActor
@Test("Auto-started session is available for subsequent records")
func autoStartedSessionPersists() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let recorder = EventRecorder(directory: tmp)
    var receivedEvents: [SessionLifecycleEvent] = []
    
    let cancellable = recorder.sessionPublisher.sink { event in
        receivedEvents.append(event)
    }
    
    // Act - record two events without explicit session
    recorder.record("event1")
    try await Task.sleep(nanoseconds: 100_000_000)
    recorder.record("event2")
    try await Task.sleep(nanoseconds: 100_000_000)
    
    // Assert - should only receive ONE .started (not two)
    #expect(receivedEvents.count == 1)
    
    guard case .started = receivedEvents.first else {
        throw TestError("Expected .started event")
    }
    
    // Both events should be in the same session
    let events = await recorder.eventsInCurrentSession()
    #expect(events.count == 2)
    #expect(events[0].name == "event1")
    #expect(events[1].name == "event2")
    #expect(events[0].sessionId == events[1].sessionId)
    
    cancellable.cancel()
}

