//! 表示用の整形と `--json` の出力。

use chrono::NaiveDateTime;
use serde::Serialize;
use wakeari_protocol::Slot;

use crate::schedule::repeat_label;

pub fn format_time(hour: u8, minute: u8) -> String {
    format!("{:02}:{:02}", hour, minute)
}

pub fn format_seconds(s: u16) -> String {
    format!("{s}秒")
}

/// "UTC+9" / "UTC+5:30" / "UTC-3"
pub fn format_utc_offset(minutes: i32) -> String {
    let sign = if minutes < 0 { '-' } else { '+' };
    let abs = minutes.abs();
    let (h, m) = (abs / 60, abs % 60);
    if m == 0 {
        format!("UTC{sign}{h}")
    } else {
        format!("UTC{sign}{h}:{m:02}")
    }
}

pub fn format_datetime(t: NaiveDateTime) -> String {
    t.format("%Y-%m-%d %H:%M:%S").to_string()
}

pub fn enabled_label(enabled: bool) -> &'static str {
    if enabled { "有効" } else { "無効" }
}

/// 端末上の表示幅（全角を 2 として数える）。
fn width(s: &str) -> usize {
    s.chars().map(|c| if c.is_ascii() { 1 } else { 2 }).sum()
}

fn pad(s: &str, w: usize) -> String {
    format!("{s}{}", " ".repeat(w.saturating_sub(width(s))))
}

/// 列を揃えた表。
pub fn table(header: &[&str], rows: &[Vec<String>]) -> String {
    let mut widths: Vec<usize> = header.iter().map(|h| width(h)).collect();
    for r in rows {
        for (i, c) in r.iter().enumerate() {
            widths[i] = widths[i].max(width(c));
        }
    }
    let line = |cells: Vec<&str>| {
        cells
            .iter()
            .enumerate()
            .map(|(i, c)| pad(c, widths[i]))
            .collect::<Vec<_>>()
            .join("  ")
            .trim_end()
            .to_string()
    };
    let mut out = vec![line(header.to_vec())];
    for r in rows {
        out.push(line(r.iter().map(String::as_str).collect()));
    }
    out.join("\n")
}

pub fn print_json<T: Serialize>(v: &T) {
    println!(
        "{}",
        serde_json::to_string_pretty(v).expect("JSON に変換できる")
    );
}

#[derive(Serialize, Debug, PartialEq)]
pub struct AlarmJson {
    pub id: u8,
    pub time: String,
    pub weekday_mask: u8,
    pub repeat: String,
    pub enabled: bool,
}

pub fn alarm_json(s: &Slot) -> AlarmJson {
    AlarmJson {
        id: s.id,
        time: format_time(s.hour, s.minute),
        weekday_mask: s.weekday_mask,
        repeat: repeat_label(s.weekday_mask),
        enabled: s.enabled,
    }
}

#[derive(Serialize, Debug, PartialEq)]
pub struct DeviceJson {
    pub name: Option<String>,
    pub id: String,
    pub rssi: Option<i16>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct NextJson {
    pub id: u8,
    pub at: String,
    pub until: String,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct StatusJson {
    pub device: DeviceJson,
    pub device_name: String,
    pub time_synced: bool,
    /// ローカル時刻（RFC 3339 風、タイムゾーンなし）。未同期なら null。
    pub device_time: Option<String>,
    pub valve_on: bool,
    pub remaining_s: u16,
    pub active_slot: Option<u8>,
    pub duration_s: u16,
    pub next_alarm: Option<NextJson>,
}

/// 表の 1 行。
pub fn alarm_row(s: &Slot) -> Vec<String> {
    vec![
        s.id.to_string(),
        format_time(s.hour, s.minute),
        repeat_label(s.weekday_mask),
        enabled_label(s.enabled).to_string(),
    ]
}

pub fn alarm_table(slots: &[Slot]) -> String {
    let rows: Vec<Vec<String>> = slots.iter().map(alarm_row).collect();
    table(&["ID", "時刻", "繰り返し", "状態"], &rows)
}

/// 1 件のアラームの要約。
pub fn alarm_summary(s: &Slot) -> String {
    format!(
        "ID {}: {} {}（{}）",
        s.id,
        format_time(s.hour, s.minute),
        repeat_label(s.weekday_mask),
        enabled_label(s.enabled)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slot(id: u8, mask: u8, h: u8, m: u8, enabled: bool) -> Slot {
        Slot {
            id,
            enabled,
            weekday_mask: mask,
            hour: h,
            minute: m,
        }
    }

    #[test]
    fn offsets() {
        assert_eq!(format_utc_offset(540), "UTC+9");
        assert_eq!(format_utc_offset(330), "UTC+5:30");
        assert_eq!(format_utc_offset(-180), "UTC-3");
        assert_eq!(format_utc_offset(0), "UTC+0");
    }

    #[test]
    fn alarm_json_shape() {
        let v = serde_json::to_value(alarm_json(&slot(2, 0x1F, 7, 5, true))).unwrap();
        assert_eq!(
            v,
            serde_json::json!({
                "id": 2, "time": "07:05", "weekday_mask": 31, "repeat": "平日", "enabled": true
            })
        );
    }

    #[test]
    fn status_json_shape() {
        let s = StatusJson {
            device: DeviceJson {
                name: Some("wakeari".into()),
                id: "abc".into(),
                rssi: Some(-60),
            },
            device_name: "wakeari".into(),
            time_synced: true,
            device_time: Some("2026-11-12T07:00:00".into()),
            valve_on: false,
            remaining_s: 0,
            active_slot: None,
            duration_s: 30,
            next_alarm: Some(NextJson {
                id: 1,
                at: "2026-11-13T07:00".into(),
                until: "あと 24時間".into(),
            }),
        };
        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["active_slot"], serde_json::Value::Null);
        assert_eq!(v["device"]["rssi"], -60);
        assert_eq!(v["next_alarm"]["id"], 1);
        assert_eq!(v["duration_s"], 30);
    }

    #[test]
    fn table_aligns_wide_chars() {
        let t = alarm_table(&[slot(0, 0x1F, 7, 0, true), slot(1, 0, 22, 30, false)]);
        let lines: Vec<&str> = t.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("ID"));
        assert!(lines[1].contains("平日"));
        assert!(lines[2].contains("1回のみ"));
        assert!(lines[2].ends_with("無効"));
    }
}
