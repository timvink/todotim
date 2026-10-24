import SwiftUI
import TodoCore
import UniformTypeIdentifiers

/// Sheet that imports Todoist data, either live through the Todoist API (with a personal API
/// token that is never stored) or from a `TodoistSnapshot` JSON file. Re-importing updates
/// earlier imports instead of duplicating them.
///
/// Present it as a sheet with the store in the environment:
///
///     .sheet(isPresented: $showImport) { ImportTodoistView().environment(store) }
struct ImportTodoistView: View {
    @Environment(TodoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Held only while the sheet is open; cleared after each import attempt.
    @State private var token = ""
    @State private var includeCompleted = false
    @State private var phase: Phase = .idle
    @State private var fetchTask: Task<Void, Never>?
    @State private var showFilePicker = false

    private enum Phase {
        case idle
        case working(String)
        case done(ImportReport, source: String)
        case failed(String)
    }

    private static let developerSettingsURL = URL(string: "https://app.todoist.com/app/settings/integrations/developer")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import from Todoist")
                .font(.system(size: 16, weight: .bold))
                .padding(16)
            Divider()
            Form {
                SwiftUI.Section {
                    SecureField("API token", text: $token, prompt: Text("Paste your Todoist API token"))
                        .onSubmit(importFromAPI)
                        .disabled(isWorking)
                    Toggle("Include completed tasks", isOn: $includeCompleted)
                        .disabled(isWorking)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("In Todoist, open Settings › Integrations › Developer and copy the API token. TodoTim uses it for this import only and does not save it.")
                        Link("Open Todoist developer settings", destination: Self.developerSettingsURL)
                        Text("Importing again updates what was imported before instead of adding duplicates. Recurrence, times, comments and reminders are not imported.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if case .idle = phase {} else {
                    SwiftUI.Section("Status") { status }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Import from file…") { showFilePicker = true }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(isWorking)
                Spacer()
                Button(isDone ? "Done" : "Cancel") {
                    fetchTask?.cancel()
                    dismiss()
                }
                .buttonStyle(SoftButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("Import", action: importFromAPI)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(isWorking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importFromFile(url)
            case .failure(let error): phase = .failed(error.localizedDescription)
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            token = ""
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
            }
        case .failed(let message):
            SwiftUI.Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.overdue)
                .textSelection(.enabled)
        case .done(let report, let source):
            VStack(alignment: .leading, spacing: 4) {
                SwiftUI.Label(report.hasChanges ? "Imported from \(source)." : "Already up to date with \(source).",
                              systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.today)
                ForEach(report.summaryLines, id: \.self) { Text($0).font(.system(size: 12)) }
                ForEach(report.warnings, id: \.self) { w in
                    SwiftUI.Label(w, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    private var options: TodoistImportOptions { TodoistImportOptions(includeCompleted: includeCompleted) }

    private func importFromAPI() {
        guard !isWorking else { return }
        let api: TodoistAPI
        do {
            api = try TodoistAPI(token: token)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        token = ""
        phase = .working("Connecting to Todoist…")
        let options = options
        fetchTask = Task {
            do {
                let snapshot = try await api.fetchSnapshot { step, count in
                    Task { @MainActor in
                        if case .working = phase { phase = .working("Fetching \(step)… \(count)") }
                    }
                }
                try Task.checkCancellation()
                phase = .working("Importing…")
                let report = TodoistImport.apply(snapshot, to: store, options: options)
                phase = .done(report, source: "Todoist")
            } catch {
                // Cancelling surfaces as CancellationError or as a cancelled URL request.
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    private func importFromFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let snapshot = try TodoistSnapshot.load(from: url)
            let report = TodoistImport.apply(snapshot, to: store, options: options)
            phase = .done(report, source: url.lastPathComponent)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
