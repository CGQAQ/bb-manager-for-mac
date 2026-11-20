import BBManagerKit
import SwiftUI

/// The profile pop-up at the top of the sidebar.
struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ProfileMenuItems()
        } label: {
            Label(model.cluster.name, systemImage: "square.stack.3d.up")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Profiles: each has its own cluster and machines")
    }
}

/// Profile items shared by the sidebar pop-up and the Profile menu.
struct ProfileMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let profiles = model.allProfiles
        Picker("Profile", selection: Binding(
            get: { model.activeProfileID },
            set: { model.switchProfile(to: $0) }
        )) {
            ForEach(profiles) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("New Profile…") { model.sheet = .newProfile }
        Button("Duplicate “\(model.cluster.name)”…") { model.sheet = .duplicateProfile(model.activeProfileID) }
        Button("Rename “\(model.cluster.name)”…") { model.sheet = .renameProfile(model.activeProfileID) }
        Divider()
        Button("Delete “\(model.cluster.name)”…", role: .destructive) {
            model.profilePendingDeletion = model.activeProfile
        }
        .disabled(profiles.count < 2)
    }
}

/// Names a new, duplicated or renamed profile.
struct ProfileNameSheet: View {
    enum Purpose {
        case create
        case duplicate(UUID)
        case rename(UUID)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let purpose: Purpose
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { name = initialName }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var problem: String? {
        if trimmed.isEmpty { return "Enter a name." }
        let others = model.allProfiles.filter {
            if case .rename(let id) = purpose { return $0.id != id }
            return true
        }
        if others.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "Another profile is already called “\(trimmed)”."
        }
        return nil
    }

    private var sourceName: String {
        switch purpose {
        case .create: ""
        case .duplicate(let id), .rename(let id): model.allProfiles.first { $0.id == id }?.name ?? ""
        }
    }

    private var initialName: String {
        switch purpose {
        case .create: Profile.uniqueName("New Profile", among: model.allProfiles)
        case .duplicate: Profile.uniqueName("\(sourceName) Copy", among: model.allProfiles)
        case .rename: sourceName
        }
    }

    private var title: String {
        switch purpose {
        case .create: "New Profile"
        case .duplicate: "Duplicate “\(sourceName)”"
        case .rename: "Rename “\(sourceName)”"
        }
    }

    private var actionTitle: String {
        switch purpose {
        case .create: "Create"
        case .duplicate: "Duplicate"
        case .rename: "Rename"
        }
    }

    private var note: String {
        switch purpose {
        case .create:
            "A profile has its own cluster and machines. Switching profiles changes what BB Manager shows and manages; nodes keep running on their machines."
        case .duplicate:
            "The copy starts with the same machines, saved passwords and cluster settings. Until you change them, both profiles manage the same nodes."
        case .rename:
            "The profile's name is also its cluster's name."
        }
    }

    private func save() {
        guard problem == nil else { return }
        let name = trimmed
        dismiss()
        switch purpose {
        case .create: model.createProfile(named: name)
        case .duplicate(let id): model.duplicateProfile(id, named: name)
        case .rename(let id): model.renameProfile(id, to: name)
        }
    }
}

extension View {
    /// Asks before deleting the profile in `model.profilePendingDeletion`.
    func profileDeletionConfirmation(_ model: AppModel) -> some View {
        @Bindable var model = model
        let profile = model.profilePendingDeletion
        return confirmationDialog(
            "Delete “\(profile?.name ?? "")”?",
            isPresented: Binding(
                get: { model.profilePendingDeletion != nil },
                set: { if !$0 { model.profilePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: profile
        ) { profile in
            Button("Delete Profile", role: .destructive) { model.deleteProfile(profile.id) }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            let machines = profile.machines.count
            let nodes = (profile.cluster.main == nil ? 0 : 1) + profile.cluster.workers.count
            Text("BB Manager forgets its cluster settings and its \(machines) machine\(machines == 1 ? "" : "s"), with their saved passwords. "
                + (nodes > 0
                    ? "Its \(nodes) node\(nodes == 1 ? " keeps" : "s keep") running on the machines; remove \(nodes == 1 ? "it" : "them") first to stop \(nodes == 1 ? "it" : "them")."
                    : "Nothing on the machines changes."))
        }
    }
}
