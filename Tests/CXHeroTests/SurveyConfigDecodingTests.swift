import Foundation
import Testing
@testable import CXHero

@Test("Decodes legacy options array into response options")
func decodeLegacyOptions() async throws {
    let json = """
    {
      "surveys": [
        {
          "id": "legacy",
          "title": "Hi",
          "message": "Choose",
          "options": ["A", "B"],
          "trigger": { "event": { "name": "go" } }
        }
      ]
    }
    """
    let config = try SurveyConfig.from(data: Data(json.utf8))
    #expect(config.surveys.count == 1)
    guard case .options(let opts) = config.surveys[0].response else {
        Issue.record("Expected options response")
        return
    }
    #expect(opts == ["A", "B"])
}

@Test("Decodes text response configuration")
func decodeTextResponse() async throws {
    let json = """
    {
      "surveys": [
        {
          "id": "feedback",
          "title": "Feedback",
          "message": "Tell us",
          "response": {
            "type": "text",
            "placeholder": "Share…",
            "submitLabel": "Send",
            "allowEmpty": true,
            "minLength": 0,
            "maxLength": 250
          },
          "trigger": { "event": { "name": "done" } }
        }
      ]
    }
    """
    let config = try SurveyConfig.from(data: Data(json.utf8))
    guard case .text(let cfg) = config.surveys[0].response else {
        Issue.record("Expected text response")
        return
    }
    #expect(cfg.placeholder == "Share…")
    #expect(cfg.submitLabel == "Send")
    #expect(cfg.allowEmpty == true)
    #expect(cfg.minLength == 0)
    #expect(cfg.maxLength == 250)
}

