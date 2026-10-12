import SwiftUI
import SwiftData
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    // Register before SwiftUI loads the store so cold-start notification taps are retained.
    let reminders = ReminderService()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "KakeiboCloudContainer") as? String != nil {
            application.registerForRemoteNotifications()
        }
        return true
    }
}

@main struct PersonalKakeiboApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: KakeiboViewModel?
    @State private var startupError: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let model { ContentView(model: model) }
                else if let startupError {
                    ContentUnavailableView {
                        Label("家計簿を開けません", systemImage: "exclamationmark.triangle")
                    } description: { Text(startupError + "\n既存データは削除していません。") }
                    actions: { Button("再試行") { start() } }
                } else { ProgressView("読み込み中…").task { start() } }
            }.environment(\.locale, Locale(identifier: "ja_JP"))
                .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo")!)
        }
    }
    @MainActor private func start() {
        do {
            let schema = Schema(versionedSchema: KakeiboSchema.self)
            let cloud = Bundle.main.object(forInfoDictionaryKey: "KakeiboCloudContainer") as? String
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: cloud.map { .private($0) } ?? .none)
            let container = try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: configuration)
            let store = Store(container: container)
            try store.seed()
            model = KakeiboViewModel(store: store, reminderService: delegate.reminders); startupError = nil
        } catch { startupError = "保存領域を初期化できませんでした。開発者に構成を確認してください。" }
    }
}
