import Foundation
import Testing
@testable import CXHero

@Test("Attempt cooldown override works independently of delay override")
func attemptCooldownOverrideIndependent() throws {
    // Arrange
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test",
            title: "Test",
            message: "Message",
            response: .options(["A", "B"]),
            trigger: .event(EventTrigger(name: "test", scheduleAfterSeconds: 3600)),
            attemptCooldownSeconds: 86400
        )
    ])
    
    // Create debug config with ONLY attempt cooldown override (no delay override)
    let debugConfig = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: nil,  // Keep production delay
        overrideAttemptCooldown: 15,  // Override cooldown only
        bypassGating: false
    )
    
    // Act
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - attempt cooldown should be overridden
    #expect(result.surveys[0].attemptCooldownSeconds == 15)
    
    // But delay should remain unchanged
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 3600) // Original production delay
}

@Test("Delay override works independently of attempt cooldown override")
func delayOverrideIndependent() throws {
    // Arrange
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test",
            title: "Test",
            message: "Message",
            response: .options(["A", "B"]),
            trigger: .event(EventTrigger(name: "test", scheduleAfterSeconds: 3600)),
            attemptCooldownSeconds: 86400
        )
    ])
    
    // Create debug config with ONLY delay override (no cooldown override)
    let debugConfig = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: 10,  // Override delay only
        overrideAttemptCooldown: nil,  // Keep production cooldown
        bypassGating: false
    )
    
    // Act
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - delay should be overridden
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 10)
    
    // But attempt cooldown should remain unchanged
    #expect(result.surveys[0].attemptCooldownSeconds == 86400) // Original
}

@Test("Both overrides work together")
func bothOverridesTogether() throws {
    // Arrange
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test",
            title: "Test",
            message: "Message",
            response: .options(["A", "B"]),
            trigger: .event(EventTrigger(name: "test", scheduleAfterSeconds: 3600)),
            attemptCooldownSeconds: 86400
        )
    ])
    
    // Create debug config with BOTH overrides
    let debugConfig = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: 10,
        overrideAttemptCooldown: 15,
        bypassGating: true
    )
    
    // Act
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - both should be overridden
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 10)
    #expect(result.surveys[0].attemptCooldownSeconds == 15)
}

@Test("Neither override when both nil")
func neitherOverride() throws {
    // Arrange
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test",
            title: "Test",
            message: "Message",
            response: .options(["A", "B"]),
            trigger: .event(EventTrigger(name: "test", scheduleAfterSeconds: 3600)),
            attemptCooldownSeconds: 86400
        )
    ])
    
    // Create debug config with enabled but NO overrides
    let debugConfig = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: nil,
        overrideAttemptCooldown: nil,
        bypassGating: true
    )
    
    // Act
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - nothing should change
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 3600)
    #expect(result.surveys[0].attemptCooldownSeconds == 86400)
}

@Test("Override applies to survey without original attemptCooldownSeconds")
func overrideOnSurveyWithoutCooldown() throws {
    // Arrange
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test",
            title: "Test",
            message: "Message",
            response: .options(["A", "B"]),
            trigger: .event(EventTrigger(name: "test", scheduleAfterSeconds: 3600)),
            attemptCooldownSeconds: nil  // No original cooldown
        )
    ])
    
    // Create debug config with attempt cooldown override
    let debugConfig = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: nil,
        overrideAttemptCooldown: 15,
        bypassGating: false
    )
    
    // Act
    let result = debugConfig.apply(to: originalConfig)
    
    // Assert - cooldown should be added
    #expect(result.surveys[0].attemptCooldownSeconds == 15)
}




