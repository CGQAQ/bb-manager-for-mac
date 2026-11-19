import AppKit
import BBManagerKit
import SwiftUI

// MARK: - Status

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

struct HealthBadge: View {
    var health: NodeHealth

    var body: some View {
        Label(health.label, systemImage: health.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(health.color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(health.color.opacity(0.12), in: Capsule())
    }
}

struct ConnectivityBadge: View {
    var connectivity: Connectivity

    var body: some View {
        HStack(spacing: 6) {
            if connectivity == .checking {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(color: connectivity.color)
            }
            Text(connectivity.label)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Cards

struct StatCard: View {
    var title: String
    var value: String
    var detail: String? = nil
    var symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            // Always reserve the detail line so cards in a row line up.
            Text(detail ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

struct Card<Content: View>: View {
    var title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }
}

struct Banner: View {
    var symbol: String
    var tint: Color
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
            // No fixedSize here: when SwiftUI measures the window's minimum size it
            // proposes a tiny width, and a fixed-height text would grow very tall
            // and push the whole window's content up under the toolbar.
            Text(text)
                .font(.callout)
                .lineLimit(1...3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - Fields

struct NumberField: View {
    var title: String
    @Binding var value: Double
    var unit: String
    var range: ClosedRange<Double>
    var step: Double = 1
    var help: String? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }
}

struct IntegerField: View {
    var title: String
    @Binding var value: Int
    var unit: String = ""
    var range: ClosedRange<Int>
    var step: Int = 1
    var help: String? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .leading)
                }
                Stepper(title, value: clamped, in: range, step: step)
                    .labelsHidden()
            }
        } label: {
            Text(title)
            if let help { Text(help) }
        }
    }

    private var clamped: Binding<Int> {
        Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }
}

struct CopyButton: View {
    var text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

// MARK: - Text views

/// Read-only, auto-scrolling monospaced log view backed by NSTextView.
struct LogView: View {
    var buffer: LogBuffer

    var body: some View {
        LogTextView(chunks: buffer.chunks, generation: buffer.generation)
    }
}

struct LogTextView: NSViewRepresentable {
    var chunks: [String]
    var generation: Int

    final class Coordinator {
        var count = 0
        var generation = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        let clip = scrollView.contentView
        let atBottom = clip.bounds.maxY >= textView.frame.maxY - 30
        if coordinator.generation != generation || coordinator.count > chunks.count {
            storage.setAttributedString(NSAttributedString(string: chunks.joined(), attributes: Self.attributes))
        } else if coordinator.count < chunks.count {
            storage.append(NSAttributedString(string: chunks[coordinator.count...].joined(), attributes: Self.attributes))
        } else {
            return
        }
        coordinator.count = chunks.count
        coordinator.generation = generation
        if atBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

/// Plain-text code editor with every “smart” substitution turned off.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            // Keep the caret where it was, clamped to the new text. Never assign an
            // empty `selectedRanges` array: AppKit throws ("no ranges") and the app crashes.
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        }
    }
}

// MARK: - Misc

extension Date {
    var relativeDescription: String {
        RelativeDateTimeFormatter().localizedString(for: self, relativeTo: Date())
    }
}

struct EmptyStateButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}
