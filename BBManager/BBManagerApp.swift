import BBManagerKit
import SwiftUI

@main
enum BBManagerMain {
    static func main() {
        // ssh launches this same executable as SSH_ASKPASS for password logins.
        if let account = ProcessInfo.processInfo.environment[SSHClient.askpassAccountVariable] {
            AskpassHelper.run(account: account)
        }
        BBManagerApp.main()
    }
}

enum AskpassHelper {
    static func run(account: String) -> Never {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        // Never confirm unknown host keys from here; StrictHostKeyChecking=accept-new handles first contact.
        if prompt.contains("yes/no") {
            FileHandle.standardOutput.write(Data("no\n".utf8))
            exit(0)
        }
        guard let password = Keychain.password(account: account) else { exit(1) }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        exit(0)
    }
}

struct BBManagerApp: App {
    @State private var model = AppModel()
    @AppStorage(AppDefaults.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some Scene {
        Window("BB Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1220, height: 780)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent()
                .environment(model)
        } label: {
            Label("BB Manager", systemImage: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Machine…") { model.sheet = .addMachine }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            Button("Overview") { model.selection = .overview }
                .keyboardShortcut("1")
            Button("Main Node") { model.selection = .mainNode }
                .keyboardShortcut("2")
            Button("Workers") { model.selection = .workers }
                .keyboardShortcut("3")
            Button("Statistics") { model.selection = .statistics }
                .keyboardShortcut("4")
            Button("Configuration") { model.selection = .configuration }
                .keyboardShortcut("5")
            Divider()
        }
        CommandMenu("Profile") {
            ProfileMenuItems()
                .environment(model)
        }
        CommandMenu("Cluster") {
            Button("Refresh Status") { Task { await model.pollAll() } }
                .keyboardShortcut("r")
            Divider()
            Button("Set Up Main Node…") { model.sheet = .setUpMainNode }
                .disabled(model.cluster.main != nil || model.machines.isEmpty)
            Button("Add Worker…") { model.sheet = .addWorker(preselectedMachine: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.cluster.main == nil)
            Button("Apply All Changes") { model.applyAllChanges() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!model.allRoles.contains(where: model.hasPendingChanges))
            Divider()
            Button("Open Portal") {
                if let url = model.portalURL { NSWorkspace.shared.open(url) }
            }
            .disabled(model.portalURL == nil)
        }
    }
}
