//! BLE の探索・接続・読み書き。UUID と各 characteristic のエンコードは `wakeari-protocol` を使う。

use std::time::{Duration, Instant};

use btleplug::api::{
    Central, CentralState, Characteristic, Manager as _, Peripheral as _, ScanFilter, WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use chrono::{Local, Offset, Utc};
use uuid::Uuid;
use wakeari_protocol as proto;

const MACOS_HINT: &str = "macOS では、ターミナルアプリに Bluetooth の許可が必要です。\
「システム設定 > プライバシーとセキュリティ > Bluetooth」でお使いのターミナルを許可してください。";

#[derive(Debug, thiserror::Error)]
pub enum BleError {
    #[error("Bluetooth アダプタが見つかりません。Bluetooth が使えるか確認してください。")]
    NoAdapter,
    #[error("Bluetooth がオフになっています。オンにしてからもう一度試してください。")]
    BluetoothOff,
    #[error("Bluetooth の使用が許可されていません。{}", permission_hint())]
    PermissionDenied,
    #[error(
        "Bluetooth の状態を取得できませんでした。Bluetooth がオンか、アプリに許可があるか確認してください。{}",
        permission_hint()
    )]
    AdapterUnavailable,
    #[error(
        "デバイスが見つかりません（{0}秒探しました）。デバイスの電源と距離を確認してください。{1}"
    )]
    NotFound(u64, String),
    #[error("入力値がデバイスに拒否されました")]
    Rejected,
    #[error("{0}がタイムアウトしました")]
    Timeout(&'static str),
    #[error(
        "デバイスが想定した GATT 構成ではありません（{0} がありません）。ファームウェアのバージョンを確認してください。"
    )]
    MissingCharacteristic(&'static str),
    #[error("デバイスとの接続が切れました")]
    Disconnected,
    #[error("デバイスから想定外のデータを受け取りました: {0}")]
    BadData(String),
    #[error("Bluetooth のエラー: {0}")]
    Other(String),
}

fn permission_hint() -> &'static str {
    if cfg!(target_os = "macos") {
        MACOS_HINT
    } else {
        ""
    }
}

/// btleplug のエラーを日本語のエラーにする。
pub fn map_err(e: btleplug::Error) -> BleError {
    use btleplug::Error as E;
    match e {
        E::PermissionDenied => BleError::PermissionDenied,
        E::NoAdapterAvailable => BleError::NoAdapter,
        E::NotConnected => BleError::Disconnected,
        E::DeviceNotFound => BleError::NotFound(0, String::new()),
        E::TimedOut(_) => BleError::Timeout("通信"),
        other => {
            let msg = other.to_string();
            let l = msg.to_lowercase();
            // 0x80 は仕様上「値の拒否」。OS ごとにエラー文言が違うので文字列で判定する。
            if l.contains("0x80")
                || l.contains("code=128")
                || l.contains("code: 128")
                || l.contains("unknown att error")
                || l.contains("protocolerror")
                || l.contains("protocol error")
            {
                BleError::Rejected
            } else if l.contains("not authorized") || l.contains("unauthorized") {
                BleError::PermissionDenied
            } else if l.contains("disconnect") || l.contains("not connected") {
                BleError::Disconnected
            } else {
                BleError::Other(msg)
            }
        }
    }
}

type R<T> = Result<T, BleError>;

/// スキャンで見つかったデバイス。
#[derive(Clone)]
pub struct Found {
    pub peripheral: Peripheral,
    /// プラットフォーム上の識別子（macOS は UUID、Windows はアドレス）。
    pub id: String,
    pub address: String,
    pub name: Option<String>,
    pub rssi: Option<i16>,
}

impl Found {
    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or("(名前なし)")
    }

    /// `--device` の指定（名前・id・アドレス）に一致するか。
    pub fn matches(&self, spec: &str) -> bool {
        let s = spec.trim().to_lowercase();
        self.id.to_lowercase() == s
            || self.address.to_lowercase() == s
            || self.name.as_deref().map(str::to_lowercase).as_deref() == Some(&s)
    }
}

pub async fn adapter() -> R<Adapter> {
    let manager = Manager::new().await.map_err(map_err)?;
    let adapter = manager
        .adapters()
        .await
        .map_err(map_err)?
        .into_iter()
        .next()
        .ok_or(BleError::NoAdapter)?;
    // CoreBluetooth は起動直後 Unknown のことがあるので少し待つ。
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        match adapter.adapter_state().await.map_err(map_err)? {
            CentralState::PoweredOn => return Ok(adapter),
            CentralState::PoweredOff => return Err(BleError::BluetoothOff),
            CentralState::Unknown => {
                if Instant::now() >= deadline {
                    // 未許可のときも Unknown のまま変わらない。
                    return Err(BleError::AdapterUnavailable);
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    }
}

fn service_uuid() -> Uuid {
    Uuid::from_u128(proto::SERVICE_UUID_U128)
}

async fn snapshot(adapter: &Adapter) -> R<Vec<Found>> {
    let mut out = Vec::new();
    for p in adapter.peripherals().await.map_err(map_err)? {
        let Some(props) = p.properties().await.map_err(map_err)? else {
            continue;
        };
        // macOS は OS 側のサービスフィルタを信頼する。他は念のためここでも絞る。
        if !cfg!(target_os = "macos") && !props.services.contains(&service_uuid()) {
            continue;
        }
        let name = props
            .local_name
            .clone()
            .or_else(|| props.advertisement_name.clone())
            .filter(|n| !n.is_empty());
        out.push(Found {
            id: p.id().to_string(),
            address: props.address.to_string(),
            name,
            rssi: props.rssi,
            peripheral: p,
        });
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(out)
}

/// スキャンをいつ打ち切るか。
pub enum Until<'a> {
    /// タイムアウトまで続ける（`scan` コマンド用）。
    Timeout,
    /// 指定に一致するデバイスが見つかったらすぐ。
    Match(&'a str),
    /// 最初のデバイスが見つかってから少し待つ（他の候補も拾うため）。
    FirstPlusGrace(Duration),
    /// id が一致するか、新しい名前に一致するデバイスを探す（名前変更後の再探索用）。
    Rediscover { id: &'a str, name: &'a str },
}

/// サービス UUID でスキャンする。見つかったデバイスを返す（0 件もあり得る）。
pub async fn scan(adapter: &Adapter, timeout: Duration, until: Until<'_>) -> R<Vec<Found>> {
    adapter
        .start_scan(ScanFilter {
            services: vec![service_uuid()],
        })
        .await
        .map_err(map_err)?;
    let start = Instant::now();
    let mut first_seen: Option<Instant> = None;
    let mut by_name_since: Option<Instant> = None;
    let result = loop {
        let found = snapshot(adapter).await;
        let found = match found {
            Ok(f) => f,
            Err(e) => break Err(e),
        };
        if !found.is_empty() && first_seen.is_none() {
            first_seen = Some(Instant::now());
        }
        let done = match &until {
            Until::Timeout => false,
            Until::Match(spec) => found.iter().any(|f| f.matches(spec)),
            Until::FirstPlusGrace(g) => first_seen.is_some_and(|t| t.elapsed() >= *g),
            Until::Rediscover { id, name } => {
                if found.iter().any(|f| f.id == *id) {
                    true
                } else if found.iter().any(|f| f.name.as_deref() == Some(*name)) {
                    // id が変わった場合のため、名前一致は少し待ってから採用する。
                    let t = *by_name_since.get_or_insert_with(Instant::now);
                    t.elapsed() >= Duration::from_secs(5)
                } else {
                    false
                }
            }
        };
        if done || start.elapsed() >= timeout {
            break Ok(found);
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    };
    let _ = adapter.stop_scan().await;
    result
}

/// 接続済みデバイスとの通信セッション。
pub struct Session {
    pub adapter: Adapter,
    pub found: Found,
    peripheral: Peripheral,
    time: Characteristic,
    command: Characteristic,
    status: Characteristic,
    schedules: Characteristic,
    config: Characteristic,
    name: Characteristic,
}

const OP_TIMEOUT: Duration = Duration::from_secs(8);

async fn with_timeout<T>(
    what: &'static str,
    fut: impl std::future::Future<Output = btleplug::Result<T>>,
) -> R<T> {
    match tokio::time::timeout(OP_TIMEOUT, fut).await {
        Ok(r) => r.map_err(map_err),
        Err(_) => Err(BleError::Timeout(what)),
    }
}

impl Session {
    /// 接続し、GATT を探索して、時刻を同期する。
    pub async fn connect(adapter: Adapter, found: Found) -> R<Session> {
        let p = found.peripheral.clone();
        with_timeout("接続", async {
            if !p.is_connected().await? {
                p.connect().await?;
            }
            Ok(())
        })
        .await?;
        let setup = async {
            with_timeout("サービスの探索", p.discover_services()).await?;
            let chars = p.characteristics();
            let find = |uuid: u128, label: &'static str| -> R<Characteristic> {
                let u = Uuid::from_u128(uuid);
                chars
                    .iter()
                    .find(|c| c.uuid == u)
                    .cloned()
                    .ok_or(BleError::MissingCharacteristic(label))
            };
            Ok(Session {
                time: find(proto::TIME_UUID_U128, "Time")?,
                command: find(proto::COMMAND_UUID_U128, "Command")?,
                status: find(proto::STATUS_UUID_U128, "Status")?,
                schedules: find(proto::SCHEDULES_UUID_U128, "Schedules")?,
                config: find(proto::CONFIG_UUID_U128, "Config")?,
                name: find(proto::NAME_UUID_U128, "Name")?,
                peripheral: p.clone(),
                adapter,
                found,
            })
        };
        let session = match setup.await {
            Ok(s) => s,
            Err(e) => {
                let _ = p.disconnect().await;
                return Err(e);
            }
        };
        if let Err(e) = session.sync_time().await {
            session.close().await;
            return Err(e);
        }
        Ok(session)
    }

    pub async fn close(&self) {
        let _ = tokio::time::timeout(Duration::from_secs(3), self.peripheral.disconnect()).await;
    }

    async fn write(&self, c: &Characteristic, data: &[u8], what: &'static str) -> R<()> {
        with_timeout(
            what,
            self.peripheral.write(c, data, WriteType::WithResponse),
        )
        .await
    }

    async fn read(&self, c: &Characteristic, what: &'static str) -> R<Vec<u8>> {
        with_timeout(what, self.peripheral.read(c)).await
    }

    /// 現在時刻（UTC 秒）とローカルのタイムゾーンオフセット（分）を書き込む。
    pub async fn sync_time(&self) -> R<()> {
        let now = Local::now();
        let offset_min = (now.offset().fix().local_minus_utc() / 60) as i16;
        let t = proto::TimeSync {
            epoch_s: Utc::now().timestamp(),
            tz_offset_min: offset_min,
        };
        self.write(&self.time, &t.encode(), "時刻の同期").await
    }

    pub async fn status(&self) -> R<proto::Status> {
        let b = self.read(&self.status, "状態の取得").await?;
        proto::Status::parse(&b).map_err(|e| BleError::BadData(format!("Status: {e:?}")))
    }

    pub async fn status_raw(&self) -> R<Vec<u8>> {
        self.read(&self.status, "状態の取得").await
    }

    pub async fn schedules(&self) -> R<Vec<proto::Slot>> {
        let b = self.read(&self.schedules, "アラームの取得").await?;
        let mut out = [proto::Slot {
            id: 0,
            enabled: false,
            weekday_mask: 0,
            hour: 0,
            minute: 0,
        }; proto::MAX_SLOTS];
        let n = proto::decode_schedules(&b, &mut out)
            .map_err(|e| BleError::BadData(format!("Schedules: {e:?}")))?;
        Ok(out[..n].to_vec())
    }

    pub async fn config(&self) -> R<proto::Config> {
        let b = self.read(&self.config, "設定の取得").await?;
        proto::Config::parse(&b).map_err(|e| BleError::BadData(format!("Config: {e:?}")))
    }

    pub async fn set_config(&self, cfg: proto::Config) -> R<()> {
        cfg.validate().map_err(|_| BleError::Rejected)?;
        self.write(&self.config, &cfg.encode(), "設定の書き込み")
            .await
    }

    pub async fn device_name(&self) -> R<String> {
        let b = self.read(&self.name, "デバイス名の取得").await?;
        Ok(String::from_utf8_lossy(&b).into_owned())
    }

    /// Name を書き込む。成功するとデバイスは約 500ms 後にリセットして切断する。
    /// 書き込み応答の前に切断された場合も成功として扱う。
    pub async fn write_name(&self, name: &str) -> R<()> {
        match self
            .write(&self.name, name.as_bytes(), "デバイス名の書き込み")
            .await
        {
            Err(BleError::Disconnected) => Ok(()),
            Err(BleError::Other(_) | BleError::Timeout(_))
                if !self.peripheral.is_connected().await.unwrap_or(false) =>
            {
                Ok(())
            }
            r => r,
        }
    }

    pub async fn send(&self, cmd: proto::Command) -> R<()> {
        let mut buf = [0u8; proto::COMMAND_MAX_LEN];
        let n = cmd.encode(&mut buf);
        self.write(&self.command, &buf[..n], "コマンドの送信").await
    }

    pub async fn put(&self, slot: proto::Slot) -> R<()> {
        slot.validate().map_err(|_| BleError::Rejected)?;
        self.send(proto::Command::Put(slot)).await
    }

    /// コマンド反映後の状態を読むための短い待ち。
    pub async fn settle(&self) {
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// 接続オプション。
pub struct Target {
    pub timeout: Duration,
    pub device: Option<String>,
}

/// スキャン → デバイス選択 → 接続 → 時刻同期。
pub async fn open(target: &Target) -> R<Session> {
    let adapter = adapter().await?;
    let until = match &target.device {
        Some(spec) => Until::Match(spec),
        None => Until::FirstPlusGrace(Duration::from_secs(2)),
    };
    let found = scan(&adapter, target.timeout, until).await?;
    let secs = target.timeout.as_secs();
    let chosen = match &target.device {
        Some(spec) => found
            .iter()
            .find(|f| f.matches(spec))
            .cloned()
            .ok_or_else(|| {
                let others = if found.is_empty() {
                    String::new()
                } else {
                    format!(
                        "（見つかったデバイス: {}）",
                        found.iter().map(describe).collect::<Vec<_>>().join(", ")
                    )
                };
                BleError::NotFound(secs, others)
            })?,
        None => {
            let first = found.first().cloned().ok_or_else(|| {
                BleError::NotFound(
                    secs,
                    if cfg!(target_os = "macos") {
                        MACOS_HINT.into()
                    } else {
                        String::new()
                    },
                )
            })?;
            if found.len() > 1 {
                eprintln!(
                    "注意: デバイスが {} 台見つかりました。{} に接続します。--device で指定できます。",
                    found.len(),
                    describe(&first)
                );
                for f in &found {
                    eprintln!("  - {}", describe(f));
                }
            }
            first
        }
    };
    Session::connect(adapter, chosen).await
}

pub fn describe(f: &Found) -> String {
    format!("{} [{}]", f.display_name(), f.id)
}
