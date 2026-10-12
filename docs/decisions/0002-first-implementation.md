# 初回版の設計決定

2026-10-12。利用者の「全ての必要な開発」「権限は全て許可」の指示を受け、仕様書12節の提案を採用する。0001の未承認として保留した事項を以下で更新する。

- iOS・iPadOS 17以上。Xcode 26.3 (17C529)、Swift 6.2.4を開発環境とする。
- 月集計はグレゴリオ暦・Asia/Tokyo、月初以上・翌月初未満。日時の保存はDate。
- 初期収入カテゴリは給与・その他。支出と合わせて9カテゴリに固定UUIDを割り当てる。
- メモ1,000文字、カテゴリ名40文字。未来日を許可する。カテゴリ区分は作成後に変更せず、アーカイブ解除を提供する。
- 予算は正数、未設定はレコードなし。同じ月の更新ではID・作成日時を保持する。
- JSONはschemaVersion 1、UTC ISO 8601・9桁の小数秒、Int64整数。浮動小数点表記の金額は拒否する。
- CSVはUTF-8、CRLF、全文字列の引用符エスケープ。カテゴリ名・メモの式開始文字には出力時だけアポストロフィを付ける。
- 追加復元は同一内容をスキップし相違を拒否する。上書きはID一致の更新であり、既存データを全件削除しない。別IDの同じ年月の予算は競合とする。カテゴリ区分の変更は復元でも拒否する。
- ファイルの暫定上限は50 MiB。10,000取引のテストを実施する。実機の応答性・メモリ量は別途確認する。

Domainは値型とRepositoryプロトコル、ApplicationはUse Case、Infrastructureは@Model・Repository・ファイル形式、PresentationはViewModelとSwiftUIとする。ViewはModelContextとRepositoryを直接操作しない。ファイルの読み込みとエンコード・デコードはバックグラウンドTask、SwiftDataへの一括適用はMainActor上の専用ModelContextで実行する。

モデルにはデフォルト値を設定し、unique属性とSwiftDataリレーションシップを使用しない。初版をVersionedSchema 1.0.0として記録する。将来の変更時にはMigration Planと旧ストア試験を追加する。

同期由来の同一論理IDはupdatedAtの新しい値を表示する。同日時はsortedKeys JSONの辞書順が小さい値を採用する。予算はmonthKey単位で同様に表示する。物理レコードは削除しない。重複状態での更新・復元・バックアップは拒否して確認を求める。これはCloudKitの同時編集競合をアプリで制御する保証ではない。

CloudKitは実際の識別子の設定があるビルドでPrivate Databaseを使用する。設定がない開発ビルドは明示的な端末内保存とし、設定済みコンテナの初期化失敗時の代替ストアは作らない。Infrastructureが保存・同期通知を受信してViewModelに変更を伝え、画面active時にも再取得する。通知の実機到達は未検証。

初期ストアと復元に対する書き込みは1回のsaveにまとめる。復元はプレビュー時点のスナップショットと保存直前の状態を比較し、変更があれば再プレビューを要求する。保存失敗でrollbackする。ローカルの一括保存は全端末同時の原子性を意味しない。

仮Bundle IDはcom.example.PersonalKakeibo。TeamとCloudKit Containerは未設定で、登録済みの設定として扱わない。独自認証、広告、解析SDK、家計データのログ出力は追加していない。

Apple API参照: [CloudKit構成](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct)、[rollback](https://developer.apple.com/documentation/swiftdata/modelcontext/rollback()).
