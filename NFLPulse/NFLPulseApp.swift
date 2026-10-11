import SwiftUI
import BackgroundTasks

@main
struct NFLPulseApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task(id: phase) {
                    guard phase == .active else { return }
                    await store.refreshIfNeeded()
                    // A single cancellable loop for this scene; freshness gates decide actual requests.
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) }
                        catch { return }
                        await store.refreshIfNeeded()
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .background { store.scheduleBackground() }
                }
        }
        .backgroundTask(.appRefresh(AppStore.backgroundID)) {
            await store.refreshIfNeeded()
            await store.scheduleBackground()
        }
    }
}
