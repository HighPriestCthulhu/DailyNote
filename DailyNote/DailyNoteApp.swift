import SwiftUI

@main
struct DailyNoteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                model.sceneBecameActive() // day rollover + pick up synced edits
            case .inactive, .background:
                model.sceneWillResign() // flush unsaved edits
            default:
                break
            }
        }
    }
}
