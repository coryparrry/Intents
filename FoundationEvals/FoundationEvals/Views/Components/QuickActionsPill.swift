import SwiftUI

struct QuickActionsPillAction: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let busyLabel: String
    var isEnabled = true
}

enum QuickActionsPillPhase: Equatable {
    case idle
    case thinking(String)
    case streaming(String)
    case result
}

struct QuickActionsPillLabels {
    var placeholder = "Describe edits"
    var keep = "Keep"
    var discard = "Discard"
    var retry = "Try again"
}

/// A contextual control, independent of selection, placement, and task execution.
struct QuickActionsPill: View {
    let primaryActions: [QuickActionsPillAction]
    let additionalActions: [QuickActionsPillAction]
    var labels = QuickActionsPillLabels()
    @Binding var prompt: String
    let phase: QuickActionsPillPhase
    let onAction: (QuickActionsPillAction) -> Void
    let onSubmit: () -> Void
    let onKeep: () -> Void
    let onDiscard: () -> Void
    let onRetry: () -> Void

    private let height: CGFloat = 44
    @State private var isExpanded = false
    @State private var lastBusyLabel = "Working"
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isPromptMode: Bool { isFocused || hasPrompt }
    private var motion: QuickActionsPillMotion { .init() }

    private var phasePosition: CGFloat {
        switch phase {
        case .idle: 0
        case .thinking, .streaming: 1
        case .result: 2
        }
    }

    private var activeBusyLabel: String? {
        switch phase {
        case .thinking(let label), .streaming(let label): label
        case .idle, .result: nil
        }
    }

    private var morphAnimation: Animation? { reduceMotion ? nil : motion.morph }
    private var contentAnimation: Animation? { reduceMotion ? nil : motion.content }
    private var menuSwapAnimation: Animation? { reduceMotion ? nil : motion.menuSwap }

    var body: some View {
        QuickActionsPillPhaseLayout(position: phasePosition) {
            idleControls
                .opacity(phase == .idle ? 1 : 0)
                .allowsHitTesting(phase == .idle)
                .accessibilityHidden(phase != .idle)
                .animation(contentAnimation, value: phasePosition)

            processingControls(label: activeBusyLabel ?? lastBusyLabel)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(activeBusyLabel == nil ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(activeBusyLabel == nil)
                .animation(contentAnimation, value: phasePosition)

            resultControls
                .fixedSize(horizontal: true, vertical: false)
                .opacity(phase == .result ? 1 : 0)
                .allowsHitTesting(phase == .result)
                .accessibilityHidden(phase != .result)
                .animation(contentAnimation, value: phasePosition)
        }
            .frame(height: height)
            .padding(4)
            .background {
                ZStack {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                    Capsule()
                        .stroke(.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
            // Keep the surface and controls on one geometry snapshot when the
            // pill's parent overlay moves.
            .geometryGroup()
            .animation(morphAnimation, value: phasePosition)
            .frame(maxWidth: .infinity)
            .frame(height: height + 8)
            .font(.callout)
            .foregroundStyle(.primary)
            .buttonStyle(QuickActionsPillButtonStyle())
            .onChange(of: phase) { _, next in
                if next != .idle {
                    isFocused = false
                    isExpanded = false
                }
                if case .thinking(let label) = next {
                    lastBusyLabel = label
                } else if case .streaming(let label) = next {
                    lastBusyLabel = label
                }
            }
    }

    private var idleControls: some View {
        HStack(spacing: 0) {
            ZStack {
                if isExpanded {
                    allActionsScrollView
                        .transition(expandedTransition)
                } else {
                    compactEntryControls
                        .transition(compactTransition)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            separator
            controlButtons
        }
        .animation(menuSwapAnimation, value: isPromptMode)
        .animation(menuSwapAnimation, value: isExpanded)
    }

    private var compactEntryControls: some View {
        HStack(spacing: 0) {
            promptField(maxWidth: .infinity)

            if isPromptMode {
                if hasPrompt {
                    sendButton
                        .transition(promptActionTransition)
                }
            } else {
                primaryActionsGroup
                    .transition(primaryActionsTransition)
            }
        }
    }

    private var allActionsScrollView: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(primaryActions + additionalActions) { actionButton($0) }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollIndicators(.hidden)
    }

    private var primaryActionsGroup: some View {
        ViewThatFits(in: .horizontal) {
            primaryActionsRow(iconOnly: false)
            primaryActionsRow(iconOnly: true)
        }
    }

    /// Lays out the primary actions after a separator, optionally showing their icons without visible titles.
    private func primaryActionsRow(iconOnly: Bool) -> some View {
        HStack(spacing: 0) {
            separator
            ForEach(primaryActions) {
                actionButton($0, iconOnly: iconOnly)
            }
        }
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.callout.weight(.semibold))
                .frame(width: height, height: height)
                .foregroundStyle(.background)
                .background(Color.primary, in: Circle())
        }
        .accessibilityLabel("Send prompt")
    }

    /// Binds the prompt field to focus state and routes keyboard submission through the guarded submit action.
    private func promptField(maxWidth: CGFloat) -> some View {
        TextField(labels.placeholder, text: $prompt)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(submit)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minWidth: 80, maxWidth: maxWidth)
            .frame(height: height)
            .layoutPriority(1)
    }

    /// A stable trailing slot lets the SF Symbol replace in place while the
    /// content beside it changes width and identity.
    private var controlButtons: some View {
        Button {
            if isPromptMode {
                clearPrompt()
            } else {
                isFocused = false
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isPromptMode ? "xmark" : "chevron.right")
                .contentTransition(.symbolEffect(.replace))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: height, height: height)
                .contentShape(Circle())
        }
        .accessibilityLabel(isPromptMode ? "Clear prompt" : isExpanded ? "Show fewer actions" : "Show more actions")
        .animation(contentAnimation, value: isPromptMode)
    }

    private var compactTransition: AnyTransition {
        .move(edge: .leading).combined(with: .opacity)
    }

    private var expandedTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    private var primaryActionsTransition: AnyTransition {
        .move(edge: .trailing).combined(with: .opacity)
    }

    private var promptActionTransition: AnyTransition {
        .scale(scale: 0.97).combined(with: .opacity)
    }

    /// Displays a combined accessible progress indicator for the current processing phase.
    private func processingControls(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
            Text("\(label)…")
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var resultControls: some View {
        HStack(spacing: 2) {
            Button(action: onKeep) {
                Label(labels.keep, systemImage: "checkmark")
                    .padding(.horizontal, 12)
                    .frame(minHeight: height)
                    .foregroundStyle(.background)
                    .background(Color.primary, in: Capsule())
            }
            Button(action: onDiscard) {
                Label(labels.discard, systemImage: "xmark")
                    .padding(.horizontal, 10)
                    .frame(minHeight: height)
                    .contentShape(Capsule())
            }
            separator
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: height, height: height)
                    .contentShape(Circle())
            }
            .accessibilityLabel(labels.retry)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    /// Builds an enabled-state-aware action button that clears text focus before invoking the host callback.
    private func actionButton(_ action: QuickActionsPillAction, iconOnly: Bool = false) -> some View {
        Button {
            isFocused = false
            onAction(action)
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: action.systemImage)
                        .frame(minWidth: 24)
                        .accessibilityLabel(action.title)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                        Text(action.title)
                    }
                }
            }
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: height)
                .contentShape(Capsule())
        }
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.35)
    }

    /// Submits only a nonempty prompt in the idle phase, releasing focus before calling the host.
    private func submit() {
        guard hasPrompt, phase == .idle else { return }
        isFocused = false
        onSubmit()
    }

    /// Clears the bound prompt and collapses the editor while releasing keyboard focus.
    private func clearPrompt() {
        prompt = ""
        isFocused = false
        isExpanded = false
    }
}
