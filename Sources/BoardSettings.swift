import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct BoardSettings: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var schedule: ScheduleModel

    var body: some View {
        Form {
            Section("Calendar") {
                if schedule.nativeCalendarNames.isEmpty {
                    Button("Connect Mac Calendar") { Task { await schedule.connect() } }
                    Text("Add the same Google or iCloud accounts in macOS Internet Accounts and turn on Calendars to sync those events.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connected to Mac Calendar. Dayboard checks for calendar changes about once a minute.")
                        .foregroundStyle(.secondary)
                }
                if let error = schedule.error { Text(error).foregroundStyle(.red) }
                if model.connected {
                    Text("Notion Calendar entries are refreshed from your Tasks database.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Notion") {
                Button(model.notionConfiguration == nil ? "Import Notion configuration…" : "Replace Notion configuration…",
                       action: importConfiguration).disabled(model.busy)
                if model.notionConfiguration == nil {
                    Text("Import a configuration file to link Dayboard to your Notion databases.")
                        .foregroundStyle(.secondary)
                }
                SecureField("Notion API token", text: $model.tokenDraft)
                    .onSubmit(connect)
                HStack {
                    Button(model.connected ? "Replace token" : "Connect", action: connect)
                        .disabled(model.notionConfiguration == nil || model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || model.readingSavedToken)
                    if model.connected {
                        Button("Disconnect", action: model.disconnect).disabled(model.busy)
                    } else if model.notionConfiguration != nil {
                        Button("Use saved token") {
                            Task {
                                await model.restoreSavedToken()
                                await model.refresh()
                            }
                        }
                        .disabled(model.readingSavedToken || model.busy)
                    }
                    if model.busy || model.readingSavedToken { ProgressView().controlSize(.small) }
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red)
                } else if model.connected {
                    Text("Refreshes automatically every minute.").foregroundStyle(.secondary)
                } else {
                    Text("Use a Notion API token with read access to Tasks, Good Habits, Activity Log and Character. For check-ins, allow the connection to insert into Activity Log.")
                        .foregroundStyle(.secondary)
                }
                if let habitProblem = model.habitProblem { Text(habitProblem).foregroundStyle(.red) }
                if let journalProblem = model.journalProblem { Text(journalProblem).foregroundStyle(.red) }
                if model.notionConfiguration?.journalSourceID != nil {
                    Text("Daily Journal uses the date on this Mac. Give your connection read and create access to the journal’s data source.")
                        .foregroundStyle(.secondary)
                }
                Link("Create a Notion API token", destination: URL(string: "https://www.notion.so/developers/tokens")!)
                if let config = model.notionConfiguration {
                    HStack(spacing: 10) {
                        if let url = config.tasksURL { Link("Tasks", destination: url) }
                        if let url = config.habitSourceURL ?? config.habitsURL { Link("Good Habits", destination: url) }
                        if let url = config.activityURL { Link("Activity Log", destination: url) }
                        if let url = config.characterURL { Link("Character", destination: url) }
                        if let url = config.journalURL { Link("Journal", destination: url) }
                    }
                }
                if !model.pendingCheckIns.isEmpty {
                    Text("\(model.pendingCheckIns.count) pending check-in\(model.pendingCheckIns.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Button("Sync check-ins") { Task { await model.syncCheckIns() } }
                        .disabled(!model.connected || model.busy)
                }
                if let checkInProblem = model.checkInProblem { Text(checkInProblem).foregroundStyle(.red) }
            }
            Section("Desktop") {
                Toggle("Light text on wallpaper", isOn: $schedule.lightText)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                if model.loginStatus == .requiresApproval {
                    Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = model.loginProblem { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importNotionConfiguration(from: url) }
        }
    }

    private func connect() {
        Task {
            if await model.connect(model.tokenDraft) { model.tokenDraft = "" }
        }
    }
}
