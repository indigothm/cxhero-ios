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

private func writeGatingWithAttempts(base: URL, userId: String, ruleId: String, lastShownISO8601: String, attemptCount: Int, completedOnce: Bool = false) throws {
    let userFolder = userId
    let dir = base
        .appendingPathComponent("users")
        .appendingPathComponent(userFolder)
        .appendingPathComponent("surveys")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let payload: [String: Any] = [
        "rules": [
            ruleId: [
                "lastShownAt": lastShownISO8601,
                "shownOnce": true,
                "attemptCount": attemptCount,
                "completedOnce": completedOnce
            ]
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    try data.write(to: dir.appendingPathComponent("gating.json"), options: .atomic)
}

@MainActor
@Test("MaxAttempts blocks after reaching limit")
func maxAttemptsBlocksAfterLimit() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    // Pre-populate gating with 3 attempts (reached max)
    try writeGatingWithAttempts(base: recorder.storageBaseDirectoryURL, userId: "user-max", ruleId: "survey1", lastShownISO8601: iso8601Past(seconds: 3600), attemptCount: 3)
    
    let rule = SurveyRule(
        ruleId: "survey1",
        title: "Survey",
        message: "Please answer",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "scan", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-max", metadata: nil)
    recorder.record("scan")
    try await Task.sleep(nanoseconds: 250_000_000)
    
    // Should be blocked because attemptCount (3) >= maxAttempts (3)
    #expect(model.isPresented == false)
}

@MainActor
@Test("MaxAttempts allows when under limit")
func maxAttemptsAllowsUnderLimit() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    // Pre-populate gating with 2 attempts (under max of 3)
    try writeGatingWithAttempts(base: recorder.storageBaseDirectoryURL, userId: "user-under", ruleId: "survey2", lastShownISO8601: iso8601Past(seconds: 3600), attemptCount: 2)
    
    let rule = SurveyRule(
        ruleId: "survey2",
        title: "Survey",
        message: "Please answer",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "scan", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: 3600
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-under", metadata: nil)
    recorder.record("scan")
    try await Task.sleep(nanoseconds: 250_000_000)
    
    // Should be allowed because attemptCount (2) < maxAttempts (3) and cooldown expired
    #expect(model.isPresented == true)
}

@MainActor
@Test("Completed survey blocks future attempts")
func completedSurveyBlocksFuture() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    // Pre-populate gating with completed survey
    try writeGatingWithAttempts(base: recorder.storageBaseDirectoryURL, userId: "user-completed", ruleId: "survey3", lastShownISO8601: iso8601Past(seconds: 3600), attemptCount: 1, completedOnce: true)
    
    let rule = SurveyRule(
        ruleId: "survey3",
        title: "Survey",
        message: "Please answer",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "scan", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-completed", metadata: nil)
    recorder.record("scan")
    try await Task.sleep(nanoseconds: 250_000_000)
    
    // Should be blocked because survey was already completed
    #expect(model.isPresented == false)
}

@MainActor
@Test("Attempt cooldown blocks re-attempts within window")
func attemptCooldownBlocks() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    // Pre-populate gating with recent attempt (1 minute ago)
    try writeGatingWithAttempts(base: recorder.storageBaseDirectoryURL, userId: "user-cooldown", ruleId: "survey4", lastShownISO8601: iso8601Past(seconds: 60), attemptCount: 1)
    
    let rule = SurveyRule(
        ruleId: "survey4",
        title: "Survey",
        message: "Please answer",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "scan", properties: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: 3600 // 1 hour cooldown
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-cooldown", metadata: nil)
    recorder.record("scan")
    try await Task.sleep(nanoseconds: 250_000_000)
    
    // Should be blocked because attempt cooldown not expired
    #expect(model.isPresented == false)
}

@MainActor
@Test("First attempt increments counter")
func firstAttemptIncrementsCounter() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let rule = SurveyRule(
        ruleId: "survey5",
        title: "Survey",
        message: "Please answer",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(name: "scan", properties: nil)),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-new", metadata: nil)
    recorder.record("scan")
    try await Task.sleep(nanoseconds: 250_000_000)
    
    // Survey should be presented
    #expect(model.isPresented == true)
    
    // Check that gating file was created with attemptCount = 1
    let gatingStore = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
    let canShow = await gatingStore.canShow(
        ruleId: "survey5",
        forUser: "user-new",
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: nil
    )
    
    // Should still be able to show (attemptCount is now 1, max is 3)
    #expect(canShow == true)
}


// MARK: - Recurring surveys

private let month: TimeInterval = 2_592_000

@Test("Recurring survey is blocked within its cooldown even after completion")
func recurringBlockedWithinCooldown() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try writeGatingWithAttempts(base: base, userId: "u", ruleId: "r", lastShownISO8601: iso8601Past(seconds: 10 * 86_400), attemptCount: 1, completedOnce: true)
    let store = SurveyGatingStore(baseDirectory: base)
    let allowed = await store.canShow(ruleId: "r", forUser: "u", oncePerUser: nil, cooldownSeconds: month, maxAttempts: nil, attemptCooldownSeconds: nil, recurring: true)
    #expect(allowed == false)
}

@Test("Recurring survey shows again after its cooldown, completed or not")
func recurringReturnsAfterCooldown() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try writeGatingWithAttempts(base: base, userId: "u", ruleId: "r", lastShownISO8601: iso8601Past(seconds: month + 3_600), attemptCount: 5, completedOnce: true)
    let store = SurveyGatingStore(baseDirectory: base)
    let recurring = await store.canShow(ruleId: "r", forUser: "u", oncePerUser: nil, cooldownSeconds: month, maxAttempts: 1, attemptCooldownSeconds: nil, recurring: true)
    #expect(recurring == true)
    // The same history retires a non-recurring rule for good.
    let oneOff = await store.canShow(ruleId: "r", forUser: "u", oncePerUser: nil, cooldownSeconds: month, maxAttempts: 1, attemptCooldownSeconds: nil)
    #expect(oneOff == false)
}

@Test("Recurring decodes from JSON and defaults to nil")
func recurringDecodes() throws {
    let json = #"{"surveys":[{"id":"a","title":"t","message":"m","options":["x"],"trigger":{"event":{"name":"e"}},"recurring":true},{"id":"b","title":"t","message":"m","options":["x"],"trigger":{"event":{"name":"e"}}}]}"#
    let config = try SurveyConfig.from(data: Data(json.utf8))
    #expect(config.surveys[0].recurring == true)
    #expect(config.surveys[1].recurring == nil)
}
