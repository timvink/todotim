import SwiftUI
import TodoCore

/// Settings (⌘,): WebDAV sync configuration.
struct SettingsView: View {
    @Environment(SyncController.self) private var sync
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var folder = "TodoTim"
    @State private var enabled = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var saved = false

    var body: some View {
        Form {
            SwiftUI.Section {
                TextField("Server URL", text: $serverURL, prompt: Text("https://cloud.example.com/remote.php/dav/files/USERNAME/"))
                TextField("Username", text: $username)
                SecureField("App password", text: $password)
                TextField("Folder", text: $folder, prompt: Text("TodoTim"))
                Toggle("Enable sync", isOn: $enabled)
            } header: {
                Text("WebDAV (Nextcloud)")
            } footer: {
                Text("Use a Nextcloud app password (Settings → Security → Devices & sessions). The password is stored in the Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SwiftUI.Section("Status") {
                HStack {
                    statusText
                    Spacer()
                }
                if let r = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? Theme.today : Theme.overdue)
                        Text(r.message).textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button {
                    testing = true
                    testResult = nil
                    let s = currentSettings
                    let pw = password
                    Task {
                        let err = await sync.testConnection(s, password: pw)
                        testResult = err == nil ? (true, "Connection works.") : (false, err!)
                        testing = false
                    }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test connection") }
                }
                .disabled(testing || serverURL.isEmpty || username.isEmpty)
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary).font(.system(size: 12)) }
                Button("Save") {
                    sync.configure(currentSettings, password: password.isEmpty ? nil : password)
                    saved = true
                    if currentSettings.enabled { model.syncNow() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            let s = sync.settings
            serverURL = s.serverURL
            username = s.username
            folder = s.folder.isEmpty ? "TodoTim" : s.folder
            enabled = s.enabled
            password = sync.storedPassword() ?? ""
        }
        .onChange(of: currentSettings) { saved = false }
    }

    private var currentSettings: SyncSettings {
        SyncSettings(serverURL: serverURL.trimmingCharacters(in: .whitespaces),
                     username: username.trimmingCharacters(in: .whitespaces),
                     folder: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty
                        ? "TodoTim" : folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                     enabled: enabled)
    }

    @ViewBuilder private var statusText: some View {
        switch sync.status {
        case .disabled:
            SwiftUI.Label("Sync is off", systemImage: "icloud.slash")
        case .idle(let last):
            SwiftUI.Label(last.map { "Last synced \($0.formatted(date: .abbreviated, time: .standard))" } ?? "Not synced yet",
                          systemImage: "checkmark.icloud")
        case .syncing:
            SwiftUI.Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud")
        case .error(let msg):
            SwiftUI.Label(msg, systemImage: "exclamationmark.icloud").foregroundStyle(Theme.overdue)
        }
    }
}
