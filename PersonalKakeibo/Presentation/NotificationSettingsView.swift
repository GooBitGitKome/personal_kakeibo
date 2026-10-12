import SwiftUI
import UIKit
import PersonalKakeiboDomain

struct NotificationSettingsView: View {
    @Bindable var model: KakeiboViewModel
    @State private var slots = ReminderSlot.defaults
    @State private var message: String?
    @State private var error: String?
    var body: some View {
        Form {
            Section("通知時刻（最大3回）") {
                ForEach(slots.indices, id: \.self) { index in
                    Toggle(["朝", "昼", "晩"][index], isOn: $slots[index].isEnabled)
                    DatePicker("時刻", selection: Binding(get: {
                        Month.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: slots[index].hour, minute: slots[index].minute))!
                    }, set: { date in
                        let parts = Month.calendar.dateComponents([.hour, .minute], from: date)
                        slots[index].hour = parts.hour!; slots[index].minute = parts.minute!
                        message = nil
                    }), displayedComponents: .hourAndMinute).disabled(!slots[index].isEnabled)
                }
                Button("時刻を保存") {
                    do { try model.setNotificationSlots(slots); error = nil; message = "通知時刻を保存しました" }
                    catch { self.error = error.localizedDescription; message = nil }
                }
                Button("7時・12時・18時に戻す") { slots = ReminderSlot.defaults; message = nil }
                if let message { Text(message).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("通知の許可") {
                Text(model.reminderService.status)
                Button("iOSの通知設定を開く") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Section {
                Text("予算で「リマインドする」を選ぶと、毎日この時刻に項目ごとの1日分の予算を通知します。有効な繰り返し収支の確認通知は別にまとめて送ります。時刻は1日最大3枠で、すべてオフにすると停止します。時刻は日本時間です。")
                Text("月額予算の日割りはアプリの起動・復帰時に再計算します。アプリを開かずに月をまたぐと、次の起動まで前回の概算額を通知します。保存ごとの残額はアプリ内で表示し、通知を開くと最新の残額と未記録の予定を確認できます。")
            }
        }.navigationTitle("通知設定")
            .onAppear { slots = model.preferences.slots; model.updateNotifications() }
    }
}
