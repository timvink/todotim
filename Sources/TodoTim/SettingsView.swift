import SwiftUI
import TodoCore

/// Settings (⌘,): CalDAV sync configuration.
struct SettingsView: View {
    @Environment(SyncController.self) private var sync
    @Environment(AppModel.self) private var model
    @State private var serverURL = ""
    @State private var username = ""
    /// A new password typed by the user. The saved one is never loaded into the view.
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var enabled = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var saved = false

    var body: some View {
        Form {
            SwiftUI.Section {
                if let managed = sync.managedConfigPath {
                    // Settings come from the config file; only the password can be changed here.
                    LabeledContent("Server URL", value: serverURL.isEmpty ? "—" : serverURL)
                    LabeledContent("Username", value: username.isEmpty ? "—" : username)
                    SecureField("App password", text: $password, prompt: Text(hasStoredPassword ? "Saved in Keychain" : ""))
                    LabeledContent("Sync", value: enabled ? "Enabled" : "Disabled")
                    Text("Managed by \(Self.abbreviatingHome(managed))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Server URL", text: $serverURL, prompt: Text("https://cloud.example.com/remote.php/dav/"))
                    TextField("Username", text: $username)
                    SecureField("App password", text: $password, prompt: Text(hasStoredPassword ? "Saved in Keychain" : ""))
                    Toggle("Enable sync", isOn: $enabled)
                }
            } header: {
                Text("CalDAV (Nextcloud)")
            } footer: {
                Text("Your projects sync as Nextcloud task lists (CalDAV). Use a Nextcloud app password (Settings → Security → Devices & sessions); it is stored in the Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SwiftUI.Section("Status") {
                HStack {
                    statusText
                    Spacer()
                }
                if let warning = sync.warning {
                    SwiftUI.Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let err = sync.credentialError {
                    SwiftUI.Label(err, systemImage: "key.slash")
                        .foregroundStyle(Theme.overdue)
                        .textSelection(.enabled)
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
                    // Use the newly typed password, or else the one saved in the Keychain.
                    let pw = password.isEmpty ? (sync.storedPassword() ?? "") : password
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
                    if !password.isEmpty {
                        password = ""
                        hasStoredPassword = true
                    }
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
            enabled = s.enabled
            password = ""
            hasStoredPassword = !(sync.storedPassword() ?? "").isEmpty
        }
        .onChange(of: currentSettings) { saved = false }
    }

    /// "/Users/tim/.todotim.toml" → "~/.todotim.toml".
    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var currentSettings: SyncSettings {
        SyncSettings(serverURL: serverURL.trimmingCharacters(in: .whitespaces),
                     username: username.trimmingCharacters(in: .whitespaces),
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
