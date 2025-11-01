import Foundation
import SwiftUI
import Combine

@available(iOS 13.0, macOS 12.0, tvOS 13.0, watchOS 8.0, *)
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
    private let recorder: EventRecorder

    init(config: SurveyConfig, recorder: EventRecorder = .shared) {
        self.config = config
        self.recorder = recorder
        // Initialize gating before subscribing to events to enforce safeguards from first event
        self.gating = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
        subscribeToEvents()
    }

    init(configPublisher: AnyPublisher<SurveyConfig, Never>, initial: SurveyConfig, recorder: EventRecorder = .shared) {
        self.config = initial
        self.recorder = recorder
        self.gating = SurveyGatingStore(baseDirectory: recorder.storageBaseDirectoryURL)
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
            lastSessionId = event.sessionId
        }
        for rule in config.surveys {
            if rule.oncePerSession ?? true {
                if shownThisSession.contains(rule.ruleId) { continue }
            }
            if !matches(rule.trigger, event: event) { continue }
            if let gating = gating {
                let allow = await gating.canShow(ruleId: rule.ruleId, forUser: event.userId, oncePerUser: rule.oncePerUser, cooldownSeconds: rule.cooldownSeconds)
                if !allow { continue }
            }
            activeRule = rule
            isPresented = true
            sheetHandledAnalytics = false
            if rule.oncePerSession ?? true { shownThisSession.insert(rule.ruleId) }
            if let gating = gating { await gating.markShown(ruleId: rule.ruleId, forUser: event.userId) }
            recorder.record("survey_presented", properties: ["id": .string(rule.ruleId)])
            break
        }
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
        Task { [weak self] in
            let session = await self?.recorder.currentSession()
            self?.resetFor(session: session)
        }
    }

    // No async gating init; gating must be ready before subscribing.
}

@available(iOS 13.0, macOS 12.0, tvOS 13.0, watchOS 8.0, *)
public struct SurveyTriggerView<Content: View>: View {
    @StateObject private var model: SurveyTriggerViewModel
    private let content: () -> Content
    private let recorder: EventRecorder

    public init(config: SurveyConfig, recorder: EventRecorder = .shared, @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: SurveyTriggerViewModel(config: config, recorder: recorder))
        self.recorder = recorder
        self.content = content
    }

    public init(manager: SurveyConfigManager, recorder: EventRecorder = .shared, @ViewBuilder content: @escaping () -> Content) {
        _model = StateObject(wrappedValue: SurveyTriggerViewModel(configPublisher: manager.configPublisher, initial: manager.currentConfig, recorder: recorder))
        self.recorder = recorder
        self.content = content
    }

    public var body: some View {
        content()
            .sheet(isPresented: $model.isPresented, onDismiss: {
                if let rule = model.activeRule, model.sheetHandledAnalytics == false {
                    // Dismissal via swipe/backdrop: record once here
                    recorder.record("survey_dismissed", properties: ["id": .string(rule.ruleId)])
                }
                model.activeRule = nil
                model.sheetHandledAnalytics = false
            }) {
                if let rule = model.activeRule {
                    SurveySheet(rule: rule, onSubmit: { option in
                        recorder.record("survey_response", properties: [
                            "id": .string(rule.ruleId),
                            "option": .string(option)
                        ])
                        model.sheetHandledAnalytics = true
                        model.isPresented = false
                    }, onClose: {
                        recorder.record("survey_dismissed", properties: ["id": .string(rule.ruleId)])
                        model.sheetHandledAnalytics = true
                        model.isPresented = false
                    })
                } else {
                    EmptyView()
                }
            }
    }
}

@available(iOS 13.0, macOS 12.0, tvOS 13.0, watchOS 8.0, *)
struct SurveySheet: View {
    let rule: SurveyRule
    let onSubmit: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(rule.title)
                .font(.headline)
            Text(rule.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ForEach(rule.options, id: \.self) { option in
                Button(option) { onSubmit(option) }
            }
            Button("Close") { onClose() }
                .padding(.top, 8)
        }
        .padding()
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
