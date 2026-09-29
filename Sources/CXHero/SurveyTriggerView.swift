import Foundation
import SwiftUI
import Combine

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
@MainActor
final class SurveyTriggerViewModel: ObservableObject {
    @Published var activeRule: SurveyRule?
    @Published var isPresented: Bool = false
    @Published var config: SurveyConfig
    @Published var sheetHandledAnalytics: Bool = false

    private var configCancellable: AnyCancellable?
    private var eventCancellable: AnyCancellable?
    private var sessionCancellable: AnyCancellable?
    private var shownThisSession: Set<String> = []
    private var lastSessionId: UUID?
    private var gating: SurveyGatingStore?
    private var scheduledStore: ScheduledSurveyStore?
    private var notificationScheduler: SurveyNotificationScheduler?
    private let recorder: EventRecorder
    private var scheduledTasks: [String: Task<Void, Never>] = [:]
    
    /// Debug configuration for testing
    var debugConfig: SurveyDebugConfig = .production

    /// When true, enables local notification scheduling for delayed surveys
    var notificationsEnabled: Bool = false

    init(config: SurveyConfig, recorder: EventRecorder = .shared, debugConfig: SurveyDebugConfig = .production, notificationsEnabled: Bool = false) {
        // Apply debug overrides to config
        self.config = debugConfig.apply(to: config)
        self.debugConfig = debugConfig
        self.notificationsEnabled = notificationsEnabled
        self.recorder = recorder
        // Initialize gating before subscribing to events to enforce safeguards from first event
        self.gating = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
        self.scheduledStore = ScheduledSurveyStore(baseDirectory: recorder.storageBaseDirectoryURL)
        if notificationsEnabled {
            self.notificationScheduler = SurveyNotificationScheduler()
        }
        subscribeToEvents()
    }

    init(configPublisher: AnyPublisher<SurveyConfig, Never>, initial: SurveyConfig, recorder: EventRecorder = .shared, debugConfig: SurveyDebugConfig = .production, notificationsEnabled: Bool = false) {
        // Apply debug overrides to initial config
        self.config = debugConfig.apply(to: initial)
        self.recorder = recorder
        self.debugConfig = debugConfig
        self.notificationsEnabled = notificationsEnabled
        self.gating = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
        self.scheduledStore = ScheduledSurveyStore(baseDirectory: recorder.storageBaseDirectoryURL)
        if notificationsEnabled {
            self.notificationScheduler = SurveyNotificationScheduler()
        }
        self.configCancellable = configPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cfg in 
                // Apply debug overrides when config updates
                guard let self = self else { return }
                self.config = self.debugConfig.apply(to: cfg)
            }
        subscribeToEvents()
    }

    private func resetFor(session: EventSession?) {
        shownThisSession.removeAll()
    }

    private func handle(event: Event) {
        Task { await process(event: event) }
    }

    private func process(event: Event) async {
        if lastSessionId != event.sessionId {
            shownThisSession.removeAll()
            // Cancel any scheduled tasks from previous session
            for (_, task) in scheduledTasks {
                task.cancel()
            }
            scheduledTasks.removeAll()
            lastSessionId = event.sessionId
        }
        for rule in config.surveys {
            // In debug mode with gating bypass, skip all gating checks
            if !debugConfig.bypassGating {
            if rule.oncePerSession ?? true {
                if shownThisSession.contains(rule.ruleId) { continue }
                }
            }
            
            if !matches(rule.trigger, event: event) { continue }
            
            // In debug mode with gating bypass, skip gating checks (completion, attempts, cooldowns)
            if !debugConfig.bypassGating {
            if let gating = gating {
                    let allow = await gating.canShow(
                        ruleId: rule.ruleId,
                        forUser: event.userId,
                        oncePerUser: rule.oncePerUser,
                        cooldownSeconds: rule.cooldownSeconds,
                        maxAttempts: rule.maxAttempts,
                        attemptCooldownSeconds: rule.attemptCooldownSeconds,
                        recurring: rule.recurring
                    )
                if !allow { continue }
            }
            }
            
            // Check if trigger has a delay
            if case .event(let eventTrigger) = rule.trigger,
               let delaySeconds = eventTrigger.scheduleAfterSeconds, delaySeconds > 0 {
                // Schedule the survey to show after delay
                await scheduleDelayedSurvey(rule: rule, userId: event.userId, delaySeconds: delaySeconds)
            } else {
                // Show immediately
                await showSurvey(rule: rule, userId: event.userId)
            }
            break
        }
    }
    
    private func scheduleDelayedSurvey(rule: SurveyRule, userId: String?, delaySeconds: TimeInterval) async {
        // Cancel any existing scheduled task for this rule
        scheduledTasks[rule.ruleId]?.cancel()
        
        // We need a session to associate the schedule with.
        let session = await recorder.currentSession()
        guard let sessionId = session?.id else { return }
        
        // Deduplicate: if this rule is already pending for this session, do nothing.
        // This prevents double scheduling when the host app accidentally ends up with
        // multiple active trigger models/subscriptions.
        if let store = scheduledStore {
            let alreadyPending = await store
                .getPendingSurveys(for: userId, sessionId: sessionId.uuidString)
                .contains(where: { $0.id == rule.ruleId })
            
            if alreadyPending {
                print("[CXHero] ℹ️ Survey '\(rule.ruleId)' already scheduled for this session - skipping")
                return
            }
            
            await store.scheduleForLater(
                ruleId: rule.ruleId,
                userId: userId,
                sessionId: sessionId.uuidString,
                delaySeconds: delaySeconds
            )
        }
        
        // Schedule local notification if enabled and configured
        if notificationsEnabled {
            if let notificationConfig = rule.notification {
                if let scheduler = notificationScheduler {
                    print("[CXHero] 📬 Scheduling notification for '\(rule.ruleId)' in \(delaySeconds)s")
                    await scheduler.schedule(
                        ruleId: rule.ruleId,
                        sessionId: sessionId.uuidString,
                        notificationConfig: notificationConfig,
                        triggerAfterSeconds: delaySeconds
                    )
                } else {
                    print("[CXHero] ⚠️ Notification scheduler not initialized!")
                }
            } else {
                print("[CXHero] ℹ️ No notification config for survey '\(rule.ruleId)'")
            }
        } else {
            print("[CXHero] ℹ️ Notifications not enabled")
        }
        
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard let self else { return }
                await self.showSurvey(rule: rule, userId: userId)
                
                // Remove from persistent store and cancel notification after showing
                let session = await self.recorder.currentSession()
                if let sessionId = session?.id {
                    if let store = self.scheduledStore {
                        await store.removeScheduled(ruleId: rule.ruleId, sessionId: sessionId.uuidString, userId: userId)
                    }
                    if let scheduler = self.notificationScheduler {
                        await scheduler.cancel(ruleId: rule.ruleId, sessionId: sessionId.uuidString)
                    }
                }
            } catch {
                // Task was cancelled
            }
            await MainActor.run {
                self?.scheduledTasks.removeValue(forKey: rule.ruleId)
            }
        }
        scheduledTasks[rule.ruleId] = task
    }
    
    private func showSurvey(rule: SurveyRule, userId: String?) async {
        await MainActor.run {
            activeRule = rule
            isPresented = true
            sheetHandledAnalytics = false
        }
        
        // In debug mode with gating bypass, skip tracking shown state
        if !debugConfig.bypassGating {
            if rule.oncePerSession ?? true { 
                await MainActor.run {
                    shownThisSession.insert(rule.ruleId)
                }
            }
            if let gating = gating { await gating.markShown(ruleId: rule.ruleId, forUser: userId) }
        }
        
            recorder.record("survey_presented", properties: [
                "id": .string(rule.ruleId),
            "responseType": .string(rule.response.analyticsType),
            "debugMode": .bool(debugConfig.enabled)
            ])
    }

    private func matches(_ trigger: TriggerCondition, event: Event) -> Bool {
        switch trigger {
        case .event(let t):
            guard t.name == event.name else { return false }
            guard let props = t.properties else { return true }
            // Existence checks
            let evProps = event.properties ?? [:]
            for (k, matcher) in props {
                switch matcher {
                case .exists(let shouldExist):
                    let exists = evProps.keys.contains(k)
                    if shouldExist != exists { return false }
                default:
                    guard let v = evProps[k] else { return false }
                    if !matcher.matches(v) { return false }
                }
            }
            return true
        }
    }

    private func subscribeToEvents() {
        // Subscribe to event stream
        self.eventCancellable = recorder.eventsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handle(event: event)
            }
        
        // Subscribe to session lifecycle events
        self.sessionCancellable = recorder.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                switch event {
                case .started(let session):
                    // Only restore if this is a different session than we've seen
                    // (Prevents re-restoration on auto-start of same session we already processed)
                    guard let self = self, session.id != self.lastSessionId else { return }
                    print("[CXHero] 🔔 Session started - restoring pending surveys")
                    Task { [weak self] in
                        await self?.restorePendingScheduledSurveys()
                    }
                case .ended:
                    break
                }
            }
        
        Task { [weak self] in
            guard let self else { return }
            // Only attempt restoration on init if a session already exists.
            // If there is no session yet, we'll restore when the session starts.
            if let session = await self.recorder.currentSession() {
                self.resetFor(session: session)
                self.lastSessionId = session.id
                await self.restorePendingScheduledSurveys()
            }
        }
    }

    deinit {
        // Best-effort: cancel any outstanding scheduled tasks on teardown to avoid
        // keeping the model alive accidentally and/or double-firing after view recreation.
        for (_, task) in scheduledTasks {
            task.cancel()
        }
    }
    
    private func restorePendingScheduledSurveys() async {
        print("[CXHero] 🔍 Checking for pending scheduled surveys...")
        
        guard let session = await recorder.currentSession() else {
            print("[CXHero] ⚠️ No current session, cannot restore surveys")
            return
        }
        
        guard let store = scheduledStore else {
            print("[CXHero] ⚠️ No scheduled store, cannot restore surveys")
            return
        }
        
        let userId = session.userId
        print("[CXHero] 📋 Restoring surveys for userId: \(userId ?? "anonymous"), sessionId: \(session.id)")
        
        // Check for surveys that should have already triggered (from ANY session)
        // This allows surveys scheduled in previous sessions to be shown after app restart
        let triggered = await store.getAllTriggeredSurveys(for: userId)
        print("[CXHero] 📊 Found \(triggered.count) triggered surveys")
        
        for scheduled in triggered {
            print("[CXHero] ⏰ Triggered survey: id=\(scheduled.id), triggerAt=\(scheduled.triggerAt), sessionId=\(scheduled.sessionId)")
            // Find the rule in config
            if let rule = config.surveys.first(where: { $0.ruleId == scheduled.id }) {
                print("[CXHero] ✅ Showing triggered survey: \(rule.ruleId)")
                // Show immediately since trigger time has passed
                await showSurvey(rule: rule, userId: userId)
                // Remove with original session ID
                await store.removeScheduled(ruleId: rule.ruleId, sessionId: scheduled.sessionId, userId: userId)
                break // Only show one survey at a time
            } else {
                print("[CXHero] ⚠️ Rule not found in config for triggered survey: \(scheduled.id)")
            }
        }
        
        // Restore pending scheduled surveys that haven't triggered yet (from ANY session)
        let pending = await store.getAllPendingSurveys(for: userId)
        print("[CXHero] 📊 Found \(pending.count) pending surveys")
        
        for scheduled in pending {
            let remainingDelay = scheduled.remainingDelay
            print("[CXHero] ⏱️ Pending survey: id=\(scheduled.id), triggerAt=\(scheduled.triggerAt), remainingDelay=\(remainingDelay)s, sessionId=\(scheduled.sessionId)")
            
            // Find the rule in config
            if let rule = config.surveys.first(where: { $0.ruleId == scheduled.id }) {
                if remainingDelay > 0 {
                    print("[CXHero] 🔄 Re-scheduling survey with \(remainingDelay)s remaining")
                    // Re-schedule with remaining time (keep original session ID for cleanup)
                    scheduleDelayedSurveyForRestoredSchedule(
                        rule: rule, 
                        userId: userId, 
                        delaySeconds: remainingDelay,
                        originalSessionId: scheduled.sessionId
                    )
                } else {
                    print("[CXHero] ✅ Showing pending survey (delay expired): \(rule.ruleId)")
                    // Should trigger now
                    await showSurvey(rule: rule, userId: userId)
                    // Remove with original session ID
                    await store.removeScheduled(ruleId: rule.ruleId, sessionId: scheduled.sessionId, userId: userId)
                    break // Only show one survey at a time
                }
            } else {
                print("[CXHero] ⚠️ Rule not found in config for pending survey: \(scheduled.id)")
            }
        }
        
        if triggered.isEmpty && pending.isEmpty {
            print("[CXHero] ℹ️ No pending surveys to restore")
        }
    }
    
    private func scheduleDelayedSurveyWithRemainingTime(rule: SurveyRule, userId: String?, delaySeconds: TimeInterval, sessionId: String) {
        // Note: This is kept for backwards compatibility but now just delegates to the restored schedule handler
        scheduleDelayedSurveyForRestoredSchedule(
            rule: rule,
            userId: userId,
            delaySeconds: delaySeconds,
            originalSessionId: sessionId
        )
    }
    
    func markSurveyCompleted(ruleId: String) {
        Task {
            let session = await recorder.currentSession()
            if let gating = gating {
                await gating.markCompleted(ruleId: ruleId, forUser: session?.userId)
            }
            // Remove any scheduled surveys for this rule since it's been completed
            if let sessionId = session?.id {
                if let store = scheduledStore {
                    await store.removeScheduled(ruleId: ruleId, sessionId: sessionId.uuidString, userId: session?.userId)
                }
                // Cancel pending notification
                if let scheduler = notificationScheduler {
                    await scheduler.cancel(ruleId: ruleId, sessionId: sessionId.uuidString)
                }
            }
            // Also cancel any in-memory scheduled tasks
            scheduledTasks[ruleId]?.cancel()
            scheduledTasks.removeValue(forKey: ruleId)
        }
    }
    
    /// Handle notification tap - shows the survey if it exists in config
    func handleNotificationTap(surveyId: String, sessionId: String) {
        Task {
            // Find the rule in config
            guard let rule = config.surveys.first(where: { $0.ruleId == surveyId }) else {
                return
            }
            
            // Get current session
            let session = await recorder.currentSession()
            
            // Only show if session matches (prevents stale notifications)
            guard session?.id.uuidString == sessionId else {
                return
            }
            
            // Show the survey
            await showSurvey(rule: rule, userId: session?.userId)
            
            // Clean up scheduled state
            if let store = scheduledStore {
                await store.removeScheduled(ruleId: surveyId, sessionId: sessionId, userId: session?.userId)
            }
        }
    }
    
    /// Check for and present any pending surveys from previous sessions
    /// Call this on app launch/foreground to handle surveys that were scheduled but not shown
    public func checkAndPresentPendingSurveys() async {
        guard let session = await recorder.currentSession(),
              let store = scheduledStore else { return }
        
        let userId = session.userId
        
        // Check for surveys that should have already triggered (from any session)
        let triggered = await store.getAllTriggeredSurveys(for: userId)
        for scheduled in triggered {
            // Find the rule in config
            if let rule = config.surveys.first(where: { $0.ruleId == scheduled.id }) {
                // Show immediately since trigger time has passed
                await showSurvey(rule: rule, userId: userId)
                // Remove with original session ID
                await store.removeScheduled(ruleId: rule.ruleId, sessionId: scheduled.sessionId, userId: userId)
                break // Only show one survey at a time
            }
        }
        
        // Also check pending surveys that haven't triggered yet
        let pending = await store.getAllPendingSurveys(for: userId)
        for scheduled in pending {
            // Find the rule in config
            if let rule = config.surveys.first(where: { $0.ruleId == scheduled.id }) {
                let remainingDelay = scheduled.remainingDelay
                if remainingDelay <= 0 {
                    // Should trigger now
                    await showSurvey(rule: rule, userId: userId)
                    await store.removeScheduled(ruleId: rule.ruleId, sessionId: scheduled.sessionId, userId: userId)
                    break
                } else {
                    // Re-schedule with remaining time (keep original session ID for cleanup)
                    scheduleDelayedSurveyForRestoredSchedule(
                        rule: rule, 
                        userId: userId, 
                        delaySeconds: remainingDelay,
                        originalSessionId: scheduled.sessionId
                    )
                }
            }
        }
    }
    
    private func scheduleDelayedSurveyForRestoredSchedule(
        rule: SurveyRule, 
        userId: String?, 
        delaySeconds: TimeInterval,
        originalSessionId: String
    ) {
        // Cancel any existing scheduled task for this rule
        scheduledTasks[rule.ruleId]?.cancel()
        
        // Don't re-persist - already in store with original session ID
        
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                await showSurvey(rule: rule, userId: userId)
                
                // Remove using original session ID
                if let store = scheduledStore {
                    await store.removeScheduled(ruleId: rule.ruleId, sessionId: originalSessionId, userId: userId)
                }
            } catch {
                // Task was cancelled
            }
            scheduledTasks.removeValue(forKey: rule.ruleId)
        }
        scheduledTasks[rule.ruleId] = task
    }

    /// Presents a survey on demand - a home shortcut, a deep link, a button.
    ///
    /// Skips trigger matching, cooldowns and completion gating: the member
    /// asked for this survey, so there is no prompt to throttle. Response,
    /// dismissal and presentation analytics record as usual. No-op when the
    /// id is not in the loaded config.
    public func presentSurvey(ruleId: String) {
        guard let rule = config.surveys.first(where: { $0.ruleId == ruleId }) else { return }
        Task { [weak self] in
            guard let self else { return }
            let session = await self.recorder.currentSession()
            await self.showSurvey(rule: rule, userId: session?.userId)
        }
    }

    // No async gating init; gating must be ready before subscribing.
}

/// A handle onto the survey sheet for descendant views.
///
/// `SurveyTriggerView` injects one into the environment of its content, so
/// anything inside - a quick link, a settings row - can open a survey by id
/// without knowing about the trigger model.
public struct SurveyPresenter: Sendable {
    private let present: @MainActor @Sendable (String) -> Void

    public init(present: @MainActor @Sendable @escaping (String) -> Void) {
        self.present = present
    }

    @MainActor
    public func presentSurvey(ruleId: String) {
        present(ruleId)
    }
}

private struct SurveyPresenterKey: EnvironmentKey {
    static let defaultValue = SurveyPresenter { _ in }
}

public extension EnvironmentValues {
    /// Open a survey from inside `SurveyTriggerView` content:
    /// `surveyPresenter.presentSurvey(ruleId:)`.
    var surveyPresenter: SurveyPresenter {
        get { self[SurveyPresenterKey.self] }
        set { self[SurveyPresenterKey.self] = newValue }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
public struct SurveyTriggerView<Content: View>: View {
    @StateObject private var model: SurveyTriggerViewModel
    private let content: () -> Content
    private let recorder: EventRecorder
    private let onNotificationTap: ((String, String) -> Void)?
    private let accentColor: Color?
    
    @Environment(\.scenePhase) private var scenePhase

    public init(config: SurveyConfig, recorder: EventRecorder = .shared, debugConfig: SurveyDebugConfig = .production, notificationsEnabled: Bool = false, accentColor: Color? = nil, onNotificationTap: ((String, String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        let viewModel = SurveyTriggerViewModel(config: config, recorder: recorder, debugConfig: debugConfig, notificationsEnabled: notificationsEnabled)
        _model = StateObject(wrappedValue: viewModel)
        self.recorder = recorder
        self.accentColor = accentColor
        self.onNotificationTap = onNotificationTap
        self.content = content
    }

    public init(manager: SurveyConfigManager, recorder: EventRecorder = .shared, debugConfig: SurveyDebugConfig = .production, notificationsEnabled: Bool = false, accentColor: Color? = nil, onNotificationTap: ((String, String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        let viewModel = SurveyTriggerViewModel(configPublisher: manager.configPublisher, initial: manager.currentConfig, recorder: recorder, debugConfig: debugConfig, notificationsEnabled: notificationsEnabled)
        _model = StateObject(wrappedValue: viewModel)
        self.recorder = recorder
        self.accentColor = accentColor
        self.onNotificationTap = onNotificationTap
        self.content = content
    }
    
    // DEPRECATED: Legacy init for backwards compatibility
    public init(config: SurveyConfig, recorder: EventRecorder = .shared, debugModeEnabled: Bool = false, notificationsEnabled: Bool = false, onNotificationTap: ((String, String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        let debugConfig = debugModeEnabled ? SurveyDebugConfig.debug : SurveyDebugConfig.production
        let viewModel = SurveyTriggerViewModel(config: config, recorder: recorder, debugConfig: debugConfig, notificationsEnabled: notificationsEnabled)
        _model = StateObject(wrappedValue: viewModel)
        self.recorder = recorder
        self.accentColor = nil
        self.onNotificationTap = onNotificationTap
        self.content = content
    }
    
    /// Call this method from your app's notification delegate to handle survey notification taps
    public func handleNotificationResponse(surveyId: String, sessionId: String) {
        model.handleNotificationTap(surveyId: surveyId, sessionId: sessionId)
        onNotificationTap?(surveyId, sessionId)
    }
    
    /// Check for and present any pending surveys from previous sessions
    /// Call this on app launch or when app becomes active to handle surveys scheduled in previous sessions
    public func checkPendingSurveys() async {
        await model.checkAndPresentPendingSurveys()
    }

    public var body: some View {
        content()
            .sheet(isPresented: $model.isPresented, onDismiss: {
                if let rule = model.activeRule, model.sheetHandledAnalytics == false {
                    // Dismissal via swipe/backdrop: record once here
                    recorder.record("survey_dismissed", properties: [
                        "id": .string(rule.ruleId),
                        "responseType": .string(rule.response.analyticsType)
                    ])
                }
                model.activeRule = nil
                model.sheetHandledAnalytics = false
            }) {
                if let rule = model.activeRule {
                    SurveySheet(
                        rule: rule,
                        accentColor: accentColor,
                        onSubmitOption: { option in
                            recorder.record("survey_response", properties: [
                                "id": .string(rule.ruleId),
                                "type": .string("choice"),
                                "option": .string(option)
                            ])
                            model.markSurveyCompleted(ruleId: rule.ruleId)
                            model.sheetHandledAnalytics = true
                            model.isPresented = false
                        },
                        onSubmitText: { text in
                            recorder.record("survey_response", properties: [
                                "id": .string(rule.ruleId),
                                "type": .string("text"),
                                "text": .string(text)
                            ])
                            model.markSurveyCompleted(ruleId: rule.ruleId)
                            model.sheetHandledAnalytics = true
                            model.isPresented = false
                        },
                        onClose: {
                            recorder.record("survey_dismissed", properties: [
                                "id": .string(rule.ruleId),
                                "responseType": .string(rule.response.analyticsType)
                            ])
                            model.sheetHandledAnalytics = true
                            model.isPresented = false
                        }
                    )
                } else {
                    EmptyView()
                }
            }
            .onChange(of: scenePhase) { _ in
                if scenePhase == .active {
                    // Check for pending surveys when app becomes active
                    Task {
                        await model.checkAndPresentPendingSurveys()
                    }
                }
            }
            .environment(\.surveyPresenter, SurveyPresenter { [weak model] ruleId in
                model?.presentSurvey(ruleId: ruleId)
            })
    }
}

private extension SurveyResponse {
    var analyticsType: String {
        switch self {
        case .options: return "choice"
        case .text: return "text"
        case .combined: return "combined"
        }
    }
}

public extension SurveyConfig {
    static func from(data: Data) throws -> SurveyConfig {
        try JSONDecoder().decode(SurveyConfig.self, from: data)
    }

    static func from(url: URL) throws -> SurveyConfig {
        let data = try Data(contentsOf: url)
        return try from(data: data)
    }
    
    /// Load survey config from app bundle with optional debug overrides
    static func loadFromBundle(
        resourceName: String,
        bundle: Bundle = .main,
        debugConfig: SurveyDebugConfig = .production
    ) throws -> SurveyConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw ConfigError.fileNotFound(resourceName)
        }
        
        var config = try from(url: url)
        
        // Apply debug overrides if enabled
        if debugConfig.enabled {
            config = debugConfig.apply(to: config)
        }
        
        return config
    }
}

public enum ConfigError: Error {
    case fileNotFound(String)
}

