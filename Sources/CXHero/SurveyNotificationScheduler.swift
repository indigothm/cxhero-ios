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
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        
        do {
            try await notificationCenter.add(request)
        } catch {
            // Silently ignore notification scheduling errors
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

