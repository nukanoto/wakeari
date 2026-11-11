# wakeari BLE GATT プロトコル（v2.1）

ファームウェア（`firmware/protocol` クレート）とスマホアプリ（`app/lib/ble/protocol.dart`）は、この文書を共通の仕様として実装する。
多バイトの値はすべて **little-endian** で表す。

v1 からの変更点:
- 予約ごとの `duration_s` を廃止した。ON の時間は、全予約で共通の Config にまとめた。
- Slot を 5 bytes に縮めた。
- Config characteristic を追加した。
- Status に `active_slot` を追加した（13 bytes）。
- ON コマンドからペイロードを外した。

v2.1 で追加:
- Name characteristic を追加した（デバイス名を変更できる）。
- デバイス名をアドバタイズからスキャン応答へ移した。

## アドバタイズ
- アドバタイズデータ: Flags と Primary Service UUID `9643763d-ca0d-45be-bae0-e3d2170256fe` だけを載せる。
- スキャン応答: Complete Local Name（デバイス名）を載せる。
- デバイス名の初期値は `wakeari`。GAP の Device Name（0x2A00）も同じ値にする。
- GATT 構成を変えたときは、ファームの `GATT_DB_VERSION` を上げて BLE アドレスを変える（iOS の GATT キャッシュ対策）。v2.1 では `3`。

## Characteristics

| 名前 | UUID | 属性 | 長さ |
|---|---|---|---|
| Time | `59049d1c-3f43-4b9a-b9cd-ff479d454afa` | Write | 10 |
| Command | `6e0e3b6f-0aa8-40ad-855e-d527c4ce7e2e` | Write | 1〜6 |
| Status | `5eb782eb-b27c-4a34-ac18-03cf8f2ad6ff` | Read, Notify | 13 |
| Schedules | `75f7c1b1-0233-4282-a2d0-0932961212a8` | Read, Notify | 1 + 5×N（最大41） |
| Config | `8dbfbc93-2938-4495-a466-b2c67133bfd4` | Read, Write, Notify | 2 |
| Name | `85fae2ad-ab1d-436a-922b-a3435a12154b` | Read, Write | 1〜29 |

### Name（1〜29 bytes）
- 中身はデバイス名の UTF-8 バイト列（終端の NUL は付けない）。
- 長さが 1〜29 bytes に収まり、正しい UTF-8 で、制御文字（U+0000〜U+001F, U+007F）を含まない場合だけ受け付ける。それ以外は ATT エラー `0x80` を返す。
- 29 bytes はスキャン応答（31 bytes）に Complete Local Name を載せられる上限。日本語なら全角 9 文字まで。
- 受け付けると、ファームはフラッシュに保存して約 500ms 後にソフトウェアリセットする。リセット後のアドバタイズと GAP Device Name には新しい名前を使う。
- アプリは書き込みが成功したら、切断に備えて自動で再スキャンし、同じデバイスへ再接続する。

### Time（10 bytes）
| offset | 型 | 内容 |
|---|---|---|
| 0 | i64 | 現在の UNIX 時刻（秒, UTC） |
| 8 | i16 | タイムゾーンオフセット（分）。JST なら `540`。範囲は -720〜840 |

アプリは接続直後に必ず書き込む。ファームは tz を保存するが、時刻は電源が切れると失われる。再び同期されるまで予約は実行しない。

### Command
先頭 1 バイトが opcode。

| opcode | 名前 | ペイロード | 動作 |
|---|---|---|---|
| `0x01` | ON | なし | 即時 ON（手動テスト用）。Config の `duration_s` 秒後に自動 OFF。ON 中に送ると残り時間を上書きする |
| `0x02` | OFF | なし | 即時 OFF（予約で ON になっている場合も止める） |
| `0x10` | PUT | Slot（5 bytes） | 同じ id のスロットを追加または上書き |
| `0x11` | DELETE | `id: u8` | スロットを削除 |
| `0x12` | CLEAR | なし | 全スロットを削除 |

不正な長さ、未知の opcode、範囲外の値はエラーとして扱い、状態を変えない（ATT エラー `0x80` を返す）。

### Slot（5 bytes）
| offset | 型 | 内容 |
|---|---|---|
| 0 | u8 | `id`（0〜7） |
| 1 | u8 | `enabled`（0 / 1） |
| 2 | u8 | `weekday_mask`: bit0=月, bit1=火, … bit6=日。`0` は単発。上位ビットは 0 |
| 3 | u8 | `hour`（0〜23, ローカル時刻） |
| 4 | u8 | `minute`（0〜59） |

- 繰り返し: `weekday_mask` の曜日の `hour:minute`（ローカル時刻）に、Config の `duration_s` 秒だけ ON する。
- 単発（mask=0）: 次に来る `hour:minute` に 1 回だけ実行し、実行後にファームが `enabled=0` にする（スロット自体は残す）。
- 同じスロットは同じ分に 2 回以上発火しない。
- 最大 8 件（id 0〜7）。

### Config（2 bytes）
| offset | 型 | 内容 |
|---|---|---|
| 0 | u16 | `duration_s`: 1 回の ON の長さ（1〜3600）。初期値はファームの定数 `DEFAULT_DURATION_S = 30` |

- Write で変更すると、ファームはフラッシュに保存して Notify する。範囲外の値は ATT エラー `0x80` を返す。
- アプリでは「デバッグ」画面からだけ変更する。

### Status（13 bytes）
| offset | 型 | 内容 |
|---|---|---|
| 0 | u8 | `valve_on`（0 / 1） |
| 1 | u16 | `remaining_s`（OFF のとき 0。デバッグ表示用） |
| 3 | u8 | `time_synced`（0 / 1） |
| 4 | i64 | `now_epoch`（UTC 秒。未同期なら 0） |
| 12 | u8 | `active_slot`: いま ON にしている予約の id。手動 ON か OFF のときは `0xFF` |

状態が変わったときと、ON 中は 1 秒ごとに Notify する。同じ分に複数の予約が発火した場合、`active_slot` は id が最小のものにする。

### Schedules
`count: u8` に続いて、Slot（5 bytes）を `count` 個並べる（id の昇順）。スロットが変わるたびに Notify する。

## 保存
- フラッシュに保存するのは tz、全スロット、Config、デバイス名の 4 つ。
- v1 形式で保存されたスロット（7 bytes）を読み込めなかった場合は、空として扱ってよい。

## 安全
- GPIO2 は起動時 Low（OFF）。
- 1 回の ON は最大 3600 秒（ファームの定数 `MAX_DURATION_S`）。
