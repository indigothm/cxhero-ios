import Foundation
import Testing
@testable import CXHero

@MainActor
@Test("Manual presentation shows a survey whose trigger never fired")
func manualPresentationShowsWithoutTrigger() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    let rule = SurveyRule(
        ruleId: "quick-checkin-cleanliness",
        title: "How clean is your club today?",
        message: "We'd love to hear your thoughts!",
        response: .combined(CombinedResponseConfig(
            options: ["Poor", "Fair", "Good", "Great", "Excellent"],
            optionsLabel: "Rate the cleanliness of your club today",
            textField: TextFieldConfig(placeholder: "Tell us more", required: false, maxLength: 500),
            submitLabel: "Submit Feedback"
        )),
        trigger: .event(EventTrigger(name: "shortcut_opened", properties: nil, scheduleAfterSeconds: nil)),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    let model = SurveyTriggerViewModel(config: SurveyConfig(surveys: [rule]), recorder: recorder)

    _ = await recorder.startSession(userID: "user-manual", metadata: nil)

    model.presentSurvey(ruleId: "quick-checkin-cleanliness")
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.isPresented == true)
    #expect(model.activeRule?.ruleId == "quick-checkin-cleanliness")
}

@MainActor
@Test("Manual presentation opens again after the survey was completed")
func manualPresentationBypassesCompletionGating() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    let rule = SurveyRule(
        ruleId: "repeatable-survey",
        title: "Quick question",
        message: "How was it?",
        response: .options(["Great", "Poor"]),
        trigger: .event(EventTrigger(name: "shortcut_opened", properties: nil, scheduleAfterSeconds: nil)),
        oncePerSession: false,
        oncePerUser: false,
        cooldownSeconds: 2592000
    )
    let model = SurveyTriggerViewModel(config: SurveyConfig(surveys: [rule]), recorder: recorder)

    _ = await recorder.startSession(userID: "user-repeat", metadata: nil)

    model.presentSurvey(ruleId: "repeatable-survey")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(model.isPresented == true)

    model.isPresented = false
    model.markSurveyCompleted(ruleId: "repeatable-survey")
    try await Task.sleep(nanoseconds: 300_000_000)

    // The event path now respects completion and cooldown...
    recorder.record("shortcut_opened")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(model.isPresented == false)

    // ...the member tapping the shortcut still gets the survey.
    model.presentSurvey(ruleId: "repeatable-survey")
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(model.isPresented == true)
}

@MainActor
@Test("Manual presentation ignores unknown rule ids")
func manualPresentationUnknownRule() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)

    let rule = SurveyRule(
        ruleId: "known-survey",
        title: "Quick question",
        message: "How was it?",
        response: .options(["Great", "Poor"]),
        trigger: .event(EventTrigger(name: "shortcut_opened", properties: nil, scheduleAfterSeconds: nil))
    )
    let model = SurveyTriggerViewModel(config: SurveyConfig(surveys: [rule]), recorder: recorder)

    _ = await recorder.startSession(userID: "user-unknown", metadata: nil)

    model.presentSurvey(ruleId: "not-in-config")
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.isPresented == false)
}