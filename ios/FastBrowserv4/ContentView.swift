import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var biometricService = BiometricService()

    var body: some View {
        Group {
            if biometricService.isUnlocked {
                BrowserView()
            } else {
                LockScreenView(biometricService: biometricService)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                biometricService.lock()
            }
        }
    }
}
