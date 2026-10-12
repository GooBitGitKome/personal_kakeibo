# 検証記録

検証日: 2026-10-12。環境: macOS、Xcode 26.3 (17C529)、Swift 6.2.4、iPhoneOS SDK 26.2。


## 金額全消去・00入力・項目別予算通知（2026-10-12）

- `swift test --scratch-path /tmp/personal-kakeibo-build --disable-sandbox`（既存手順のモジュールキャッシュ環境変数を使用）は32件成功、失敗0。
- 追加3件で、00入力と19桁制限、全消去後のメモ・日付・ジャンル保持、28/29/30/31日の日割り、日額優先、端数切り捨て、未設定、最大金額を検証。
- 代替通知サービスで項目別の名前・概算額・安定した識別子、月変更時の再計算、予算通知オフ・解除、アーカイブによる除外、繰り返し収支の独立した確認通知を検証。
- `/tmp/kakeibo-input-reminders-project` に `project-buildcheck.yml` から確認用プロジェクトを生成。署名なし・Asset Catalogを除外したiPhoneOSビルドは成功。通常構成のビルドは `No available simulator runtimes for platform iphonesimulator` により `CompileAssetCatalogVariant` で失敗した。
- 新旧の予約整理と項目・時刻枠ごとの繰り返し予約を実装。通知予約数を64件以内に抑えるため、超過時は対象項目または時刻枠を減らす案内を表示する。OSへの予約・取り消しと配信は実機では未検証。
- スワイプの判定範囲・方向・閾値とVoiceOverアクションを実装したが、実機UI検証は未実施。確認手順は `docs/device-validation.md` に追加。
- 月額予算からの概算は起動・復帰時に更新する。未起動で月をまたいだ場合は次回起動まで前回の概算額を繰り返し通知する。

検証ログ: `/tmp/kakeibo-input-reminders-tests.log`、`/tmp/kakeibo-input-reminders-code-ios.log`、`/tmp/kakeibo-input-reminders-ios.log`。

## 入力・予算・リマインダー追加（2026-10-12）

最終の `swift test` は29件成功、失敗0。既存15件に14件の検証を追加した。

- Core Dataの変更通知をバックグラウンドから送信し、コールバックがMainActorへ移って画面更新することを確認。
- ViewModelから30回連続保存し、入力消去・取引件数・残額を確認。save前の障害注入では入力が保持され、追加レコードがrollbackされる。
- 初期ジャンルのViewModel再生成後の保持、収支区分ごとの独立性、アーカイブ時の代替選択。
- 日額・月額予算、日本時間の開始・終了境界、予算超過、編集・削除の再計算、未設定、集計オーバーフロー。
- 毎日・毎週・毎月の期日、閏年・月末補正、未処理予定の表示、無効化、スキップ。
- 繰り返し収支と処理済み状態を一括保存し、失敗時の両方のrollbackと二重記録・二重スキップの拒否を確認。
- v1のディスクストアにカテゴリ・取引・予算を保存してv2へ移行。既存値の保持と、新しい予算・予定・処理状態の再読み込みを確認。
- v2 JSONの全項目往復・復元・再追加、従来v1 JSONの読み込み、新データを保持した追加復元。
- 通知枠の上限・重複時刻拒否・全枠停止、通知対象のアーカイブ時の停止、通知を開くコールバックによるタブ遷移を代替サービスで確認。

追加後のアプリ全体のiPhoneOSビルドも署名なし・Asset Catalogを除外した確認用構成で成功。確認用プロジェクトは `/tmp` に生成し、通常のプロジェクトはアイコンと既存の署名Teamを保持した構成にしている。

```sh
mkdir -p /tmp/kakeibo-update-project
xcodegen generate --spec project-buildcheck.yml --project /tmp/kakeibo-update-project
xcodebuild -project /tmp/kakeibo-update-project/PersonalKakeibo.xcodeproj -scheme PersonalKakeibo -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/kakeibo-update-ios CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
```

SwiftDataモデルのinitを直接代入に変更し、ローカル保存通知による余分な再取得を除去した。MainActor内で作られたCombineのsinkコールバックは、Swift 6でバックグラウンド通知を受けると実行スレッド検査で停止する可能性がある。コールバックを明示的な `@Sendable` にして、画面更新だけをMainActorへ移した。

同じ構造の最小コードを `/tmp/kakeibo-actor-notification-probe.swift` に用意し、Swift 6でコンパイルして確認した。修正前のコールバックはバックグラウンド通知でsignal 4（終了コード132）となり、`@Sendable` を付けた同じコードは終了コード0で `BACKGROUND_CALLBACK_COMPLETED` を出力した。これは元の通知経路にクラッシュ条件がある証拠であり、報告された実機のクラッシュスタックとの一致を確認したものではない。保存の各段階は `PersonalKakeibo` subsystemの `Entry` / `Persistence` categoryにログを記録する。金額・メモなどの家計情報はログに含めない。

実機のクラッシュ記録はこの環境に見つからず、終了の原因は断定していない。CoreSimulatorServiceに接続できず、CoreDeviceServiceの初期化もタイムアウトしたため、実機での終了解消、スワイプ・長押し・カレンダーUI、許可ダイアログ、OS通知配信、通知からのコールド起動は未検証。新エンティティのCloudKit同期と端末間の同時処理も未検証であり、2台での同時記帳の一意性を保証するものではない。

UserDefaultsへの初期ジャンル・時刻の保存には、[Appleの利用理由CA92.1](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc)をPrivacy Manifestに宣言した。

## 初回版（追加前）の検証

## 実行結果

`swift test`で15件成功、失敗0。Domain 4件、SwiftData・ファイル形式・Applicationの結合テスト11件。テストの家計情報は架空。

| 検証 | 結果 |
| --- | --- |
| ASCII数字、ゼロ・負数・小数・Int64範囲外の拒否 | 成功 |
| 集計のオーバーフロー、開始を含み終了を除外、空一覧 | 成功 |
| 日本時間の年月、閏年2月、不正年月の拒否 | 成功 |
| 取引の保存・編集・削除、ID・createdAt保持 | 成功 |
| アーカイブ後の既存参照保持と新規入力拒否 | 成功 |
| 予算の未設定・保存・更新、カテゴリ名とメモ制限 | 成功 |
| ディスクストアの再読み込み | 成功 |
| JSON全値・小数秒の往復、CSVの引用符と改行 | 成功 |
| JSONの未知バージョン、UUID重複、参照不正、小数金額の拒否 | 成功 |
| 同一バックアップの再追加、追加の競合拒否、上書きプレビュー | 成功 |
| プレビュー後に状態が変わった場合の拒否 | 成功 |
| save直前の障害注入で一括更新がrollbackされる | 成功 |
| 同じ論理IDの表示統合と物理レコード保持 | 成功 |
| 10,000取引のJSON出力・読込・プレビュー・一括保存 | 成功、4,049,324 bytes、約5.85秒 |

10,000件の処理は当初約26.9秒だった。日時フォーマッタの再利用とID索引によるマージにより約5.85秒に短縮した。数字はMacのテスト用メモリストアでの1回の実測であり、実機の応答性・メモリ量を保証しない。アプリではファイル読み込み・変換をバックグラウンドTaskで実行し、一括保存はMainActorで行う。

## ビルドと環境制約

iPhoneOS向けのアプリ、Domain、Applicationのコード全体は、署名なし・アイコンカタログを除外した確認用構成でビルド成功した。Privacy Manifestも含む。確認用構成は `project-buildcheck.yml`、最終のXcodeプロジェクトは通常の `project.yml` から再生成している。

```sh
xcodegen generate --spec project-buildcheck.yml
xcodebuild -project PersonalKakeibo.xcodeproj -scheme PersonalKakeibo -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath /tmp/kakeibo-ios-build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' build
xcodegen generate
```

この環境ではCoreSimulatorServiceに接続できない。通常構成のAsset Catalogコンパイルは「No available simulator runtimes for platform iphonesimulator」で失敗した。アイコン画像とカタログは用意しているが、そのコンパイルとSimulator起動は未確認。制限環境でSwiftマクロを実行するため、検証コマンドではコンパイラの `-disable-sandbox` を指定した。これはリリース用プロジェクト設定には追加していない。

SwiftDataテスト中にOSのstore changed通知登録の権限警告が出た。ローカル保存・復元テストは成功しているが、同期通知の到達性を検証した結果としては扱わない。

## 残る確認

実際のApple Developer Team、Bundle ID、CloudKit Containerは未提供のため、iCloudを有効にした署名・接続は未実施。標準構成は端末内保存。CloudKit設定用生成スクリプトと未ログイン等の状態案内は実装している。

AC01、AC04、AC09〜AC11、AC17、AC18のUI・2台実機部分、共有UI、初期化失敗の画面、実機での保存エラー、CloudKit本番スキーマは未検証。AC15の障害注入はsave直前に例外を発生させる試験であり、ディスク障害そのものの再現ではない。AC20は初版スキーマのため未適用。

MVPの受け入れ完了・本番同期保証・配布完了とは扱わない。続きは [実機確認手順](device-validation.md) に従う。
