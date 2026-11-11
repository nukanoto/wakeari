//! 1 秒ごとにスケジュールを評価し、該当スロットでバルブを ON にする。

use core::cell::RefCell;
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::{Duration, Ticker};
use wakeari_protocol::{Command, Schedule};

use crate::{clock, storage, valve};

pub static SCHEDULE: Mutex<CriticalSectionRawMutex, RefCell<Schedule>> =
    Mutex::new(RefCell::new(Schedule::new()));
/// スロットが変わったことを BLE タスクへ知らせる。
pub static SCHEDULE_CHANGED: Signal<CriticalSectionRawMutex, ()> = Signal::new();

pub fn snapshot() -> Schedule {
    SCHEDULE.lock(|s| *s.borrow())
}

pub fn restore(s: Schedule) {
    SCHEDULE.lock(|c| *c.borrow_mut() = s);
}

/// PUT / DELETE / CLEAR を適用して保存・通知する。
pub fn apply(cmd: &Command) {
    SCHEDULE.lock(|s| s.borrow_mut().apply(cmd));
    SCHEDULE_CHANGED.signal(());
    storage::PERSIST.signal(());
}

#[embassy_executor::task]
pub async fn scheduler_task() {
    let mut ticker = Ticker::every(Duration::from_secs(1));
    loop {
        ticker.next().await;
        // 未同期の間はスケジュールを実行しない
        let Some(t) = clock::local_time() else { continue };
        let fired = SCHEDULE.lock(|s| s.borrow_mut().tick(t));
        if fired.count == 0 {
            continue;
        }
        for id in fired.iter() {
            esp_println::println!("schedule: slot {} fired", id);
        }
        // 同じ分に複数発火したら id が最小のものを active_slot にする
        let active = fired.min_id().unwrap_or(wakeari_protocol::NO_ACTIVE_SLOT);
        valve::VALVE_CMD.send(valve::ValveCmd::On(active)).await;
        if fired.one_shot_disabled {
            SCHEDULE_CHANGED.signal(());
            storage::PERSIST.signal(());
        }
    }
}
