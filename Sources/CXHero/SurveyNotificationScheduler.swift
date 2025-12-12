import Foundation
import UserNotifications

/// Handles scheduling and managing local notifications for delayed surveys
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
public actor SurveyNotificationScheduler {
    private let notificationCenter: UNUserNotificationCenter
    
    public init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }
    
    /// Check if notification permissions are authorized
    public func checkPermissions() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus == .authorized
    }
    
    /// Request notification permissions
    public func requestPermissions() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }
    
    /// Schedule a notification for a survey
    public func schedule(
        ruleId: String,
        sessionId: String,
        notificationConfig: NotificationConfig,
        triggerAfterSeconds: TimeInterval
    ) async {
        // Check permissions first
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            print("[CXHero-Notification] ⚠️ Notification permission not authorized, skipping schedule")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = notificationConfig.title
        content.body = notificationConfig.body
        if notificationConfig.sound {
            content.sound = .default
        }
        
        // Add metadata to identify the survey
        content.userInfo = [
            "surveyId": ruleId,
            "sessionId": sessionId,
            "source": "cxhero"
        ]
        
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: triggerAfterSeconds,
            repeats: false
        )
        
        let identifier = notificationIdentifier(ruleId: ruleId, sessionId: sessionId)
        
        // Deduplicate: if we already have a pending request with the same identifier, don't re-add.
        // This protects against accidental double subscription/initialisation in host apps.
        let pending = await notificationCenter.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) {
            print("[CXHero-Notification] ℹ️ Notification already scheduled for '\(ruleId)' (\(identifier)) - skipping")
            return
        }
        
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        do {
            try await notificationCenter.add(request)
            print("[CXHero-Notification] ✅ Scheduled notification for survey '\(ruleId)' in \(triggerAfterSeconds)s")
        } catch {
            print("[CXHero-Notification] ❌ Failed to schedule notification: \(error.localizedDescription)")
        }
    }
    
    /// Cancel a scheduled notification
    public func cancel(ruleId: String, sessionId: String) {
        let identifier = notificationIdentifier(ruleId: ruleId, sessionId: sessionId)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
    
    /// Cancel all pending survey notifications
    public func cancelAll() {
        notificationCenter.removeAllPendingNotificationRequests()
    }
    
    /// Get pending notification identifiers
    public func getPendingIdentifiers() async -> [String] {
        let requests = await notificationCenter.pendingNotificationRequests()
        return requests
            .filter { $0.content.userInfo["source"] as? String == "cxhero" }
            .map { $0.identifier }
    }
    
    private func notificationIdentifier(ruleId: String, sessionId: String) -> String {
        return "cxhero-survey-\(ruleId)-\(sessionId)"
    }
}

