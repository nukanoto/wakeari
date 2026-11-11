//! `nvs` データパーティションに tz とスケジュールを保存する（sequential-storage の map）。

use embassy_futures::select::{Either, select};
use embassy_embedded_hal::adapter::BlockingAsync;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::{Duration, Timer};
use esp_bootloader_esp_idf::partitions::{
    DataPartitionSubType, PARTITION_TABLE_MAX_LEN, PartitionType, read_partition_table,
};
use esp_storage::FlashStorage;
use heapless::String;
use sequential_storage::cache::Cache;
use sequential_storage::map::{MapConfig, MapStorage};
use wakeari_protocol::{Config, MAX_SLOTS, NAME_MAX_LEN, SCHEDULES_MAX_LEN, Schedule, Slot, decode_schedules};

use crate::{clock, config, name, scheduler};

/// 保存が必要になったら signal する。
pub static PERSIST: Signal<CriticalSectionRawMutex, ()> = Signal::new();
/// 名前の変更。デバウンスせずに保存し、完了後に `NAME_SAVED` へ結果を返す。
pub static NAME_SAVE: Signal<CriticalSectionRawMutex, ()> = Signal::new();
/// `NAME_SAVE` の結果（true なら保存済み。この後ソフトウェアリセットする）
pub static NAME_SAVED: Signal<CriticalSectionRawMutex, bool> = Signal::new();
/// 名前の保存からソフトウェアリセットまでの猶予（ATT 応答を送るため）
const RESET_DELAY_MS: u64 = 500;

const KEY_TZ: u8 = 0;
const KEY_SCHEDULES: u8 = 1;
const KEY_CONFIG: u8 = 2;
const KEY_NAME: u8 = 3;
/// 使用するのは先頭の 4 ページ（16 KiB）まで
const MAX_REGION_BYTES: usize = 4 * 4096;

pub struct Storage {
    flash: FlashStorage<'static>,
}

/// `nvs` パーティション上の map を開く。
macro_rules! open_map {
    ($flash:expr, $map:ident) => {
        let mut pt_buf = [0u8; PARTITION_TABLE_MAX_LEN];
        let pt = read_partition_table(&mut $flash, &mut pt_buf).map_err(|_| "partition table")?;
        let entry = pt
            .find_partition(PartitionType::Data(DataPartitionSubType::Nvs))
            .map_err(|_| "partition table")?
            .ok_or("nvs partition not found")?;
        let mut region = entry.as_flash_region(&mut $flash);
        let len = region.partition_size().min(MAX_REGION_BYTES) as u32;
        let nor = region.as_nor_flash().map_err(|_| "nvs region")?;
        let mut $map = MapStorage::<u8, _, _>::new(
            BlockingAsync::new(nor),
            MapConfig::new(0..len),
            Cache::new_uncached(),
        );
    };
}

impl Storage {
    pub fn new(flash: FlashStorage<'static>) -> Self {
        Storage { flash }
    }

    /// 保存済みの (tz, schedule, config) を読む。何も無ければ None / 空。
    pub async fn load(
        &mut self,
    ) -> Result<(Option<i16>, Schedule, Option<Config>, Option<String<NAME_MAX_LEN>>), &'static str> {
        open_map!(self.flash, map);
        let mut buf = [0u8; 128];

        let tz = {
            let v = map
                .fetch_item::<&[u8]>(&mut buf, &KEY_TZ)
                .await
                .map_err(|_| "fetch tz")?;
            v.and_then(|b| <[u8; 2]>::try_from(b).ok()).map(i16::from_le_bytes)
        };

        let mut sched = Schedule::new();
        let v = map
            .fetch_item::<&[u8]>(&mut buf, &KEY_SCHEDULES)
            .await
            .map_err(|_| "fetch schedules")?;
        if let Some(b) = v {
            let mut slots = [Slot {
                id: 0,
                enabled: false,
                weekday_mask: 0,
                hour: 0,
                minute: 0,
            }; MAX_SLOTS];
            match decode_schedules(b, &mut slots) {
                Ok(n) => {
                    for s in &slots[..n] {
                        let _ = sched.put(*s);
                    }
                }
                Err(e) => esp_println::println!(
                    "storage: stored schedules do not decode ({:?}, old v1 format?), starting empty",
                    e
                ),
            }
        }

        let v = map
            .fetch_item::<&[u8]>(&mut buf, &KEY_CONFIG)
            .await
            .map_err(|_| "fetch config")?;
        let cfg = match v {
            Some(b) => match Config::parse(b) {
                Ok(c) => Some(c),
                Err(e) => {
                    esp_println::println!("storage: stored config invalid ({:?}), using default", e);
                    None
                }
            },
            None => None,
        };

        let name = match map
            .fetch_item::<&[u8]>(&mut buf, &KEY_NAME)
            .await
            .map_err(|_| "fetch name")?
        {
            Some(b) => match wakeari_protocol::validate_name(b) {
                Ok(s) => {
                    let mut out = String::new();
                    let _ = out.push_str(s);
                    Some(out)
                }
                Err(e) => {
                    esp_println::println!("storage: stored name invalid ({:?}), using default", e);
                    None
                }
            },
            None => None,
        };
        Ok((tz, sched, cfg, name))
    }

    pub async fn save(
        &mut self,
        tz: i16,
        sched: &Schedule,
        cfg: Config,
    ) -> Result<(), &'static str> {
        open_map!(self.flash, map);
        let mut buf = [0u8; 128];
        let tz_bytes = tz.to_le_bytes();
        map.store_item::<&[u8]>(&mut buf, &KEY_TZ, &&tz_bytes[..])
            .await
            .map_err(|_| "store tz")?;
        let mut enc = [0u8; SCHEDULES_MAX_LEN];
        let n = sched.encode(&mut enc);
        map.store_item::<&[u8]>(&mut buf, &KEY_SCHEDULES, &&enc[..n])
            .await
            .map_err(|_| "store schedules")?;
        let cfg_bytes = cfg.encode();
        map.store_item::<&[u8]>(&mut buf, &KEY_CONFIG, &&cfg_bytes[..])
            .await
            .map_err(|_| "store config")?;
        let nm = name::get();
        map.store_item::<&[u8]>(&mut buf, &KEY_NAME, &nm.as_bytes())
            .await
            .map_err(|_| "store name")?;
        Ok(())
    }
}

/// PERSIST / NAME_SAVE を待って保存するタスク。
/// 名前の変更はデバウンスせずに保存し、完了後に 500ms 待ってソフトウェアリセットする。
#[embassy_executor::task]
pub async fn storage_task(mut storage: Storage) {
    loop {
        let rename = match select(PERSIST.wait(), NAME_SAVE.wait()).await {
            Either::First(()) => {
                // 連続する更新をまとめる
                Timer::after(Duration::from_millis(300)).await;
                PERSIST.reset();
                false
            }
            Either::Second(()) => {
                PERSIST.reset();
                true
            }
        };
        let tz = clock::tz_offset_min();
        let sched = scheduler::snapshot();
        let res = storage.save(tz, &sched, config::get()).await;
        match &res {
            Ok(()) => esp_println::println!("storage: saved"),
            Err(e) => esp_println::println!("storage: save failed: {}", e),
        }
        if rename {
            NAME_SAVED.signal(res.is_ok());
            if res.is_ok() {
                Timer::after(Duration::from_millis(RESET_DELAY_MS)).await;
                esp_println::println!("storage: name changed, resetting");
                esp_hal::system::software_reset();
            }
        }
    }
}
