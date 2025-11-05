import Foundation
import Testing
@testable import CXHero

@Test("loadFromBundle throws error when file not found")
func loadFromBundleFileNotFound() async throws {
    // Act & Assert
    #expect(throws: Error.self) {
        try SurveyConfig.loadFromBundle(
            resourceName: "nonexistent-file",
            bundle: .main
        )
    }
}

@Test("loadFromBundle with production config returns unmodified config")
func loadFromBundleProductionUnmodified() async throws {
    // Arrange - create temp bundle with config file
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let configJSON = """
    {
      "surveys": [
        {
          "id": "test-survey",
          "title": "Test",
          "message": "Test message",
          "response": {
            "type": "options",
            "options": ["A", "B", "C"]
          },
          "trigger": {
            "event": {
              "name": "test_event",
              "scheduleAfterSeconds": 3600
            }
          }
        }
      ]
    }
    """
    
    let configURL = tmp.appendingPathComponent("test-config.json")
    try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
    
    // Act
    let config = try SurveyConfig.from(url: configURL)
    let productionResult = SurveyDebugConfig.production.apply(to: config)
    
    // Assert - should be unchanged
    #expect(productionResult.surveys.count == 1)
    guard case .event(let trigger) = productionResult.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 3600)
}

@Test("loadFromBundle with debug config overrides delays")
func loadFromBundleDebugOverrides() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let configJSON = """
    {
      "surveys": [
        {
          "id": "test-survey",
          "title": "Test",
          "message": "Test message",
          "response": {
            "type": "options",
            "options": ["A", "B"]
          },
          "trigger": {
            "event": {
              "name": "test_event",
              "scheduleAfterSeconds": 4200
            }
          },
          "attemptCooldownSeconds": 86400
        }
      ]
    }
    """
    
    let configURL = tmp.appendingPathComponent("test-config.json")
    try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
    
    // Act
    let config = try SurveyConfig.from(url: configURL)
    let debugResult = SurveyDebugConfig.debug.apply(to: config)
    
    // Assert - should have debug overrides
    #expect(debugResult.surveys.count == 1)
    guard case .event(let trigger) = debugResult.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 10) // Debug override
    #expect(debugResult.surveys[0].attemptCooldownSeconds == 15) // Debug override
}

@Test("loadFromBundle with custom debug config applies custom overrides")
func loadFromBundleCustomDebugConfig() async throws {
    // Arrange
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    
    let configJSON = """
    {
      "surveys": [
        {
          "id": "test",
          "title": "Test",
          "message": "Message",
          "response": { "type": "options", "options": ["A"] },
          "trigger": {
            "event": {
              "name": "test_event",
              "scheduleAfterSeconds": 1000
            }
          },
          "attemptCooldownSeconds": 5000
        }
      ]
    }
    """
    
    let configURL = tmp.appendingPathComponent("test-config.json")
    try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
    
    // Act
    let config = try SurveyConfig.from(url: configURL)
    let customDebug = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: 3,
        overrideAttemptCooldown: 7,
        bypassGating: true
    )
    let result = customDebug.apply(to: config)
    
    // Assert
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 3) // Custom override
    #expect(result.surveys[0].attemptCooldownSeconds == 7) // Custom override
}

@Test("Debug config apply handles multiple surveys")
func debugConfigApplyMultipleSurveys() throws {
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "survey-1",
            title: "Survey 1",
            message: "Message",
            response: .options(["A"]),
            trigger: .event(EventTrigger(name: "event1", scheduleAfterSeconds: 100))
        ),
        SurveyRule(
            ruleId: "survey-2",
            title: "Survey 2",
            message: "Message",
            response: .options(["B"]),
            trigger: .event(EventTrigger(name: "event2", scheduleAfterSeconds: 200))
        )
    ])
    
    let debugConfig = SurveyDebugConfig.debug
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - both should be overridden
    #expect(result.surveys.count == 2)
    
    for survey in result.surveys {
        guard case .event(let trigger) = survey.trigger else {
            throw TestError("Expected event trigger")
        }
        #expect(trigger.scheduleAfterSeconds == 10) // Debug override
    }
}

