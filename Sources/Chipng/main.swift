import AppKit
import SwiftUI

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--cli" {
    CommandLineMode.run(Array(arguments.dropFirst()))
}
ChipngApp.main()

struct ChipngApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Chipng", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export Each to Folder…") { model.exportToFolder() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
                Button("Export as ZIP…") { model.exportZip() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.canExport)
                Divider()
                Button("Replace Originals…") { model.requestReplace() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Clear All") { model.removeAll() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.items.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with “Open With → Chipng”.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
