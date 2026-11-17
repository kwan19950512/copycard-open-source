import SwiftUI

@main struct CopyCardApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { AISettingsView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("新建窗口") { AppModel.shared.openWindow() }.keyboardShortcut("n")
                }
            }
    }
}
