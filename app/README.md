# wakeari アプリ

ESP32-C5 の電磁弁コントローラ「wakeari」を BLE で操作する Flutter アプリ（Android / iOS）。
通信仕様は [`docs/protocol.md`](../docs/protocol.md) を参照。

## 実行方法

```sh
cd app
flutter pub get
flutter run            # 実機を接続して実行（BLE はシミュレーター/エミュレーターでは動かない）
flutter analyze
flutter test
flutter build apk --debug
```

- Android 12 以降は実行時に「付近のデバイス」権限を要求する。11 以前は位置情報権限が必要。
- iOS は実機でのビルド時に署名設定（Xcode の Signing & Capabilities）が必要。

## 画面

### スキャン画面
Service UUID でフィルタして wakeari を探す。見つかるまでは中央に変形するインジケーターを表示する。
見つかったデバイスは行ごとに「接続」ボタンを持ち、接続中はそのボタンに進捗を表示する（他の行は無効）。
接続直後にアプリが現在時刻（UTC 秒 + タイムゾーン）を書き込み、Config を読み出して Notify を購読する。

### ホーム画面
- 上部: 「wakeari ● 接続中」と設定ボタン。
- ヒーロー: 待機中は次のアラーム（あと何時間何分・時刻・日付）、動作中は「動作中」と停止ボタン、次のアラーム。
  次のアラームはデバイスの時刻（未同期なら端末の時刻）から全スロットで計算する（`lib/state/next_run.dart`）。
- アラーム一覧: 全幅の行。スイッチで有効/無効、タップで編集、左スワイプで削除（「元に戻す」付き）。最大 8 件。
- アラームを追加 / 編集: ボトムシートで時刻と曜日（未選択は 1 回のみ）を設定する。ON の長さはアラームごとには持たない。

### 設定画面
デバイス名・接続・デバイスの時刻・タイムゾーン・今すぐ時刻を同期、デバッグ、切断、バージョン。

### デバッグ画面
- ON にする時間（Config, 1〜3600 秒。デバイスに保存）の変更と初期値（30 秒）への復帰。
- 手動テスト（ON / OFF）、状態の生データ表示、アラームの全削除。

## テスト

```sh
flutter test                                   # プロトコル・次の実行時刻・表示整形
flutter build ios --release -t integration_test/ble_e2e_test.dart
```

`integration_test/ble_e2e_test.dart` は実機（ESP32-C5 + iPhone）用の結合テスト。
リリースビルドを `xcrun devicectl ... --console` で動かす想定で、ログは stdout に出し、
最後に `E2E RESULT: PASS|FAIL ...` と `SMOKE RESULT: PASS|FAIL ...` を出力する。

## 構成

| パス | 内容 |
|---|---|
| `lib/ble/protocol.dart` | プロトコル v2 のエンコード/デコードと検証（純 Dart） |
| `lib/ble/device_repository.dart` | スキャン・接続・時刻同期・Notify 購読・コマンド送信・Config 書き込み |
| `lib/state/providers.dart` | Riverpod プロバイダ（接続・ステータス・予約・Config・デバイス時計） |
| `lib/state/next_run.dart` | 次のアラームの計算（純 Dart） |
| `lib/ui/theme.dart` | Material 3 Expressive 風テーマ（動的カラー対応） |
| `lib/ui/` | ホーム・スキャン・設定・デバッグ画面とウィジェット |

## 補足
- BLE ライブラリ `flutter_blue_plus` はライセンス区分の指定が必須で、個人利用向けの `License.nonprofit` を指定している。商用利用する場合は `device_repository.dart` の指定とライセンスを見直すこと。
- 動的カラーは端末の primary 色をシードにして ColorScheme を生成している。
