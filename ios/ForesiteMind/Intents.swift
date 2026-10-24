// Siri, Shortcuts, Spotlight and the Action button: "Add an action in Mind", "Show Mind", "Show my actions".

import AppIntents

struct AddActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Add an action"
    static var description = IntentDescription("Adds a line to your Mind action list, in the Inbox for triage.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Action", requestValueDialog: "What's the action?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppRouter.shared.add(text: text)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: reply)))
    }
}

struct ShowMindIntent: AppIntent {
    static var title: LocalizedStringResource = "Show the Mind"
    static var description = IntentDescription("Opens Mind on the live view of what Claude is doing.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open("mind")
        return .result()
    }
}

struct ShowActionsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show my actions"
    static var description = IntentDescription("Opens Mind on your action list.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.open("actions")
        return .result()
    }
}

struct MindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddActionIntent(), phrases: [
            "Add an action in \(.applicationName)",
            "Add to \(.applicationName)",
            "New \(.applicationName) action",
        ])
        AppShortcut(intent: ShowActionsIntent(), phrases: [
            "Show my actions in \(.applicationName)",
            "Open \(.applicationName) actions",
        ])
        AppShortcut(intent: ShowMindIntent(), phrases: [
            "Show the \(.applicationName)",
            "Open \(.applicationName)",
        ])
    }
}
