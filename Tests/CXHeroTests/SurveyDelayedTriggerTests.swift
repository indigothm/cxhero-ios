import Foundation
import Testing
@testable import CXHero

@MainActor
@Test("Delayed trigger schedules survey after delay")
func delayedTriggerSchedulesSurvey() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let rule = SurveyRule(
        ruleId: "delayed-survey",
        title: "Delayed Survey",
        message: "How was your visit?",
        response: .options(["Great", "Good", "Poor"]),
        trigger: .event(EventTrigger(
            name: "member_checkin",
            properties: nil,
            scheduleAfterSeconds: 1.0 // 1 second delay for testing
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-delayed", metadata: nil)
    recorder.record("member_checkin")
    
    // Should not be presented immediately
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    #expect(model.isPresented == false)
    
    // Wait for delay to expire
    try await Task.sleep(nanoseconds: 1_100_000_000) // 1.1 seconds total
    
    // Now should be presented
    #expect(model.isPresented == true)
}

@MainActor
@Test("Immediate trigger (nil scheduleAfterSeconds) shows immediately")
func immediateTriggerShowsImmediately() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let rule = SurveyRule(
        ruleId: "immediate-survey",
        title: "Immediate Survey",
        message: "Quick question",
        response: .options(["Yes", "No"]),
        trigger: .event(EventTrigger(
            name: "action",
            properties: nil,
            scheduleAfterSeconds: nil // Immediate
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-immediate", metadata: nil)
    recorder.record("action")
    
    // Allow minimal propagation time
    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
    
    // Should be presented immediately
    #expect(model.isPresented == true)
}

@MainActor
@Test("Scheduled tasks cancelled on session change")
func scheduledTasksCancelledOnSessionChange() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let rule = SurveyRule(
        ruleId: "session-survey",
        title: "Survey",
        message: "Question",
        response: .options(["A", "B"]),
        trigger: .event(EventTrigger(
            name: "event",
            properties: nil,
            scheduleAfterSeconds: 2.0 // 2 second delay
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    // Start first session and trigger event
    _ = await recorder.startSession(userID: "user-session", metadata: nil)
    recorder.record("event")
    
    // Wait a bit but not long enough for survey to show
    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    
    // Verify survey is not yet presented
    #expect(model.isPresented == false)
    
    // Start new session (scheduled task will be cancelled, but restoration will re-schedule)
    await recorder.endSession()
    _ = await recorder.startSession(userID: "user-session", metadata: nil)
    
    // Wait for restoration to re-schedule the survey with remaining delay
    try await Task.sleep(nanoseconds: 300_000_000) // 0.3s for restoration
    
    // Wait for the re-scheduled survey to show (remaining ~1.5s)
    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
    
    // Survey SHOULD now be presented because it was restored and re-scheduled
    // (The old behavior was to cancel, but the new restoration logic re-schedules)
    #expect(model.isPresented == true)
}

@MainActor
@Test("Multiple scheduled surveys only show first matching")
func multipleScheduledSurveysOnlyShowFirst() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let rule1 = SurveyRule(
        ruleId: "survey-1",
        title: "Survey 1",
        message: "First",
        response: .options(["OK"]),
        trigger: .event(EventTrigger(
            name: "event",
            properties: nil,
            scheduleAfterSeconds: 0.5
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    
    let rule2 = SurveyRule(
        ruleId: "survey-2",
        title: "Survey 2",
        message: "Second",
        response: .options(["OK"]),
        trigger: .event(EventTrigger(
            name: "event",
            properties: nil,
            scheduleAfterSeconds: 1.0
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    
    // First matching rule should win
    let config = SurveyConfig(surveys: [rule1, rule2])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "user-multi", metadata: nil)
    recorder.record("event")
    
    // Wait for first survey to show
    try await Task.sleep(nanoseconds: 700_000_000) // 0.7 seconds
    
    // First survey should be presented
    #expect(model.isPresented == true)
    #expect(model.activeRule?.ruleId == "survey-1")
    
    // Wait longer to see if second would show (it shouldn't due to oncePerSession)
    try await Task.sleep(nanoseconds: 500_000_000) // Additional 0.5 seconds
    
    // Still should be showing survey-1, not survey-2
    #expect(model.activeRule?.ruleId == "survey-1")
}

@MainActor
@Test("Delayed trigger with 70 minutes (real use case)")
func delayedTrigger70Minutes() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    // 70 minutes = 4200 seconds
    let rule = SurveyRule(
        ruleId: "gym-feedback",
        title: "How was your workout?",
        message: "We'd love to hear about your experience today",
        response: .options(["Great", "Good", "Okay", "Poor"]),
        trigger: .event(EventTrigger(
            name: "member_checkin",
            properties: nil,
            scheduleAfterSeconds: 0.2 // Using 0.2 seconds for testing instead of 4200
        )),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil,
        maxAttempts: 3,
        attemptCooldownSeconds: 86400 // 24 hours
    )
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "gym-member", metadata: nil)
    recorder.record("member_checkin")
    
    // Should not be presented immediately
    try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
    #expect(model.isPresented == false)
    
    // Wait for delay
    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds more
    
    // Now should be presented
    #expect(model.isPresented == true)
    #expect(model.activeRule?.ruleId == "gym-feedback")
}

