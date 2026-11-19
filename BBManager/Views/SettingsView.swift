import BBManagerKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SSHSettings()
                .tabItem { Label("SSH", systemImage: "key") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppDefaults.refreshInterval) private var refreshInterval = 10.0
    @AppStorage(AppDefaults.historyMinutes) private var historyMinutes = 30
    @AppStorage(AppDefaults.showMenuBarExtra) private var showMenuBarExtra = true

    var body: some View {
        Form {
            Picker("Refresh Status Every", selection: $refreshInterval) {
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
            }
            Picker("Keep Statistics For", selection: $historyMinutes) {
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("3 hours").tag(180)
            }
            Toggle("Show in Menu Bar", isOn: $showMenuBarExtra)
            LabeledContent("State File") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([StateStore.defaultURL])
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

struct SSHSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppDefaults.sshPath) private var sshPath = "/usr/bin/ssh"
    @AppStorage(AppDefaults.sshConnectTimeout) private var connectTimeout = 10
    @AppStorage(AppDefaults.sshExtraOptions) private var extraOptions = ""

    var body: some View {
        Form {
            Section {
                TextField("ssh Executable", text: $sshPath)
                    .font(.system(.body, design: .monospaced))
                IntegerField(title: "Connect Timeout", value: $connectTimeout, unit: "s", range: 2...120)
            } footer: {
                Text("BB Manager runs OpenSSH with your ~/.ssh/config and keeps one multiplexed connection per machine.")
            }
            Section {
                TextEditor(text: $extraOptions)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
            } header: {
                Text("Extra Options")
            } footer: {
                Text("One option per line, passed as -o. For example: ProxyJump=bastion.example.com")
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
        .onChange(of: sshPath) { model.applySSHSettings() }
        .onChange(of: connectTimeout) { model.applySSHSettings() }
        .onChange(of: extraOptions) { model.applySSHSettings() }
    }
}
