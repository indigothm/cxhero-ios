import Foundation

/// Configuration for debug/testing mode behavior of surveys
public struct SurveyDebugConfig: Sendable {
    /// Enable debug mode (bypasses gating, modifies delays)
    public let enabled: Bool
    
    /// Override all survey scheduleAfterSeconds delays (e.g., 60 seconds for testing)
    public let overrideScheduleDelay: TimeInterval?
    
    /// Override all attemptCooldownSeconds (e.g., 15 seconds for testing)
    public let overrideAttemptCooldown: TimeInterval?
    
    /// Bypass all gating checks (oncePerUser, cooldowns, maxAttempts)
    public let bypassGating: Bool
    
    public init(
        enabled: Bool,
        overrideScheduleDelay: TimeInterval? = nil,
        overrideAttemptCooldown: TimeInterval? = nil,
        bypassGating: Bool = false
    ) {
        self.enabled = enabled
        self.overrideScheduleDelay = overrideScheduleDelay
        self.overrideAttemptCooldown = overrideAttemptCooldown
        self.bypassGating = bypassGating
    }
    
    /// Production configuration - all debug features disabled
    public static nonisolated(unsafe) let production = SurveyDebugConfig(
        enabled: false,
        overrideScheduleDelay: nil,
        overrideAttemptCooldown: nil,
        bypassGating: false
    )
    
    /// Debug configuration - fast delays, bypassed gating
    public static nonisolated(unsafe) let debug = SurveyDebugConfig(
        enabled: true,
        overrideScheduleDelay: 60,  // 60 seconds instead of production timing
        overrideAttemptCooldown: 15,  // 15 seconds instead of 24 hours
        bypassGating: true  // Show every time, ignore completion/attempts
    )
    
    /// Apply debug overrides to a survey config
    internal func apply(to config: SurveyConfig) -> SurveyConfig {
        guard enabled else { return config }
        
        let modifiedSurveys = config.surveys.map { survey in
            var modifiedSurvey = survey
            var needsRebuild = false
            var modifiedTrigger = survey.trigger
            var modifiedAttemptCooldown = survey.attemptCooldownSeconds
            
            // Override trigger delays if specified
            if case .event(let eventTrigger) = survey.trigger,
               let overrideDelay = overrideScheduleDelay {
                modifiedTrigger = TriggerCondition.event(EventTrigger(
                    name: eventTrigger.name,
                    properties: eventTrigger.properties,
                    scheduleAfterSeconds: overrideDelay
                ))
                needsRebuild = true
            }
            
            // Override attempt cooldown if specified (independent of delay override)
            if let overrideCooldown = overrideAttemptCooldown {
                modifiedAttemptCooldown = overrideCooldown
                needsRebuild = true
            }
            
            // Rebuild survey rule if any overrides were applied
            if needsRebuild {
                modifiedSurvey = SurveyRule(
                    ruleId: survey.ruleId,
                    title: survey.title,
                    message: survey.message,
                    response: survey.response,
                    trigger: modifiedTrigger,
                    oncePerSession: survey.oncePerSession,
                    oncePerUser: survey.oncePerUser,
                    cooldownSeconds: survey.cooldownSeconds,
                    maxAttempts: survey.maxAttempts,
                    attemptCooldownSeconds: modifiedAttemptCooldown,
                    notification: survey.notification
                )
            }
            
            return modifiedSurvey
        }
        
        return SurveyConfig(surveys: modifiedSurveys)
    }
}

