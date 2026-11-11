//! デバイス名（Name characteristic）。起動時にフラッシュから復元し、GAP / スキャン応答に使う。

use core::cell::RefCell;
use critical_section::Mutex;
use heapless::String;
use wakeari_protocol::{DEFAULT_NAME, NAME_MAX_LEN, Error, validate_name};

static NAME: Mutex<RefCell<Option<String<NAME_MAX_LEN>>>> = Mutex::new(RefCell::new(None));

fn to_string(s: &str) -> String<NAME_MAX_LEN> {
    let mut out = String::new();
    // validate_name 済み（29 bytes 以下）なので必ず収まる
    let _ = out.push_str(s);
    out
}

/// 現在の名前。未設定なら初期値。
pub fn get() -> String<NAME_MAX_LEN> {
    critical_section::with(|cs| {
        NAME.borrow_ref(cs).clone().unwrap_or_else(|| to_string(DEFAULT_NAME))
    })
}

/// 起動時の復元用。不正なら無視（初期値のまま）。
pub fn restore(b: &[u8]) {
    if let Ok(s) = validate_name(b) {
        critical_section::with(|cs| *NAME.borrow_ref_mut(cs) = Some(to_string(s)));
    }
}

/// 検証して反映する（保存は呼び出し側）。以前の値を返す。
pub fn set(b: &[u8]) -> Result<String<NAME_MAX_LEN>, Error> {
    let s = validate_name(b)?;
    let prev = get();
    critical_section::with(|cs| *NAME.borrow_ref_mut(cs) = Some(to_string(s)));
    Ok(prev)
}

/// 以前の値に戻す（保存失敗時）。
pub fn revert(prev: String<NAME_MAX_LEN>) {
    critical_section::with(|cs| *NAME.borrow_ref_mut(cs) = Some(prev));
}
