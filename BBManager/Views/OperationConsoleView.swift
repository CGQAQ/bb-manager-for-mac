import SwiftUI

struct OperationConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    var session: OperationSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                stateIcon
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(text: session.log.text, label: "Copy Log")
            }
            .padding(16)
            Divider()
            LogView(buffer: session.log)
                .frame(minHeight: 320)
            Divider()
            HStack {
                if case .failed(let message) = session.state {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if session.isRunning {
                    Button("Cancel", role: .cancel) { session.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Hide") { dismiss() }
                        .help("Keep running in the background")
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 760, height: 520)
        .interactiveDismissDisabled(session.isRunning)
    }

    private var subtitle: String {
        switch session.state {
        case .running: "Running on \(session.machineName)…"
        case .succeeded: "Finished on \(session.machineName)"
        case .failed: "Failed on \(session.machineName)"
        case .cancelled: "Cancelled"
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch session.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}
