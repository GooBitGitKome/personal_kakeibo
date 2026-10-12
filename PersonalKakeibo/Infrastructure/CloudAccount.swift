import CloudKit
import Foundation

enum CloudAccount {
    static func description() async -> String {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "KakeiboCloudContainer") as? String else {
            return "端末内に保存します。iCloud同期はこのビルドで設定されていません。"
        }
        do {
            switch try await CKContainer(identifier: identifier).accountStatus() {
            case .available: return "iCloudにログインしています。同期完了は確認していません。"
            case .noAccount: return "iCloudにログインしていません。端末内の記録は利用できます。"
            case .restricted: return "iCloudの利用が制限されています。端末内の記録は利用できます。"
            case .temporarilyUnavailable: return "iCloudを一時的に利用できません。時間をおいて確認してください。"
            case .couldNotDetermine: return "iCloudの状態を確認できません。通信や設定を確認してください。"
            @unknown default: return "iCloudの状態を確認できません。"
            }
        } catch { return "iCloudの状態を確認できません。通信や設定を確認してください。" }
    }
}
