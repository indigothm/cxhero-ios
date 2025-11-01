import Foundation
import Testing
@testable import CXHero

private func iso8601Now() -> String {
    let fmt = ISO8601DateFormatter()
    return fmt.string(from: Date())
}

private func iso8601Past(seconds: TimeInterval) -> String {
    let fmt = ISO8601DateFormatter()
    return fmt.string(from: Date().addingTimeInterval(-seconds))
}

private func writeGating(base: URL, userId: String, ruleId: String, lastShownISO8601: String) throws {
    let userFolder = userId // safeUserFolder allows '-', '_' and digits; this ID uses only allowed chars
    let dir = base
        .appendingPathComponent("users")
        .appendingPathComponent(userFolder)
        .appendingPathComponent("surveys")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload: [String: Any] = [
        "rules": [
            ruleId: [
                "lastShownAt": lastShownISO8601,
                "shownOnce": true
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    try data.write(to: dir.appendingPathComponent("gating.json"), options: .atomic)
}

@MainActor
@Test("First event respects once-per-user gating")
func firstEventRespectsGating() async throws {
    // Arrange a temp base directory
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    // Pre-populate gating so the rule should be blocked for this user
    try writeGating(base: recorder.storageBaseDirectoryURL, userId: "user-abc", ruleId: "ask", lastShownISO8601: iso8601Now())

    // Build a config with oncePerUser true
    let rule = SurveyRule(
        ruleId: "ask",
        title: "Quick",
        message: "Rate us",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "play", properties: nil)),
        oncePerSession: true,
        oncePerUser: true,
        cooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)

    // Start a session for this user and record the triggering event
    _ = await recorder.startSession(userID: "user-abc", metadata: nil)
    recorder.record("play")

    // Allow propagation
    try await Task.sleep(nanoseconds: 200_000_000)

    // Assert not presented due to gating
    #expect(model.isPresented == false)
}

@MainActor
@Test("Cooldown blocks within window")
func cooldownBlocks() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    // Pre-populate gating with lastShownAt now
    try writeGating(base: recorder.storageBaseDirectoryURL, userId: "user-xyz", ruleId: "cooldown", lastShownISO8601: iso8601Now())

    let rule = SurveyRule(
        ruleId: "cooldown",
        title: "Hello",
        message: "Wait",
        response: .options(["OK"]),
        trigger: .event(EventTrigger(name: "launch", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: 3600
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)

    _ = await recorder.startSession(userID: "user-xyz", metadata: nil)
    recorder.record("launch")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(model.isPresented == false)
}

@MainActor
@Test("Presents when gating allows")
func presentsWhenAllowed() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    // No gating prepopulation; should allow
    let rule = SurveyRule(
        ruleId: "ok",
        title: "Hi",
        message: "Tell us",
        response: .options(["A", "B"]),
        trigger: .event(EventTrigger(name: "go", properties: nil)),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)

    _ = await recorder.startSession(userID: "user-ok", metadata: nil)
    recorder.record("go")
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(model.isPresented == true)
}

@MainActor
@Test("Cooldown expired allows presentation")
func cooldownExpiredAllows() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    // Pre-populate gating with lastShownAt sufficiently in the past (2 hours)
    try writeGating(base: recorder.storageBaseDirectoryURL, userId: "user-cool", ruleId: "cool", lastShownISO8601: iso8601Past(seconds: 7200))

    let rule = SurveyRule(
        ruleId: "cool",
        title: "Hi",
        message: "Again",
        response: .options(["OK"]),
        trigger: .event(EventTrigger(name: "open", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: 3600
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)

    _ = await recorder.startSession(userID: "user-cool", metadata: nil)
    recorder.record("open")
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(model.isPresented == true)
}
