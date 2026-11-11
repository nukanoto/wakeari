//! 全予約・手動 ON で共通の ON の長さ（Config characteristic）。

use core::sync::atomic::{AtomicU16, Ordering};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use wakeari_protocol::{Config, DEFAULT_DURATION_S, Error};

static DURATION_S: AtomicU16 = AtomicU16::new(DEFAULT_DURATION_S);
/// Config が変わったことを BLE タスクへ知らせる。
pub static CONFIG_CHANGED: Signal<CriticalSectionRawMutex, ()> = Signal::new();

pub fn get() -> Config {
    Config { duration_s: DURATION_S.load(Ordering::Relaxed) }
}

pub fn duration_s() -> u16 {
    get().duration_s
}

/// 起動時の復元用（通知・保存はしない）。範囲外なら無視する。
pub fn restore(c: Config) {
    if c.validate().is_ok() {
        DURATION_S.store(c.duration_s, Ordering::Relaxed);
    }
}

/// 検証して反映し、保存・通知する。
pub fn set(c: Config) -> Result<(), Error> {
    c.validate()?;
    DURATION_S.store(c.duration_s, Ordering::Relaxed);
    CONFIG_CHANGED.signal(());
    crate::storage::PERSIST.signal(());
    Ok(())
}
