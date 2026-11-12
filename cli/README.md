# wakeari CLI

wakeari（BLE バルブアラーム）をパソコンから操作するコマンドラインツールです。`app/` のスマホアプリと同じ機能を、macOS と Windows のターミナルから使えます。通信仕様は [`docs/protocol.md`](../docs/protocol.md)（v2.1）に従い、エンコードとデコードは `firmware/protocol` の `wakeari-protocol` クレートをそのまま使っています。

## ビルドとインストール

Rust（stable）が必要です。

### macOS

```sh
# Homebrew の cargo が rustup を隠している場合は先に PATH を調整する
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

cd cli
cargo build --release          # target/release/wakeari
cargo install --path .         # ~/.cargo/bin/wakeari に入れる場合
```

### Windows

1. [rustup](https://rustup.rs/) をインストールします。MSVC ツールチェーン（`x86_64-pc-windows-msvc`、既定）を使います。
2. Visual Studio Build Tools（「C++ によるデスクトップ開発」ワークロード）をインストールします。リンカー（`link.exe`）と Windows SDK が必要です。
3. PowerShell で次を実行します。

```powershell
cd cli
cargo build --release          # target\release\wakeari.exe
cargo install --path .
```

Windows 10 以降で、Bluetooth LE に対応したアダプタが必要です。設定の「Bluetooth とデバイス」で Bluetooth をオンにしてください。

### macOS の Bluetooth 許可

macOS では、ターミナルアプリ（Terminal、iTerm2、VS Code など）に Bluetooth の許可が必要です。初回の実行で許可を求めるダイアログが出たら許可してください。出なかった、または拒否した場合は、次の場所で変更します。

「システム設定 > プライバシーとセキュリティ > Bluetooth」で、使っているターミナルアプリをオンにします。変更後はターミナルを開き直してください。

許可がないと「Bluetooth の状態を取得できませんでした」またはデバイスが見つからないエラーになります。

実行ファイルには `Info.plist`（`com.nukanoto.wakeari-cli`、Bluetooth の利用目的）を `build.rs` で埋め込んでいます。

## 共通の動作

デバイスと通信するコマンドは、次の順に動きます。

1. サービス UUID でスキャンする（既定 10 秒）
2. デバイスを選ぶ
3. 接続して GATT を探索する
4. 現在時刻とローカルのタイムゾーンを書き込む（アプリと同じ）
5. コマンドを実行する
6. 切断する

共通オプション:

| オプション | 内容 |
|---|---|
| `--timeout <秒>` | デバイスを探す時間。既定 10 |
| `-d, --device <名前またはID>` | 接続するデバイス。名前、または `scan` で表示される ID（macOS は UUID、Windows は Bluetooth アドレス）。省略時は最初に見つかったデバイスを使い、複数あれば一覧を表示する |
| `--json` | `scan` / `status` / `list` の出力を JSON にする |

失敗したときは終了コードが 0 以外になり、エラーメッセージは標準エラー出力に出ます。

## コマンド

### scan

```console
$ wakeari scan
名前     ID                                    電波強度
wakeari  3F2A1B9C-0D5E-4A7B-8C21-9E4F6A1D2B33  -58 dBm
```

### status

接続情報、デバイス名、デバイス時刻、バルブの状態、ON の長さ、次のアラームを表示します。

```console
$ wakeari status
接続: wakeari [3F2A1B9C-...]
デバイス名: wakeari
デバイス時刻: 2026-11-12 06:00:03（UTC+9）
バルブ: 停止中
ON の長さ: 30秒
次のアラーム: 07:00（木）あと 59分 ・ ID 0 ・ 平日
```

動作中は `バルブ: 動作中（アラーム ID 0: 07:00 平日（有効））　残り 20秒` のように、動かしているアラームを表示します（手動 ON のときは出ません）。

### list（別名 ls）

```console
$ wakeari list
ID  時刻   繰り返し    状態
0   07:00  平日        有効
1   09:30  土日        無効
2   22:00  月・水・金  有効
3   06:15  1回のみ     有効
```

### add

```sh
wakeari add 07:00 --days 平日
wakeari add 6:30 --days mon,wed,fri
wakeari add 22:00                  # 曜日なし = 1 回のみ
```

`--days` には次を指定できます。

- `weekdays` / `平日`（月〜金）
- `weekends` / `土日`
- `daily` / `毎日`
- 曜日のリスト: `mon,wed,fri` または `月,水,金`（`月・水・金` も可）
- `once` / `1回のみ` / `単発`

空いている最小の ID を使います。8 件まで登録でき、いっぱいのときはエラーになります。

### edit

```sh
wakeari edit 0 --time 06:45
wakeari edit 0 --days 毎日
wakeari edit 0 --once              # 1 回のみにする
```

### enable / disable / rm / clear

```sh
wakeari enable 1
wakeari disable 1
wakeari rm 1               # 別名: delete
wakeari clear              # 確認あり
wakeari clear --yes        # 確認なし
```

### stop

動作中のバルブを止めます（予約で ON になっている場合も止まります）。

### sync

デバイスの時刻を同期して、同期後の時刻を表示します。

### name

```sh
wakeari name               # 現在の名前を表示
wakeari name 寝室のバルブ  # 名前を変更
```

名前は 1〜29 バイト（UTF-8）で、制御文字は使えません。日本語なら全角 9 文字までです。変更するとデバイスが再起動して切断されます。CLI は切断を想定して待ち、デバイスを探し直し（最大 20 秒）、再接続して確認した新しい名前を表示します。

### debug

```sh
wakeari debug on                 # バルブを手動で ON（ON の長さの後に自動で止まる）
wakeari debug off                # バルブを OFF
wakeari debug duration           # ON の長さを表示
wakeari debug duration 60        # ON の長さを 60 秒にする（1〜3600）
wakeari debug duration --reset   # 30 秒に戻す
wakeari debug raw                # Status の生のバイトと各フィールド
```

## JSON 出力

```console
$ wakeari list --json
[
  { "id": 0, "time": "07:00", "weekday_mask": 31, "repeat": "平日", "enabled": true }
]
```

`status --json` は `device`、`device_name`、`time_synced`、`device_time`、`valve_on`、`remaining_s`、`active_slot`、`duration_s`、`next_alarm` を持つオブジェクトです。`scan --json` は `name` / `id` / `rssi` の配列です。

## エラー

| 状況 | メッセージの例 |
|---|---|
| Bluetooth がオフ | Bluetooth がオフになっています。 |
| アダプタがない | Bluetooth アダプタが見つかりません。 |
| 許可がない | Bluetooth の使用が許可されていません。（macOS は上の許可の手順） |
| デバイスが見つからない | デバイスが見つかりません。 |
| 値が拒否された（ATT 0x80） | 入力値がデバイスに拒否されました |
| 通信が応答しない | 〜がタイムアウトしました |

## 開発

```sh
cargo test
cargo clippy --all-targets -- -D warnings
cargo check --target x86_64-pc-windows-msvc    # Windows 向けの型検査（リンクは Windows 上で）
```

構成: `src/main.rs`（clap）、`src/ble.rs`（スキャン・接続・読み書き）、`src/schedule.rs`（曜日指定、ラベル、次回実行。純粋関数でテストあり）、`src/output.rs`（整形と JSON）、`src/commands/`（各コマンド）。
