//! GPIO2 のバルブ制御タスク。起動時は Low（OFF）。

use core::cell::Cell;
use embassy_futures::select::{Either, select};
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::channel::Channel;
use embassy_sync::signal::Signal;
use embassy_time::{Instant, Timer};
use esp_hal::gpio::Output;
use wakeari_protocol::{MAX_DURATION_S, NO_ACTIVE_SLOT};

use crate::config;

#[derive(Clone, Copy, Debug)]
pub enum ValveCmd {
    /// ON にする。長さは Config の duration_s。引数は予約 id（手動は NO_ACTIVE_SLOT）
    On(u8),
    Off,
}

#[derive(Clone, Copy)]
pub struct ValveState {
    pub on: bool,
    pub off_at: Option<Instant>,
    /// 予約で ON 中ならその id、手動 ON / OFF なら NO_ACTIVE_SLOT
    pub active_slot: u8,
}

pub static VALVE_CMD: Channel<CriticalSectionRawMutex, ValveCmd, 4> = Channel::new();
/// バルブ状態が変わったことを BLE タスクへ知らせる。
pub static STATUS_CHANGED: Signal<CriticalSectionRawMutex, ()> = Signal::new();

static STATE: Mutex<CriticalSectionRawMutex, Cell<ValveState>> =
    Mutex::new(Cell::new(ValveState { on: false, off_at: None, active_slot: NO_ACTIVE_SLOT }));

pub fn state() -> ValveState {
    STATE.lock(|c| c.get())
}

/// 残り秒数（OFF のとき 0）。切り上げ。
pub fn remaining_s() -> u16 {
    let s = state();
    match (s.on, s.off_at) {
        (true, Some(t)) => {
            let ms = t.saturating_duration_since(Instant::now()).as_millis();
            ms.div_ceil(1000).min(MAX_DURATION_S as u64) as u16
        }
        _ => 0,
    }
}

fn publish(on: bool, off_at: Option<Instant>, active_slot: u8) {
    STATE.lock(|c| c.set(ValveState { on, off_at, active_slot }));
    STATUS_CHANGED.signal(());
}

#[embassy_executor::task]
pub async fn valve_task(mut pin: Output<'static>) {
    pin.set_low();
    publish(false, None, NO_ACTIVE_SLOT);
    let mut off_at: Option<Instant> = None;
    loop {
        let ev = match off_at {
            Some(t) => select(VALVE_CMD.receive(), Timer::at(t)).await,
            None => Either::First(VALVE_CMD.receive().await),
        };
        match ev {
            Either::First(ValveCmd::On(slot)) => {
                let d = config::duration_s().clamp(1, MAX_DURATION_S);
                let t = Instant::now() + embassy_time::Duration::from_secs(d as u64);
                off_at = Some(t);
                pin.set_high();
                publish(true, off_at, slot);
                esp_println::println!("valve: ON for {}s (slot {})", d, slot);
            }
            Either::First(ValveCmd::Off) | Either::Second(()) => {
                off_at = None;
                pin.set_low();
                publish(false, None, NO_ACTIVE_SLOT);
                esp_println::println!("valve: OFF");
            }
        }
    }
}
