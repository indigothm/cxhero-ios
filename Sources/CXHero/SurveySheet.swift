import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The survey sheet.
///
/// On iOS 26 it adopts Liquid Glass: a partial-height sheet that keeps the
/// system glass background, interactive glass rating tiles, a glass close
/// button and a prominent glass submit button in a bottom safe-area bar.
/// Earlier systems keep the opaque card look.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
struct SurveySheet: View {
    let rule: SurveyRule
    let accentColor: Color?
    let onSubmitOption: (String) -> Void
    let onSubmitText: (String) -> Void
    let onClose: () -> Void
    @State private var textResponse: String = ""
    @State private var selectedOption: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { accentColor ?? Color.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SurveyCloseButton {
                    dismissKeyboard()
                    onClose()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                VStack(spacing: 28) {
                    header
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .modifier(KeyboardDismissOnScroll())
        }
        .modifier(SurveyBottomBar(isVisible: hasSubmitButton, legacyBackground: legacyBackground) {
            submitButtonSection
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
        })
        .modifier(SurveySheetChrome(detents: detentStyle, legacyBackground: legacyBackground))
        .modifier(SelectionHaptics(trigger: selectedOption))
        .onAppear {
            textResponse = ""
            selectedOption = nil
            dismissKeyboard()
        }
        .onChange(of: rule.id) { _ in
            textResponse = ""
            selectedOption = nil
            dismissKeyboard()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Text(rule.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(rule.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch rule.response {
        case .options(let options):
            // Immediate submit on tap.
            RatingRow {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    RatingTile(label: option, accent: accent, selection: .none) {
                        dismissKeyboard()
                        onSubmitOption(option)
                    }
                }
            }

        case .combined(let config):
            VStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    if let label = config.optionsLabel {
                        SectionLabel(label)
                    }
                    RatingRow {
                        ForEach(Array(config.options.enumerated()), id: \.offset) { _, option in
                            RatingTile(
                                label: option,
                                accent: accent,
                                selection: selectedOption == nil ? .none
                                    : (selectedOption == option ? .selected : .deselected)
                            ) {
                                dismissKeyboard()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    selectedOption = option
                                }
                            }
                        }
                    }
                }

                if let textFieldConfig = config.textField {
                    VStack(alignment: .leading, spacing: 10) {
                        if let label = textFieldConfig.label {
                            SectionLabel(label)
                        }
                        SurveyTextEditor(
                            text: $textResponse,
                            placeholder: textFieldConfig.placeholder,
                            height: 120,
                            maxLength: textFieldConfig.maxLength
                        )
                    }
                }
            }
            .onChange(of: textResponse) { newValue in
                if let max = config.textField?.maxLength, newValue.count > max {
                    textResponse = String(newValue.prefix(max))
                }
            }

        case .text(let config):
            SurveyTextEditor(
                text: $textResponse,
                placeholder: config.placeholder,
                height: 140,
                maxLength: config.maxLength
            )
            .onChange(of: textResponse) { newValue in
                if let max = config.maxLength, newValue.count > max {
                    textResponse = String(newValue.prefix(max))
                }
            }
        }
    }

    @ViewBuilder
    private var submitButtonSection: some View {
        switch rule.response {
        case .combined(let config):
            SurveySubmitButton(
                title: config.submitLabel ?? "Submit Feedback",
                accent: accent,
                isEnabled: canSubmitCombined(config: config)
            ) {
                dismissKeyboard()
                submitCombinedResponse(config: config)
            }

        case .text(let config):
            SurveySubmitButton(
                title: config.submitLabel ?? "Submit Feedback",
                accent: accent,
                isEnabled: canSubmit(config: config)
            ) {
                dismissKeyboard()
                onSubmitText(trimmedText(config: config))
            }

        case .options:
            EmptyView()
        }
    }

    // MARK: - Layout

    /// Whether this survey type has a submit button (combined/text) vs immediate submit (options).
    private var hasSubmitButton: Bool {
        switch rule.response {
        case .options: return false
        case .text, .combined: return true
        }
    }

    private var detentStyle: SurveySheetChrome.Detents {
        switch rule.response {
        case .options: return .compact
        case .text: return .medium
        case .combined: return .tall
        }
    }

    private var legacyBackground: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.97)
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: - Validation

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
        // Format: "option||text" or just "option" if no text
        let combinedResponse = trimmedText.isEmpty ? option : "\(option)||\(trimmedText)"

        onSubmitText(combinedResponse)
    }
}

// MARK: - Sheet chrome

/// Detents and background. On iOS 26 the sheet keeps the system glass
/// background, which only shows at a partial height, so each response type
/// opens at the height its content needs and can still be dragged to large.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SurveySheetChrome: ViewModifier {
    enum Detents { case compact, medium, tall }

    let detents: Detents
    let legacyBackground: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .presentationDetents(detentSet)
                .presentationDragIndicator(.visible)
        } else {
            legacy(content.background(legacyBackground.ignoresSafeArea()))
        }
        #else
        content.background(legacyBackground)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func legacy(_ content: some View) -> some View {
        if #available(iOS 16.0, *) {
            content
                .presentationDetents(detentSet)
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
    #endif

    #if os(iOS)
    @available(iOS 16.0, *)
    private var detentSet: Set<PresentationDetent> {
        switch detents {
        case .compact: return [.medium]
        case .medium: return [.fraction(0.6), .large]
        case .tall: return [.fraction(0.78), .large]
        }
    }
    #endif
}

/// Pins the submit button to the bottom. On iOS 26 it is a safe-area bar,
/// so the scroll view's edge effect softens the content beneath it.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SurveyBottomBar<Bar: View>: ViewModifier {
    let isVisible: Bool
    let legacyBackground: Color
    @ViewBuilder let bar: () -> Bar

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            withBar(content)
        } else {
            content
        }
    }

    @ViewBuilder
    private func withBar(_ content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar() }
        } else {
            legacyBar(content)
        }
    }

    /// Pre-iOS 26 only, so type-erased: ViewBuilder cannot express the
    /// iOS 14 fallback alongside `safeAreaInset`.
    private func legacyBar(_ content: Content) -> AnyView {
        if #available(iOS 15.0, tvOS 15.0, *) {
            return AnyView(content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar()
                }
                .background(legacyBackground.ignoresSafeArea())
            })
        }
        return AnyView(VStack(spacing: 0) {
            content
            Divider()
            bar().background(legacyBackground)
        })
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct KeyboardDismissOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SelectionHaptics: ViewModifier {
    let trigger: String?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            content.sensoryFeedback(.selection, trigger: trigger)
        } else {
            content
        }
    }
}

// MARK: - Controls

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SurveyCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Close")
        } else {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Circle().fill(Color.secondary.opacity(0.1)))
            }
            .accessibilityLabel("Close")
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SurveySubmitButton: View {
    let title: String
    let accent: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isEnabled ? accent.preferredForeground : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(isEnabled ? .regular.tint(accent).interactive() : .regular, in: Capsule())
            .disabled(!isEnabled)
            .animation(.easeInOut(duration: 0.2), value: isEnabled)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isEnabled ? accent.preferredForeground : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isEnabled ? accent : Color.secondary.opacity(0.3))
                    )
            }
            .disabled(!isEnabled)
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays the rating tiles out in one row; on iOS 26 inside a glass container
/// so neighbouring tiles blend and morph together.
@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct RatingRow<Tiles: View>: View {
    @ViewBuilder let tiles: () -> Tiles

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) { tiles() }
            }
        } else {
            HStack(spacing: 12) { tiles() }
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct RatingTile: View {
    enum Selection { case none, selected, deselected }

    let label: String
    let accent: Color
    let selection: Selection
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isSelected: Bool { selection == .selected }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            Button(action: action) {
                tileLabel(labelColor: isSelected ? accent.preferredForeground : .primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .glassEffect(isSelected ? .regular.tint(accent).interactive() : .regular.interactive(), in: shape)
            .opacity(selection == .deselected ? 0.6 : 1)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            Button(action: action) {
                tileLabel(labelColor: isSelected ? accent.preferredForeground : .primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isSelected ? accent : (colorScheme == .dark ? Color(white: 0.18) : Color.white))
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08),
                                    radius: isSelected ? 12 : 8, x: 0, y: isSelected ? 4 : 2)
                    )
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    private func tileLabel(labelColor: Color) -> some View {
        VStack(spacing: 8) {
            Text(RatingEmoji.for(label))
                .font(.system(size: 32))
                .scaleEffect(isSelected ? 1.15 : 1)
                .saturation(selection == .deselected ? 0.3 : 1)
                .accessibilityHidden(true)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
private struct SurveyTextEditor: View {
    @Binding var text: String
    let placeholder: String?
    let height: CGFloat
    let maxLength: Int?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                background

                TextEditor(text: $text)
                    .padding(12)
                    .modifier(TextEditorBackgroundModifier())

                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)

            if let maxLength {
                HStack {
                    Spacer()
                    Text("\(text.count)/\(maxLength)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(text.count > maxLength ? .red : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, *) {
            // A text field is content, not a control: a quiet fill reads
            // better on the glass sheet than another glass layer.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.fill.tertiary)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.18) : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - Helpers

private enum RatingEmoji {
    static func `for`(_ label: String) -> String {
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
private struct PressScaleButtonStyle: ButtonStyle {
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

@available(iOS 14.0, macOS 12.0, tvOS 14.0, watchOS 8.0, *)
extension Color {
    /// Black or white, whichever reads on this colour. A light brand accent
    /// (Club Lime's green) needs dark text; white on it fails contrast.
    var preferredForeground: Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .black : .white
        #else
        return .white
        #endif
    }
}
