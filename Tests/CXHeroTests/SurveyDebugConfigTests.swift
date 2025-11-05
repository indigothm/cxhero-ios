import Foundation
import Testing
@testable import CXHero

@Test("SurveyDebugConfig production preset has expected defaults")
func debugConfigProductionDefaults() {
    let config = SurveyDebugConfig.production
    
    #expect(config.enabled == false)
    #expect(config.overrideScheduleDelay == nil)
    #expect(config.overrideAttemptCooldown == nil)
    #expect(config.bypassGating == false)
}

@Test("SurveyDebugConfig debug preset has expected values")
func debugConfigDebugPreset() {
    let config = SurveyDebugConfig.debug
    
    #expect(config.enabled == true)
    #expect(config.overrideScheduleDelay == 10)
    #expect(config.overrideAttemptCooldown == 15)
    #expect(config.bypassGating == true)
}

@Test("SurveyDebugConfig apply with production config returns unchanged")
func debugConfigApplyProductionUnchanged() throws {
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
    
    let productionConfig = SurveyDebugConfig.production
    let result = productionConfig.apply(to: originalConfig)
    
    // Should be unchanged
    #expect(result == originalConfig)
    
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 3600)
    #expect(result.surveys[0].attemptCooldownSeconds == 86400)
}

@Test("SurveyDebugConfig apply with debug overrides schedule delay")
func debugConfigApplyDebugOverridesDelay() throws {
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
    
    let debugConfig = SurveyDebugConfig.debug
    let result = debugConfig.apply(to: originalConfig)
    
    // Should override delays
    guard case .event(let trigger) = result.surveys[0].trigger else {
        throw TestError("Expected event trigger")
    }
    #expect(trigger.scheduleAfterSeconds == 10) // Debug override
    #expect(result.surveys[0].attemptCooldownSeconds == 15) // Debug override
}

@Test("SurveyDebugConfig apply preserves other survey properties")
func debugConfigApplyPreservesOtherProperties() throws {
    let originalConfig = SurveyConfig(surveys: [
        SurveyRule(
            ruleId: "test-rule",
            title: "Test Title",
            message: "Test Message",
            response: .options(["Option A", "Option B", "Option C"]),
            trigger: .event(EventTrigger(name: "member_checkin", scheduleAfterSeconds: 4200)),
            oncePerSession: true,
            oncePerUser: true,
            cooldownSeconds: 86400,
            maxAttempts: 3
        )
    ])
    
    let debugConfig = SurveyDebugConfig.debug
    let result = debugConfig.apply(to: originalConfig)
    
    // Properties should be preserved
    #expect(result.surveys[0].ruleId == "test-rule")
    #expect(result.surveys[0].title == "Test Title")
    #expect(result.surveys[0].message == "Test Message")
    #expect(result.surveys[0].oncePerSession == true)
    #expect(result.surveys[0].oncePerUser == true)
    #expect(result.surveys[0].cooldownSeconds == 86400)
    #expect(result.surveys[0].maxAttempts == 3)
    
    guard case .options(let opts) = result.surveys[0].response else {
        throw TestError("Expected options response")
    }
    #expect(opts == ["Option A", "Option B", "Option C"])
}

@Test("SurveyDebugConfig custom configuration")
func debugConfigCustom() {
    let custom = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: 5,
        overrideAttemptCooldown: 10,
        bypassGating: false
    )
    
    #expect(custom.enabled == true)
    #expect(custom.overrideScheduleDelay == 5)
    #expect(custom.overrideAttemptCooldown == 10)
    #expect(custom.bypassGating == false)
}

