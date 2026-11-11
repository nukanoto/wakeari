//! BLE GATT サーバ（TrouBLE）。仕様は docs/protocol.md。

use bt_hci::controller::ExternalController;
use embassy_futures::join::join;
use embassy_futures::select::{Either4, select, select4};
use embassy_time::{Duration, Timer};
use esp_radio::ble::controller::BleConnector;
use heapless::Vec;
use static_cell::StaticCell;
use trouble_host::prelude::*;
use wakeari_protocol::{
    NO_ACTIVE_SLOT, Command, Config, NAME_MAX_LEN, SCHEDULES_MAX_LEN, SERVICE_UUID_U128, Status, TimeSync,
};

use crate::config::{self, CONFIG_CHANGED};
use crate::scheduler::{self, SCHEDULE_CHANGED};
use crate::valve::{self, STATUS_CHANGED, VALVE_CMD, ValveCmd};
use crate::{clock, name, storage};

pub type BleController = ExternalController<BleConnector<'static>, 1>;

const CONNECTIONS_MAX: usize = 1;
const L2CAP_CHANNELS_MAX: usize = 1;
/// GATT 構成の版。Characteristic を増減したら上げる（BLE アドレスに反映される）。
const GATT_DB_VERSION: u8 = 3;

/// trouble-host 0.7 の GAP Device Name 上限（gap.rs の DEVICE_NAME_MAX_LENGTH）
const GAP_NAME_MAX_LEN: usize = 22;

/// ATT アプリケーションエラー（不正な書き込み）
const ATT_ERR_INVALID: AttErrorCode = AttErrorCode::new(0x80);

#[gatt_server]
struct Server {
    wakeari: WakeariService,
}

// UUID は docs/protocol.md / wakeari_protocol::*_UUID と同じ値
#[gatt_service(uuid = "9643763d-ca0d-45be-bae0-e3d2170256fe")]
struct WakeariService {
    #[characteristic(uuid = "59049d1c-3f43-4b9a-b9cd-ff479d454afa", write)]
    time: Vec<u8, 10>,
    #[characteristic(uuid = "6e0e3b6f-0aa8-40ad-855e-d527c4ce7e2e", write)]
    command: Vec<u8, 6>,
    #[characteristic(uuid = "5eb782eb-b27c-4a34-ac18-03cf8f2ad6ff", read, notify)]
    status: [u8; 13],
    #[characteristic(uuid = "75f7c1b1-0233-4282-a2d0-0932961212a8", read, notify)]
    schedules: Vec<u8, 41>,
    #[characteristic(uuid = "8dbfbc93-2938-4495-a466-b2c67133bfd4", read, write, notify)]
    config: [u8; 2],
    #[characteristic(uuid = "85fae2ad-ab1d-436a-922b-a3435a12154b", read, write)]
    name: Vec<u8, NAME_MAX_LEN>,
}

fn current_status() -> Status {
    let vs = valve::state();
    let now = clock::now_epoch();
    Status {
        valve_on: vs.on,
        remaining_s: valve::remaining_s(),
        time_synced: now.is_some(),
        now_epoch: now.unwrap_or(0),
        active_slot: vs.active_slot,
    }
}

fn schedules_value() -> Vec<u8, SCHEDULES_MAX_LEN> {
    let mut buf = [0u8; SCHEDULES_MAX_LEN];
    let n = scheduler::snapshot().encode(&mut buf);
    Vec::from_slice(&buf[..n]).unwrap_or_default()
}

fn refresh_status(server: &Server<'_>) {
    let _ = server.set(&server.wakeari.status, &current_status().encode());
}

fn refresh_schedules(server: &Server<'_>) {
    let _ = server.set(&server.wakeari.schedules, &schedules_value());
}

fn refresh_config(server: &Server<'_>) {
    let _ = server.set(&server.wakeari.config, &config::get().encode());
}

fn refresh_name(server: &Server<'_>) {
    let n = name::get();
    let _ = server.set(&server.wakeari.name, &Vec::from_slice(n.as_bytes()).unwrap_or_default());
}

/// 書き込みを処理する。不正なら Some(エラー) を返す。
async fn handle_write(server: &Server<'_>, w: &WriteEvent<'_, '_, DefaultPacketPool>) -> Option<AttErrorCode> {
    let handle = w.handle();
    if handle == server.wakeari.time.handle {
        let parsed = w.with_data(|_, d| TimeSync::parse(d));
        match parsed {
            Ok(t) => {
                let changed = clock::tz_offset_min() != t.tz_offset_min;
                clock::sync(t.epoch_s, t.tz_offset_min);
                esp_println::println!("time sync: epoch={} tz={}min", t.epoch_s, t.tz_offset_min);
                if changed {
                    storage::PERSIST.signal(());
                }
                STATUS_CHANGED.signal(());
                None
            }
            Err(e) => {
                esp_println::println!("time write rejected: {:?}", e);
                Some(ATT_ERR_INVALID)
            }
        }
    } else if handle == server.wakeari.command.handle {
        let parsed = w.with_data(|_, d| Command::parse(d));
        match parsed {
            Ok(Command::On) => {
                let _ = VALVE_CMD.try_send(ValveCmd::On(NO_ACTIVE_SLOT));
                None
            }
            Ok(Command::Off) => {
                let _ = VALVE_CMD.try_send(ValveCmd::Off);
                None
            }
            Ok(c) => {
                scheduler::apply(&c);
                None
            }
            Err(e) => {
                esp_println::println!("command rejected: {:?}", e);
                Some(ATT_ERR_INVALID)
            }
        }
    } else if handle == server.wakeari.config.handle {
        let parsed = w.with_data(|_, d| Config::parse(d));
        match parsed {
            Ok(c) => {
                let _ = config::set(c);
                esp_println::println!("config: duration={}s", c.duration_s);
                None
            }
            Err(e) => {
                esp_println::println!("config write rejected: {:?}", e);
                Some(ATT_ERR_INVALID)
            }
        }
    } else if handle == server.wakeari.name.handle {
        // 長さを問わず検証へ渡す。保存の完了を待ってから応答する（その後リセットされる）
        let prev = match w.with_data(|_, d| name::set(d)) {
            Ok(p) => p,
            Err(e) => {
                esp_println::println!("name write rejected: {:?}", e);
                return Some(ATT_ERR_INVALID);
            }
        };
        storage::NAME_SAVED.reset();
        storage::NAME_SAVE.signal(());
        let saved = embassy_time::with_timeout(Duration::from_secs(3), storage::NAME_SAVED.wait())
            .await
            .unwrap_or(false);
        if saved {
            esp_println::println!("name: changed to {}", name::get());
            None
        } else {
            esp_println::println!("name: save failed, reverted");
            name::revert(prev);
            Some(ATT_ERR_INVALID)
        }
    } else {
        None
    }
}

async fn gatt_events(
    server: &Server<'_>,
    conn: &GattConnection<'_, '_, DefaultPacketPool>,
) -> Result<(), Error> {
    loop {
        match conn.next().await {
            GattConnectionEvent::Disconnected { reason } => {
                esp_println::println!("ble: disconnected: {:?}", reason);
                return Ok(());
            }
            GattConnectionEvent::Gatt { event } => {
                let reject = match &event {
                    GattEvent::Write(w) => handle_write(server, w).await,
                    GattEvent::Read(_) => {
                        // 読み出し直前に最新値へ更新する
                        refresh_status(server);
                        refresh_schedules(server);
                        refresh_config(server);
                        refresh_name(server);
                        None
                    }
                    _ => None,
                };
                let reply = match reject {
                    Some(code) => event.reject(code)?,
                    None => event.accept()?,
                };
                reply.send().await;
            }
            _ => {}
        }
    }
}

/// Status / Schedules / Config の Notify。
/// Status は変化時と、ON 中は 1 秒ごと。Schedules と Config は変化時。
async fn notifier(server: &Server<'_>, conn: &GattConnection<'_, '_, DefaultPacketPool>) {
    refresh_status(server);
    refresh_schedules(server);
    refresh_config(server);
    loop {
        let ev = select4(
            STATUS_CHANGED.wait(),
            SCHEDULE_CHANGED.wait(),
            CONFIG_CHANGED.wait(),
            Timer::after(Duration::from_secs(1)),
        )
        .await;
        let notify_status = match ev {
            Either4::First(()) => true,
            Either4::Second(()) => {
                let v = schedules_value();
                if server.wakeari.schedules.notify(conn, &v, true).await.is_err() {
                    esp_println::println!("ble: schedules notify failed");
                    return;
                }
                false
            }
            Either4::Third(()) => {
                let v = config::get().encode();
                if server.wakeari.config.notify(conn, &v, true).await.is_err() {
                    esp_println::println!("ble: config notify failed");
                    return;
                }
                false
            }
            Either4::Fourth(()) => valve::state().on,
        };
        if notify_status {
            let v = current_status().encode();
            if server.wakeari.status.notify(conn, &v, true).await.is_err() {
                esp_println::println!("ble: status notify failed");
                return;
            }
        }
    }
}

async fn advertise<'a, 'b>(
    peripheral: &mut Peripheral<'a, BleController, DefaultPacketPool>,
    server: &'b Server<'_>,
) -> Result<GattConnection<'a, 'b, DefaultPacketPool>, &'static str> {
    // アドバタイズデータは Flags + 128-bit Service UUID のみ。名前はスキャン応答へ載せる。
    let mut data = [0u8; 31];
    let len = AdStructure::encode_slice(
        &[
            AdStructure::Flags(LE_GENERAL_DISCOVERABLE | BR_EDR_NOT_SUPPORTED),
            AdStructure::CompleteServiceUuids128(&[SERVICE_UUID_U128.to_le_bytes()]),
        ],
        &mut data[..],
    )
    .map_err(|_| "adv data")?;
    let device_name = name::get();
    let mut scan = [0u8; 31];
    let scan_len = AdStructure::encode_slice(
        &[AdStructure::CompleteLocalName(device_name.as_bytes())],
        &mut scan[..],
    )
    .map_err(|_| "scan data")?;
    let advertiser = peripheral
        .advertise(
            &Default::default(),
            Advertisement::ConnectableScannableUndirected {
                adv_data: &data[..len],
                scan_data: &scan[..scan_len],
            },
        )
        .await
        .map_err(|e| {
            esp_println::println!("ble: advertise failed: {:?}", e);
            "advertise"
        })?;
    esp_println::println!("ble: advertising as {}", device_name);
    let conn = advertiser
        .accept()
        .await
        .map_err(|_| "accept")?
        .with_attribute_server(server)
        .map_err(|_| "attribute server")?;
    esp_println::println!("ble: connected");
    Ok(conn)
}

/// BLE ホストを走らせる（戻らない）。切断されたら再アドバタイズする。
pub async fn run(controller: BleController) -> ! {
    static RESOURCES: StaticCell<
        HostResources<BleController, DefaultPacketPool, CONNECTIONS_MAX, L2CAP_CHANNELS_MAX>,
    > = StaticCell::new();
    let resources = RESOURCES.init(HostResources::new());

    let mut mac = [0u8; 6];
    mac.copy_from_slice(esp_hal::efuse::base_mac_address().as_bytes());
    // iOS はアドレスごとに GATT 構成をキャッシュする。Service Changed を送らないので、
    // 構成を変えたら GATT_DB_VERSION を上げてアドレスを変え、古いキャッシュを使わせない。
    mac[0] ^= GATT_DB_VERSION;
    mac[5] |= 0xC0; // static random address
    let stack = trouble_host::new(controller, resources).set_random_address(Address::random(mac));
    let stack = stack.build();
    let mut peripheral = stack.peripheral();
    let mut runner = stack.runner();

    // GAP Device Name。trouble-host は内部の 22 bytes 固定バッファへコピーするため、
    // それを超える名前は UTF-8 の文字境界で切り詰めて渡す。
    let device_name = name::get();
    let mut gap_name: &str = device_name.as_str();
    while gap_name.len() > GAP_NAME_MAX_LEN {
        let mut end = gap_name.len() - 1;
        while !gap_name.is_char_boundary(end) {
            end -= 1;
        }
        gap_name = &gap_name[..end];
    }
    let server = Server::new_with_config(GapConfig::default(gap_name)).unwrap();
    refresh_name(&server);

    let _ = join(
        async {
            loop {
                if let Err(e) = runner.run().await {
                    esp_println::println!("ble: runner error: {:?}", e);
                }
            }
        },
        async {
            loop {
                match advertise(&mut peripheral, &server).await {
                    Ok(conn) => {
                        let r = select(gatt_events(&server, &conn), notifier(&server, &conn)).await;
                        if let embassy_futures::select::Either::First(Err(e)) = r {
                            esp_println::println!("ble: gatt error: {:?}", e);
                        }
                    }
                    Err(e) => {
                        esp_println::println!("ble: advertise error: {:?}", e);
                        Timer::after(Duration::from_secs(1)).await;
                    }
                }
            }
        },
    )
    .await;
    unreachable!()
}
