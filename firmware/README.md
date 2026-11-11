# wakeari ファームウェア

ESP32-C5 (RISC-V, `riscv32imac-unknown-none-elf`) 用の Rust ファームウェア。
GPIO2 で NPN トランジスタ経由の電磁弁を駆動し、BLE GATT でスマホアプリから
時刻同期・手動 ON/OFF・スケジュール管理（最大 8 件）・ON の長さ（Config）の設定を行う。
通信仕様は [`../docs/protocol.md`](../docs/protocol.md)（v2.1）に従う。

v2 では予約ごとの時間を廃止し、ON の長さは全予約・手動 ON 共通の Config `duration_s`（1〜3600、初期値 30 秒）にまとめた。
Slot は 5 bytes、ON コマンドはペイロードなし、Status は 13 bytes（`active_slot` 付き）。

## 構成

| パス | 内容 |
|---|---|
| `protocol/` | `wakeari-protocol`（no_std、ホストでテスト可能）。UUID、各バイト列（Slot / Config / Command / Status など）の parse/encode、曜日計算、スケジュール発火ロジック（発火した id を返す） |
| `src/main.rs` | 初期化。GPIO2 を最初に Low にし、保存データを復元してタスクを起動 |
| `src/config.rs` | 共通の ON の長さ（Config）。起動時にフラッシュから復元、書き込みで検証・保存・通知 |
| `src/valve.rs` | GPIO2 を所有するタスク。`VALVE_CMD`（On(active_slot)/Off）を受け、Config の秒数だけ ON して自動 OFF（最大 3600 秒にクランプ）。予約で ON なら `active_slot` に id、手動 ON / OFF / 自動 OFF では `0xFF`。OFF は予約による ON も止める。状態を `state()` で公開 |
| `src/clock.rs` | 壁時計。`sync()` で epoch との差分を保持。tz のみ永続化。未同期なら `now_epoch()` は `None` |
| `src/scheduler.rs` | 1 秒ごとに `Schedule::tick` を評価してバルブを ON。同じ分に複数発火したら id が最小のものを `active_slot` にする。単発スロットは発火後に `enabled=0` にして保存・通知 |
| `src/name.rs` | デバイス名（初期値 `wakeari`）。起動時にフラッシュから復元。不正・未保存なら初期値 |
| `src/ble.rs` | TrouBLE の GATT サーバ（Time / Command / Status / Schedules / Config / Name）。Config は Read・Write・Notify（不正値は ATT `0x80`）。Name は Read・Write（1〜29 bytes、UTF-8、制御文字なし。不正は ATT `0x80`）。書き込みが通ると保存の完了を待って応答し、約 500 ms 後にソフトウェアリセット。アドバタイズデータは Flags + Service UUID のみ、スキャン応答に Complete Local Name。切断後は再アドバタイズ |
| `src/storage.rs` | `nvs` パーティションに sequential-storage の map で tz・スケジュール・Config・Name を保存（書き込みは 300 ms デバウンス。Name だけはデバウンスせず即保存し、完了を通知する）。v1 形式（7 bytes Slot）のスケジュールは読めないためログに出して空で起動 |

## セットアップ

Homebrew の rustc/cargo が rustup より優先されることがあるため、コマンドの前に必ず PATH を通す。

```sh
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cargo install espflash --locked
```

`rust-toolchain.toml` により stable と `riscv32imac-unknown-none-elf` ターゲット、`rust-src` が使われる。

## テスト（プロトコルクレート、ホスト実行）

```sh
cd firmware/protocol
cargo test --target aarch64-apple-darwin   # Apple Silicon 以外ではホストのターゲットに置き換える
```

## ビルドと書き込み

```sh
cd firmware
cargo build --release
cargo run --release     # espflash flash --monitor --chip esp32c5 が走る
```

`esp-radio` は最適化が必須のため、dev プロファイルでも `[profile.dev.package.esp-radio] opt-level = 3` を指定している。
パーティションテーブルは espflash 既定のもの（`nvs` データパーティションを含む）を使う。

## 補足

- アドバタイズデータは Flags + 128-bit Service UUID のみ（21 bytes）。名前はスキャン応答（Complete Local Name、最大 29 bytes）に載せる。接続可能・スキャン可能（`ConnectableScannableUndirected`）でアドバタイズする。
- GAP Device Name（0x2A00）は保存した名前。ただし trouble-host 0.7 は内部バッファが 22 bytes のため、それを超える名前は UTF-8 の文字境界で切り詰める（アドバタイズ・Name characteristic は全長）。
- GATT 構成（characteristic の増減など）を変えたら `src/ble.rs` の `GATT_DB_VERSION` を上げる。BLE アドレスに XOR され、iOS の GATT キャッシュを避ける。v2.1（Name 追加）で `3`。
- GPIO2 は起動直後に Low（OFF）。1 回の ON は最大 `MAX_DURATION_S`（3600 秒）。
- 時刻は電源が切れると失われる。接続後に Time が書き込まれるまでスケジュールは実行されない。
- 不正な Command / Time の書き込みは ATT エラー `0x80` で拒否し、状態を変えない。
- ログは `esp-println` でシリアルへ出力する。
