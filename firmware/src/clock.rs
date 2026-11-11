//! 壁時計。電源が切れると失われるため、Time の書き込みで同期するまでは未同期扱い。
//! tz だけは永続化され、起動時に復元される。

use core::cell::Cell;
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_time::Instant;
use wakeari_protocol::LocalTime;

#[derive(Clone, Copy)]
struct State {
    /// epoch_ms - Instant::now().as_millis()。未同期なら None
    offset_ms: Option<i64>,
    tz_offset_min: i16,
}

static CLOCK: Mutex<CriticalSectionRawMutex, Cell<State>> = Mutex::new(Cell::new(State {
    offset_ms: None,
    tz_offset_min: 0,
}));

fn uptime_ms() -> i64 {
    Instant::now().as_millis() as i64
}

/// Time characteristic の書き込みを反映する。
pub fn sync(epoch_s: i64, tz_offset_min: i16) {
    CLOCK.lock(|c| {
        c.set(State {
            offset_ms: Some(epoch_s * 1000 - uptime_ms()),
            tz_offset_min,
        })
    });
}

/// 起動時に永続化された tz を復元する（時刻は未同期のまま）。
pub fn restore_tz(tz_offset_min: i16) {
    CLOCK.lock(|c| {
        let mut s = c.get();
        s.tz_offset_min = tz_offset_min;
        c.set(s);
    });
}

pub fn tz_offset_min() -> i16 {
    CLOCK.lock(|c| c.get().tz_offset_min)
}

/// 現在の UNIX 時刻（秒, UTC）。未同期なら None。
pub fn now_epoch() -> Option<i64> {
    let s = CLOCK.lock(|c| c.get());
    s.offset_ms.map(|o| (o + uptime_ms()).div_euclid(1000))
}

/// 現在のローカル時刻。未同期なら None。
pub fn local_time() -> Option<LocalTime> {
    let s = CLOCK.lock(|c| c.get());
    let epoch = s.offset_ms.map(|o| (o + uptime_ms()).div_euclid(1000))?;
    Some(LocalTime::from_epoch(epoch, s.tz_offset_min))
}
