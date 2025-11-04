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
    private var shownThisSession: Set<String> = []
    private var lastSessionId: UUID?
    private var gating: SurveyGatingStore?
    private var scheduledStore: ScheduledSurveyStore?
    private var notificationScheduler: SurveyNotificationScheduler?
    private let recorder: EventRecorder
    private var scheduledTasks: [String: Task<Void, Never>] = [:]
    
    /// When true, bypasses all gating rules (completion tracking, attempt limits, cooldowns) for testing
    var debugModeEnabled: Bool = false

    /// When true, enables local notification scheduling for delayed surveys
    var notificationsEnabled: Bool = false

    init(config: SurveyConfig, recorder: EventRecorder = .shared, debugModeEnabled: Bool = false, notificationsEnabled: Bool = false) {
        self.config = config
        self.debugModeEnabled = debugModeEnabled
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

    init(configPublisher: AnyPublisher<SurveyConfig, Never>, initial: SurveyConfig, recorder: EventRecorder = .shared, debugModeEnabled: Bool = false, notificationsEnabled: Bool = false) {
        self.config = initial
        self.recorder = recorder
        self.debugModeEnabled = debugModeEnabled
        self.notificationsEnabled = notificationsEnabled
        self.gating = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
        self.scheduledStore = ScheduledSurveyStore(baseDirectory: recorder.storageBaseDirectoryURL)
        if notificationsEnabled {
            self.notificationScheduler = SurveyNotificationScheduler()
        }
        self.configCancellable = configPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cfg in self?.config = cfg }
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
            // In debug mode, skip all gating checks
            if !debugModeEnabled {
            if rule.oncePerSession ?? true {
                if shownThisSession.contains(rule.ruleId) { continue }
                }
            }
            
            if !matches(rule.trigger, event: event) { continue }
            
            // In debug mode, skip gating checks (completion, attempts, cooldowns)
            if !debugModeEnabled {
            if let gating = gating {
                    let allow = await gating.canShow(
                        ruleId: rule.ruleId,
                        forUser: event.userId,
                        oncePerUser: rule.oncePerUser,
                        cooldownSeconds: rule.cooldownSeconds,
                        maxAttempts: rule.maxAttempts,
                        attemptCooldownSeconds: rule.attemptCooldownSeconds
                    )
                if !allow { continue }
            }
            }
            
            // Check if trigger has a delay
            if case .event(let eventTrigger) = rule.trigger,
               let delaySeconds = eventTrigger.scheduleAfterSeconds, delaySeconds > 0 {
                // Schedule the survey to show after delay
                scheduleDelayedSurvey(rule: rule, userId: event.userId, delaySeconds: delaySeconds)
            } else {
                // Show immediately
                await showSurvey(rule: rule, userId: event.userId)
            }
            break
        }
    }
    
    private func scheduleDelayedSurvey(rule: SurveyRule, userId: String?, delaySeconds: TimeInterval) {
        // Cancel any existing scheduled task for this rule
        scheduledTasks[rule.ruleId]?.cancel()
        
        // Persist the schedule and schedule notification
        Task {
            let session = await recorder.currentSession()
            guard let sessionId = session?.id else { return }
            
            if let store = scheduledStore {
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
        }
        
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                await showSurvey(rule: rule, userId: userId)
                
                // Remove from persistent store and cancel notification after showing
                let session = await recorder.currentSession()
                if let sessionId = session?.id {
                    if let store = scheduledStore {
                        await store.removeScheduled(ruleId: rule.ruleId, sessionId: sessionId.uuidString, userId: userId)
                    }
                    if let scheduler = notificationScheduler {
                        await scheduler.cancel(ruleId: rule.ruleId, sessionId: sessionId.uuidString)
                    }
                }
            } catch {
                // Task was cancelled
            }
            scheduledTasks.removeValue(forKey: rule.ruleId)
        }
        scheduledTasks[rule.ruleId] = task
    }
    
    private func showSurvey(rule: SurveyRule, userId: String?) async {
        await MainActor.run {
            activeRule = rule
            isPresented = true
            sheetHandledAnalytics = false
        }
        
        // In debug mode, skip tracking shown state
        if !debugModeEnabled {
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
            "debugMode": .bool(debugModeEnabled)
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
        
        // Listen for session start to restore pending surveys
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("cxHeroSessionStarted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                print("[CXHero] 🔔 Session started - restoring pending surveys")
                await self?.restorePendingScheduledSurveys()
            }
        }
        
        Task { [weak self] in
            let session = await self?.recorder.currentSession()
            self?.resetFor(session: session)
            // Try to restore on init (will succeed if session already exists)
            await self?.restorePendingScheduledSurveys()
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

    // No async gating init; gating must be ready before subscribing.
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
public struct SurveyTriggerView<Content: View>: View {
    @StateObject private var model: SurveyTriggerViewModel
    private let content: () -> Content
    private let recorder: EventRecorder
    private let onNotificationTap: ((String, String) -> Void)?

    public init(config: SurveyConfig, recorder: EventRecorder = .shared, debugModeEnabled: Bool = false, notificationsEnabled: Bool = false, onNotificationTap: ((String, String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: SurveyTriggerViewModel(config: config, recorder: recorder, debugModeEnabled: debugModeEnabled, notificationsEnabled: notificationsEnabled))
        self.recorder = recorder
        self.onNotificationTap = onNotificationTap
        self.content = content
    }

    public init(manager: SurveyConfigManager, recorder: EventRecorder = .shared, debugModeEnabled: Bool = false, notificationsEnabled: Bool = false, onNotificationTap: ((String, String) -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: SurveyTriggerViewModel(configPublisher: manager.configPublisher, initial: manager.currentConfig, recorder: recorder, debugModeEnabled: debugModeEnabled, notificationsEnabled: notificationsEnabled))
        self.recorder = recorder
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
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
struct SurveySheet: View {
    let rule: SurveyRule
    let onSubmitOption: (String) -> Void
    let onSubmitText: (String) -> Void
    let onClose: () -> Void
    @State private var textResponse: String = ""
    @State private var selectedOption: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Close button at the top
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Circle().fill(Color.secondary.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                VStack(spacing: 24) {
                    // Header section
                    VStack(spacing: 12) {
            Text(rule.title)
                            .font(.system(size: 24, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.primary)
                        
            Text(rule.message)
                            .font(.system(size: 16))
                .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .lineSpacing(4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    
                    // Content
            content
                        .padding(.horizontal, 24)
        }
                .padding(.bottom, 32)
            }
        }
        .background(backgroundColor)
        .onAppear { 
            textResponse = ""
            selectedOption = nil
        }
        .onChange(of: rule.id) { _ in 
            textResponse = ""
            selectedOption = nil
        }
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97)
    }

    @ViewBuilder
    private var content: some View {
        switch rule.response {
        case .options(let options):
            VStack(spacing: 20) {
                // Rating buttons - immediate submit on tap
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                            RatingButton(
                                label: option,
                                isFirst: index == 0,
                                isLast: index == options.count - 1,
                                action: { onSubmitOption(option) }
                            )
                        }
                    }
                }
            }
            
        case .combined(let config):
            VStack(spacing: 24) {
                // Rating buttons with selection state
                VStack(spacing: 12) {
                    if let label = config.optionsLabel {
                        Text(label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    HStack(spacing: 12) {
                        ForEach(Array(config.options.enumerated()), id: \.offset) { index, option in
                            SelectableRatingButton(
                                label: option,
                                isSelected: selectedOption == option,
                                action: { selectedOption = option }
                            )
                        }
                    }
                }
                
                // Optional text field
                if let textFieldConfig = config.textField {
                    VStack(alignment: .leading, spacing: 8) {
                        if let label = textFieldConfig.label {
                            Text(label)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(colorScheme == .dark ? Color(white: 0.18) : Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                            
                            TextEditor(text: $textResponse)
                                .frame(minHeight: 100)
                                .padding(12)
                                .background(Color.clear)
                                .modifier(TextEditorBackgroundModifier())
                            
                            if textResponse.isEmpty, let placeholder = textFieldConfig.placeholder {
                                Text(placeholder)
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(height: 120)
                        
                        if let max = textFieldConfig.maxLength {
                            HStack {
                                Spacer()
                                Text("\(textResponse.count)/\(max)")
                                    .font(.caption)
                                    .foregroundColor(textResponse.count > max ? .red : .secondary)
                            }
                        }
                    }
                }
                
                // Submit button
                Button(action: {
                    submitCombinedResponse(config: config)
                }) {
                    Text(config.submitLabel ?? "Submit Feedback")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(canSubmitCombined(config: config) ? 
                                    Color.accentColor : 
                                    Color.secondary.opacity(0.3))
                        )
                }
                .disabled(!canSubmitCombined(config: config))
            }
            .onChange(of: textResponse) { newValue in
                if let max = config.textField?.maxLength, newValue.count > max {
                    textResponse = String(newValue.prefix(max))
                }
            }
            
        case .text(let config):
            VStack(spacing: 20) {
                // Text input area
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(colorScheme == .dark ? Color(white: 0.18) : Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                    TextEditor(text: $textResponse)
                        .frame(minHeight: 120)
                            .padding(12)
                            .background(Color.clear)
                            .modifier(TextEditorBackgroundModifier())
                        
                    if textResponse.isEmpty, let placeholder = config.placeholder {
                        Text(placeholder)
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                    }
                }
                    .frame(height: 140)
                    
                if let max = config.maxLength {
                    HStack {
                        Spacer()
                        Text("\(textResponse.count)/\(max)")
                            .font(.caption)
                                .foregroundColor(textResponse.count > max ? .red : .secondary)
                        }
                    }
                }
                
                // Submit button
                Button(action: {
                    onSubmitText(trimmedText(config: config))
                }) {
                    Text(config.submitLabel ?? "Submit Feedback")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(canSubmit(config: config) ? 
                                    Color.accentColor : 
                                    Color.secondary.opacity(0.3))
                        )
                }
                .disabled(!canSubmit(config: config))
            }
            .onChange(of: textResponse) { newValue in
                if let max = config.maxLength, newValue.count > max {
                    textResponse = String(newValue.prefix(max))
                }
            }
        }
    }

    private func trimmedText(config: TextResponseConfig) -> String {
        var trimmed = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if let max = config.maxLength, trimmed.count > max {
            trimmed = String(trimmed.prefix(max))
        }
        return trimmed
    }

    private func canSubmit(config: TextResponseConfig) -> Bool {
        let trimmed = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if let max = config.maxLength, trimmed.count > max { return false }
        if let min = config.minLength, trimmed.count < min { return false }
        if !config.allowEmpty && trimmed.isEmpty { return false }
        return true
    }
    
    private func canSubmitCombined(config: CombinedResponseConfig) -> Bool {
        // Must have selected an option
        guard selectedOption != nil else { return false }
        
        // If text field is required, validate it
        if let textFieldConfig = config.textField, textFieldConfig.required {
            let trimmed = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if let min = textFieldConfig.minLength, trimmed.count < min { return false }
        }
        
        // If text field has content, validate it
        if let textFieldConfig = config.textField {
            let trimmed = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let max = textFieldConfig.maxLength, trimmed.count > max { return false }
                if let min = textFieldConfig.minLength, trimmed.count < min { return false }
            }
        }
        
        return true
    }
    
    private func submitCombinedResponse(config: CombinedResponseConfig) {
        guard let option = selectedOption else { return }
        
        let trimmedText = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Create combined response string
        // Format: "option|text" or just "option" if no text
        let combinedResponse = trimmedText.isEmpty ? option : "\(option)||\(trimmedText)"
        
        onSubmitText(combinedResponse)
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct RatingButton: View {
    let label: String
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Emoji or icon based on label
                Text(emoji)
                    .font(.system(size: 32))
                
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color.white)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), 
                            radius: 8, x: 0, y: 2)
            )
        }
        .buttonStyle(RatingButtonStyle())
    }
    
    private var emoji: String {
        let lowercased = label.lowercased()
        
        // Common rating words to emoji mapping
        if lowercased.contains("poor") || lowercased.contains("bad") || lowercased == "1" {
            return "😞"
        } else if lowercased.contains("fair") || lowercased.contains("okay") || lowercased == "2" {
            return "😐"
        } else if lowercased.contains("good") || lowercased == "3" {
            return "🙂"
        } else if lowercased.contains("great") || lowercased.contains("very good") || lowercased == "4" {
            return "😊"
        } else if lowercased.contains("excellent") || lowercased.contains("amazing") || 
                  lowercased.contains("outstanding") || lowercased == "5" {
            return "🤩"
        }
        
        // Numeric ratings 1-10
        if let number = Int(label) {
            switch number {
            case 1...2: return "😞"
            case 3...4: return "😐"
            case 5...6: return "🙂"
            case 7...8: return "😊"
            case 9...10: return "🤩"
            default: return "⭐"
            }
        }
        
        // Default star for anything else
        return "⭐"
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SelectableRatingButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Emoji or icon based on label
                Text(emoji)
                    .font(.system(size: 32))
                
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor : (colorScheme == .dark ? Color(white: 0.18) : Color.white))
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), 
                            radius: isSelected ? 12 : 8, x: 0, y: isSelected ? 4 : 2)
            )
        }
        .buttonStyle(RatingButtonStyle())
    }
    
    private var emoji: String {
        let lowercased = label.lowercased()
        
        // Common rating words to emoji mapping
        if lowercased.contains("poor") || lowercased.contains("bad") || lowercased == "1" {
            return "😞"
        } else if lowercased.contains("fair") || lowercased.contains("okay") || lowercased == "2" {
            return "😐"
        } else if lowercased.contains("good") || lowercased == "3" {
            return "🙂"
        } else if lowercased.contains("great") || lowercased.contains("very good") || lowercased == "4" {
            return "😊"
        } else if lowercased.contains("excellent") || lowercased.contains("amazing") || 
                  lowercased.contains("outstanding") || lowercased == "5" {
            return "🤩"
        }
        
        // Numeric ratings 1-10
        if let number = Int(label) {
            switch number {
            case 1...2: return "😞"
            case 3...4: return "😐"
            case 5...6: return "🙂"
            case 7...8: return "😊"
            case 9...10: return "🤩"
            default: return "⭐"
            }
        }
        
        // Default star for anything else
        return "⭐"
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct RatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct TextEditorBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
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
}
