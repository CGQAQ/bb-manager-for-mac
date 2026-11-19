import BBManagerKit
import SwiftUI

struct ConfigurationView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmImageReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Cluster Name", text: $model.cluster.name)
            } header: {
                Text("General")
            }

            if !model.allRoles.isEmpty {
                Section {
                    ForEach(model.allRoles, id: \.self) { role in
                        LabeledContent {
                            HStack {
                                if model.deployedAt(role) == nil {
                                    Text("Not deployed").foregroundStyle(.secondary)
                                } else if model.hasPendingChanges(role) {
                                    Label("Changes pending", systemImage: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.orange)
                                } else {
                                    Label("Up to date", systemImage: "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                Button("Settings…") {
                                    model.selection = role.isMain ? .mainNode : .worker(role.workerID!)
                                }
                            }
                        } label: {
                            Label(model.title(for: role), systemImage: role.isMain ? "server.rack" : "cpu")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Apply All Changes") { model.applyAllChanges() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.allRoles.contains(where: model.hasPendingChanges))
                    }
                } header: {
                    Text("Nodes")
                } footer: {
                    Text("Storage sizes, scheduler timeouts and ports live in the main node's Settings tab. Each worker has its own concurrency and cache settings.")
                }
            }

            Section {
                ImageField(title: "bb-storage", text: $model.cluster.images.storage)
                ImageField(title: "bb-scheduler", text: $model.cluster.images.scheduler)
                ImageField(title: "bb-worker", text: $model.cluster.images.worker)
                ImageField(title: "bb-runner-installer", text: $model.cluster.images.runnerInstaller)
                ImageField(title: "bb-portal", text: $model.cluster.images.portal)
                ImageField(title: "PostgreSQL", text: $model.cluster.images.postgres)
                HStack {
                    Link("Browse tags on GitHub", destination: URL(string: "https://github.com/orgs/buildbarn/packages")!)
                    Spacer()
                    Button("Reset to Recommended…") { confirmImageReset = true }
                        .disabled(model.cluster.images == .recommended)
                }
            } header: {
                Text("Container Images")
            } footer: {
                Text("Buildbarn publishes timestamped tags only. Keep bb-scheduler, bb-worker and bb-runner-installer on the same build. Applying changes pulls new images.")
            }

            Section {
                Text("New workers start with these settings. Existing workers keep their own.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Worker Defaults")
            }
            WorkerSettingsSections(settings: $model.cluster.workerDefaults, machine: nil)
        }
        .formStyle(.grouped)
        .navigationTitle("Configuration")
        .confirmationDialog("Reset container images?", isPresented: $confirmImageReset) {
            Button("Reset Images") { model.cluster.images = .recommended }
        } message: {
            Text("All images return to the versions BB Manager was tested with. Apply changes to deploy them.")
        }
    }
}

struct ImageField: View {
    var title: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.system(.callout, design: .monospaced))
                .help(text)
        }
    }
}
