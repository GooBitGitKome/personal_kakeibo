import Foundation
import Observation
import PersonalKakeiboDomain

struct ReminderMessage: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

@MainActor protocol ReminderScheduling: AnyObject {
    var status: String { get }
    var onOpen: (() -> Void)? { get set }
    func requestPermission() async
    func update(messages: [ReminderMessage], slots: [ReminderSlot])
}

#if os(iOS)
import UserNotifications

@MainActor @Observable final class ReminderService: NSObject, UNUserNotificationCenterDelegate, ReminderScheduling {
    var status = "通知の状態を確認中…"
    var onOpen: (() -> Void)? {
        didSet {
            if pendingOpen, let onOpen { pendingOpen = false; onOpen() }
        }
    }
    private var pendingOpen = false
    private let center = UNUserNotificationCenter.current()
    private var updateTask: Task<Void, Never>?
    override init() {
        super.init()
        center.delegate = self
    }
    func requestPermission() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { status = "通知を有効にできませんでした：" + error.localizedDescription }
    }
    func update(messages: [ReminderMessage], slots: [ReminderSlot]) {
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            await reconcile(messages: messages, slots: slots)
        }
    }
    private func reconcile(messages: [ReminderMessage], slots: [ReminderSlot]) async {
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        status = allowed ? "通知は許可されています" : settings.authorizationStatus == .notDetermined ? "通知を有効にすると許可を確認します" : "通知は許可されていません。iOSの設定で変更できます。"
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("kakeibo.daily.") || $0.hasPrefix("kakeibo.reminder.") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard allowed, !messages.isEmpty, ReminderSlot.validate(slots) else { return }
        // Reserve all requested items or report the capacity issue instead of silently dropping items.
        let otherCount = pending.count - ids.count
        guard messages.count * slots.filter(\.isEnabled).count + otherCount <= 64 else {
            status = "通知の予約数が上限を超えています。通知対象の項目または時刻枠を減らしてください。"
            return
        }
        var scheduledIds: [String] = []
        do {
            for message in messages {
                for slot in slots where slot.isEnabled {
                    let content = UNMutableNotificationContent()
                    content.title = message.title
                    content.body = message.body
                    content.sound = .default
                    var components = DateComponents()
                    components.calendar = Month.calendar; components.timeZone = Month.calendar.timeZone
                    components.hour = slot.hour; components.minute = slot.minute
                    let identifier = "kakeibo.reminder.\(message.id).\(slot.id)"
                    let request = UNNotificationRequest(identifier: identifier, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
                    scheduledIds.append(identifier)
                    try await center.add(request)
                }
            }
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: scheduledIds)
            status = "通知の予約に失敗しました：" + error.localizedDescription
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            if let onOpen { onOpen() } else { pendingOpen = true }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif
