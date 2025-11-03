import Foundation
import Testing
@testable import CXHero

@MainActor
@Test("Combined response decodes correctly from JSON")
func combinedResponseDecoding() throws {
    let json = """
    {
      "id": "test-combined",
      "title": "Test Survey",
      "message": "Test message",
      "response": {
        "type": "combined",
        "options": ["Poor", "Fair", "Good"],
        "optionsLabel": "Rate your experience",
        "textField": {
          "label": "Additional comments",
          "placeholder": "Tell us more",
          "required": false,
          "maxLength": 500
        },
        "submitLabel": "Submit"
      },
      "trigger": {
        "event": {
          "name": "test_event"
        }
      }
    }
    """
    
    let data = json.data(using: .utf8)!
    let rule = try JSONDecoder().decode(SurveyRule.self, from: data)
    
    #expect(rule.ruleId == "test-combined")
    
    guard case .combined(let config) = rule.response else {
        throw TestError("Expected combined response")
    }
    
    #expect(config.options == ["Poor", "Fair", "Good"])
    #expect(config.optionsLabel == "Rate your experience")
    #expect(config.submitLabel == "Submit")
    #expect(config.textField != nil)
    #expect(config.textField?.label == "Additional comments")
    #expect(config.textField?.placeholder == "Tell us more")
    #expect(config.textField?.required == false)
    #expect(config.textField?.maxLength == 500)
}

@MainActor
@Test("Combined response without text field decodes correctly")
func combinedResponseWithoutTextField() throws {
    let json = """
    {
      "id": "test-rating-only",
      "title": "Quick Survey",
      "message": "Rate us",
      "response": {
        "type": "combined",
        "options": ["1", "2", "3", "4", "5"],
        "submitLabel": "Submit Rating"
      },
      "trigger": {
        "event": {
          "name": "test_event"
        }
      }
    }
    """
    
    let data = json.data(using: .utf8)!
    let rule = try JSONDecoder().decode(SurveyRule.self, from: data)
    
    guard case .combined(let config) = rule.response else {
        throw TestError("Expected combined response")
    }
    
    #expect(config.options == ["1", "2", "3", "4", "5"])
    #expect(config.textField == nil)
    #expect(config.submitLabel == "Submit Rating")
}

@MainActor
@Test("Combined response encodes and decodes correctly")
func combinedResponseRoundTrip() throws {
    let textField = TextFieldConfig(
        label: "Comments",
        placeholder: "Your feedback",
        required: true,
        minLength: 10,
        maxLength: 200
    )
    
    let config = CombinedResponseConfig(
        options: ["Yes", "No", "Maybe"],
        optionsLabel: "Would you recommend us?",
        textField: textField,
        submitLabel: "Send Feedback"
    )
    
    let response = SurveyResponse.combined(config)
    
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    let data = try encoder.encode(response)
    let decoded = try decoder.decode(SurveyResponse.self, from: data)
    
    #expect(response == decoded)
    
    guard case .combined(let decodedConfig) = decoded else {
        throw TestError("Expected combined response")
    }
    
    #expect(decodedConfig.options == ["Yes", "No", "Maybe"])
    #expect(decodedConfig.optionsLabel == "Would you recommend us?")
    #expect(decodedConfig.textField?.label == "Comments")
    #expect(decodedConfig.textField?.required == true)
    #expect(decodedConfig.textField?.minLength == 10)
    #expect(decodedConfig.textField?.maxLength == 200)
}

@MainActor
@Test("Combined response trigger shows survey")
func combinedResponseTriggersCorrectly() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let recorder = EventRecorder(directory: tmp)
    
    let textField = TextFieldConfig(
        label: "Comments",
        placeholder: "Optional feedback",
        required: false,
        maxLength: 500
    )
    
    let rule = SurveyRule(
        ruleId: "combined-test",
        title: "Rate Us",
        message: "How did we do?",
        response: .combined(CombinedResponseConfig(
            options: ["Poor", "Good", "Excellent"],
            optionsLabel: "Your rating",
            textField: textField,
            submitLabel: "Submit"
        )),
        trigger: .event(EventTrigger(name: "action", properties: nil)),
        oncePerSession: true,
        oncePerUser: false,
        cooldownSeconds: nil
    )
    
    let config = SurveyConfig(surveys: [rule])
    let model = SurveyTriggerViewModel(config: config, recorder: recorder)
    
    _ = await recorder.startSession(userID: "test-user", metadata: nil)
    recorder.record("action")
    
    try await Task.sleep(nanoseconds: 250_000_000)
    
    #expect(model.isPresented == true)
    #expect(model.activeRule?.ruleId == "combined-test")
}

struct TestError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

