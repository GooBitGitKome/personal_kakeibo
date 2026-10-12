# Personal Kakeibo

iOS・iPadOS 17以上の個人用家計簿。SwiftUI、SwiftData、Swift Chartsを使用します。

入力、履歴の編集・確認付き削除、ジャンル管理、月別集計、12か月の推移、月間予算、CSV出力、JSONバックアップ・復元プレビューを実装しています。初期ジャンルは自動作成されます。日付・集計は日本時間・グレゴリオ暦です。

## 入力・予算・リマインダー

- ジャンルは3列のボタンで選択します。入力画面で長押しすると収入・支出それぞれの起動時の初期ジャンルになり、星で表示されます。
- テンキーの「00」で0を2桁追加できます。金額表示の右側の丸付き×ボタンで金額だけを全消去します。「⌫」は1桁削除です。メモ入力中に画面を下へスワイプするとキーボードを隠せます。入力・編集画面の日付から開くカレンダーには、収支のある日にドットを表示します。
- 設定 → ジャンル別の日額・月額予算で、食費などの上限を設定します。空欄で解除できます。保存・編集・削除の後に、その取引の日付・ジャンルの残額を画面で表示します。予算は毎日・毎月リセットされ、超過は負数です。
- リマインダーで毎日・毎週・毎月の収支予定を登録できます。期日分を確認して記録するか、その回だけスキップします。毎月の指定日が存在しない月は月末になります。無効化で予定の表示を休止できます。
- 予算・繰り返し収支ごとに「リマインドする」を選べます。予算は項目ごとに1日分の金額を個別通知します。日額設定を優先し、月額だけの場合は当月の日数で割り、1円未満を切り捨てます。繰り返し収支の確認通知は別にまとめます。初期時刻は7:00・12:00・18:00、最大3枠で変更・停止できます。月額の日割りは起動・復帰時に再計算するため、未起動で月をまたぐと次の起動まで前回の概算を通知します。通知から最新の残額と未記録予定を開けます。

集計・履歴の年月表示を押すとカレンダーが開き、年と月を選択できます。繰り返し収支は設定一覧の削除ボタンから削除できます。処理済み状態も削除し、記録済みの収支は残します。

初期ジャンル・通知時刻・通知許可は端末ごとの設定です。ジャンル別予算、繰り返し予定、処理済み状態は家計データに保存し、JSONバックアップにも含めます。従来のv1 JSONも読み込めます。既存ストアからは追加エンティティの軽量移行を行います。Appleのリマインダーアプリとの連携はありません。

## 開く・実行する

`PersonalKakeibo.xcodeproj`をXcode 26.3で開き、PersonalKakeiboスキームを選びます。Simulatorで実行するか、Signing & Capabilitiesで自分のTeamと実際のBundle IDを設定して実機で実行してください。標準のプロジェクトは端末内保存で、`com.example.PersonalKakeibo`は仮の識別子です。

プロジェクトを再生成する場合は、XcodeGenを用いて `xcodegen generate` を実行します。設定元は `project.yml` です。

## iCloud構成

実際に登録した識別子を指定して実行してください。値は自分のApple Developerアカウントのものに置き換えます。

```sh
python3 scripts/configure_cloud.py --team YOURTEAMID --bundle your.registered.bundle --container iCloud.your.registered.container
xcodegen generate --spec project-cloud.yml
```

生成される構成にはCloudKit、Remote notifications、development用のpush entitlementを含みます。XcodeでProvisioning ProfileとiCloud Containerの登録を確認してください。CloudKitの有効化を事前に省略したビルドで同期は行いません。設定したCloudKitコンテナの初期化に失敗した場合、空の保存領域への切替や既存データの削除は行いません。

同じApple AccountのiPhone・iPadで同期を確認する手順は [実機確認手順](docs/device-validation.md) にあります。署名・実際のContainer・2台の端末による同期確認は未実施です。

## テスト

Xcode 26.3 / Swift 6.2.4で次を実行します。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/kakeibo-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/kakeibo-swift-cache swift test --scratch-path /tmp/personal-kakeibo-build --disable-sandbox
```

DomainとApplicationをSwift Packageとして分離し、保存・復元・ViewModelのテストではSwiftDataのテスト用ストアと通知サービスの代替を使用します。33件のテストで00入力・金額全消去・項目別予算通知・日割り概算、連続保存、保存失敗時の入力保持、v1ストアからの移行、旧JSON互換、予算の日付境界、繰り返し収支の原子的保存・二重登録拒否・削除時の取引保持と失敗時のrollback、初期ジャンルと通知枠も確認しています。金額境界、整数オーバーフロー、月境界、編集時のID保持、アーカイブ、ファイル形式、再追加、保存失敗時のrollback、ディスク保存の再読み込み、10,000件の復元を対象にしています。

## 状態と資料

入力改善・予算・繰り返し収支の追加を実装した段階です。保存経路のモデル初期化と変更通知を修正し、診断ログを追加しています。Swift 6のCombineコールバックのスレッド検査による停止を最小コードで再現し、修正後の正常終了を確認しました。実機で報告された終了の原因特定・解消確認は未完了です。実機UI、VoiceOver、iPad分割表示、2台のiCloud同期、本番スキーマは未検証です。MVPの受け入れ完了や配布可能な状態を意味しません。

- [開発仕様](docs/development-specification.md)
- [採用した設計](docs/decisions/0002-first-implementation.md)
- [検証記録](docs/validation.md)
- [実機確認手順](docs/device-validation.md)
