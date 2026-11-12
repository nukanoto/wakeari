//! アラーム（スロット）に関する純粋なロジック。曜日指定の解釈、表示用ラベル、次回実行の計算。

use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime};
use wakeari_protocol::{MAX_SLOTS, Slot};

pub const WEEKDAYS: u8 = 0x1F;
pub const WEEKEND: u8 = 0x60;
pub const EVERYDAY: u8 = 0x7F;

const DAY_LABELS: [&str; 7] = ["月", "火", "水", "木", "金", "土", "日"];

/// 曜日マスクの表示。0 は「1回のみ」。
pub fn repeat_label(mask: u8) -> String {
    match mask {
        0 => "1回のみ".into(),
        EVERYDAY => "毎日".into(),
        WEEKDAYS => "平日".into(),
        WEEKEND => "土日".into(),
        _ => (0..7)
            .filter(|i| (mask >> i) & 1 == 1)
            .map(|i| DAY_LABELS[i])
            .collect::<Vec<_>>()
            .join("・"),
    }
}

pub fn weekday_label(index_from_monday: u32) -> &'static str {
    DAY_LABELS[index_from_monday as usize % 7]
}

/// 曜日指定の解釈に失敗したときの内容。
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ParseError {
    #[error(
        "曜日の指定が正しくありません: '{0}'（例: 平日, 土日, 毎日, 月,水,金, weekdays, mon,wed,fri）"
    )]
    Days(String),
    #[error("時刻の指定が正しくありません: '{0}'（HH:MM 形式で 0:00〜23:59）")]
    Time(String),
}

fn day_bit(token: &str) -> Option<u8> {
    let t = token.trim().to_lowercase();
    let idx = match t.as_str() {
        "mon" | "monday" | "月" | "月曜" | "月曜日" => 0,
        "tue" | "tues" | "tuesday" | "火" | "火曜" | "火曜日" => 1,
        "wed" | "wednesday" | "水" | "水曜" | "水曜日" => 2,
        "thu" | "thur" | "thurs" | "thursday" | "木" | "木曜" | "木曜日" => 3,
        "fri" | "friday" | "金" | "金曜" | "金曜日" => 4,
        "sat" | "saturday" | "土" | "土曜" | "土曜日" => 5,
        "sun" | "sunday" | "日" | "日曜" | "日曜日" => 6,
        _ => return None,
    };
    Some(1 << idx)
}

/// 曜日指定を weekday_mask にする。`once` / `1回のみ` / `単発` は 0。
pub fn parse_days(spec: &str) -> Result<u8, ParseError> {
    let err = || ParseError::Days(spec.to_string());
    let s = spec.trim().to_lowercase();
    match s.as_str() {
        "weekdays" | "weekday" | "平日" => return Ok(WEEKDAYS),
        "weekends" | "weekend" | "土日" => return Ok(WEEKEND),
        "daily" | "everyday" | "every-day" | "毎日" => return Ok(EVERYDAY),
        "once" | "oneshot" | "one-shot" | "単発" | "1回のみ" | "1回" => return Ok(0),
        _ => {}
    }
    let mut mask = 0u8;
    let mut any = false;
    for tok in s.split([',', '、', '・', '，', ' ']) {
        if tok.trim().is_empty() {
            continue;
        }
        mask |= day_bit(tok).ok_or_else(err)?;
        any = true;
    }
    if !any {
        return Err(err());
    }
    Ok(mask)
}

/// "HH:MM"（H:MM、全角コロンも可）を (hour, minute) にする。
pub fn parse_time(spec: &str) -> Result<(u8, u8), ParseError> {
    let err = || ParseError::Time(spec.to_string());
    let s = spec.trim().replace('：', ":");
    let (h, m) = s.split_once(':').ok_or_else(err)?;
    if h.is_empty() || h.len() > 2 || m.len() != 2 {
        return Err(err());
    }
    let h: u8 = h.parse().map_err(|_| err())?;
    let m: u8 = m.parse().map_err(|_| err())?;
    if h > 23 || m > 59 {
        return Err(err());
    }
    Ok((h, m))
}

/// 使われていない最小の id。満杯なら None。
pub fn smallest_free_id(slots: &[Slot]) -> Option<u8> {
    (0..MAX_SLOTS as u8).find(|id| !slots.iter().any(|s| s.id == *id))
}

pub fn is_one_shot(slot: &Slot) -> bool {
    slot.weekday_mask == 0
}

fn repeats_on(slot: &Slot, date: NaiveDate) -> bool {
    (slot.weekday_mask >> date.weekday().num_days_from_monday()) & 1 == 1
}

/// 次の実行予定。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NextRun {
    pub slot: Slot,
    pub at: NaiveDateTime,
}

fn next_occurrence(slot: &Slot, now: NaiveDateTime) -> Option<NaiveDateTime> {
    // 今日の時刻が過ぎている場合に備えて 8 日分調べる。
    for offset in 0..=7 {
        let day = now.date() + Duration::days(offset);
        if !is_one_shot(slot) && !repeats_on(slot, day) {
            continue;
        }
        let at = day.and_hms_opt(slot.hour as u32, slot.minute as u32, 0)?;
        if at >= now {
            return Some(at);
        }
    }
    None
}

/// `now` 以降で最も早い、有効なアラームの実行を返す。同時刻なら id が小さい方。
pub fn next_run(slots: &[Slot], now: NaiveDateTime) -> Option<NextRun> {
    let mut best: Option<NextRun> = None;
    for slot in slots.iter().filter(|s| s.enabled) {
        let Some(at) = next_occurrence(slot, now) else {
            continue;
        };
        let better = match &best {
            None => true,
            Some(b) => at < b.at || (at == b.at && slot.id < b.slot.id),
        };
        if better {
            best = Some(NextRun { slot: *slot, at });
        }
    }
    best
}

/// "あと 6時間12分" 形式（1 時間未満は分だけ、1 日以上は日と時間）。
pub fn until_label(at: NaiveDateTime, now: NaiveDateTime) -> String {
    let seconds = (at - now).num_seconds();
    let minutes = if seconds <= 0 { 0 } else { (seconds + 59) / 60 };
    if minutes < 1 {
        return "まもなく".into();
    }
    let d = minutes / 1440;
    let h = (minutes % 1440) / 60;
    let m = minutes % 60;
    if d > 0 {
        format!("あと {d}日{h}時間")
    } else if h > 0 {
        if m == 0 {
            format!("あと {h}時間")
        } else {
            format!("あと {h}時間{m}分")
        }
    } else {
        format!("あと {m}分")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MON: u8 = 1;
    const WED: u8 = 4;
    const FRI: u8 = 16;
    const SAT: u8 = 32;
    const SUN: u8 = 64;

    fn slot(id: u8, mask: u8, h: u8, m: u8, enabled: bool) -> Slot {
        Slot {
            id,
            enabled,
            weekday_mask: mask,
            hour: h,
            minute: m,
        }
    }
    fn dt(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(y, mo, d)
            .unwrap()
            .and_hms_opt(h, mi, s)
            .unwrap()
    }

    #[test]
    fn days_english_and_japanese() {
        assert_eq!(parse_days("weekdays"), Ok(WEEKDAYS));
        assert_eq!(parse_days("平日"), Ok(WEEKDAYS));
        assert_eq!(parse_days("Weekends"), Ok(WEEKEND));
        assert_eq!(parse_days("土日"), Ok(WEEKEND));
        assert_eq!(parse_days("daily"), Ok(EVERYDAY));
        assert_eq!(parse_days("毎日"), Ok(EVERYDAY));
        assert_eq!(parse_days("mon,wed,fri"), Ok(MON | WED | FRI));
        assert_eq!(parse_days("月,水,金"), Ok(MON | WED | FRI));
        assert_eq!(parse_days("月・水・金"), Ok(MON | WED | FRI));
        assert_eq!(parse_days(" Sat , sun "), Ok(SAT | SUN));
        assert_eq!(parse_days("土曜,日曜日"), Ok(SAT | SUN));
        assert_eq!(parse_days("once"), Ok(0));
        assert_eq!(parse_days("単発"), Ok(0));
    }

    #[test]
    fn days_invalid() {
        assert!(parse_days("").is_err());
        assert!(parse_days(",").is_err());
        assert!(parse_days("mon,foo").is_err());
        assert!(parse_days("週末").is_err());
    }

    #[test]
    fn repeat_labels() {
        assert_eq!(repeat_label(0), "1回のみ");
        assert_eq!(repeat_label(0x7F), "毎日");
        assert_eq!(repeat_label(0x1F), "平日");
        assert_eq!(repeat_label(0x60), "土日");
        assert_eq!(repeat_label(MON | WED | FRI), "月・水・金");
        assert_eq!(repeat_label(SUN), "日");
    }

    #[test]
    fn time_parse() {
        assert_eq!(parse_time("07:05"), Ok((7, 5)));
        assert_eq!(parse_time("7:05"), Ok((7, 5)));
        assert_eq!(parse_time("23:59"), Ok((23, 59)));
        assert_eq!(parse_time("0:00"), Ok((0, 0)));
        assert_eq!(parse_time("7：30"), Ok((7, 30)));
        for bad in [
            "24:00", "12:60", "7", "7:5", "abc", "", "12:34:56", "-1:00", ":30",
        ] {
            assert!(parse_time(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn free_id() {
        assert_eq!(smallest_free_id(&[]), Some(0));
        let s = |id| slot(id, 0, 1, 1, true);
        assert_eq!(smallest_free_id(&[s(0), s(1), s(3)]), Some(2));
        assert_eq!(smallest_free_id(&[s(1)]), Some(0));
        let full: Vec<Slot> = (0..8).map(s).collect();
        assert_eq!(smallest_free_id(&full), None);
    }

    // 2026-11-11 は水曜日。
    fn wed_morning() -> NaiveDateTime {
        dt(2026, 11, 11, 6, 0, 0)
    }

    #[test]
    fn next_none_and_disabled() {
        assert_eq!(next_run(&[], wed_morning()), None);
        assert_eq!(next_run(&[slot(0, 0x7F, 7, 0, false)], wed_morning()), None);
    }

    #[test]
    fn next_daily() {
        let r = next_run(&[slot(0, 0x7F, 7, 0, true)], wed_morning()).unwrap();
        assert_eq!(r.at, dt(2026, 11, 11, 7, 0, 0));
        let r = next_run(&[slot(0, 0x7F, 5, 0, true)], wed_morning()).unwrap();
        assert_eq!(r.at, dt(2026, 11, 12, 5, 0, 0));
    }

    #[test]
    fn next_weekday_mask() {
        let sat10 = dt(2026, 11, 14, 10, 0, 0);
        let r = next_run(&[slot(0, WEEKDAYS, 7, 0, true)], sat10).unwrap();
        assert_eq!(r.at, dt(2026, 11, 16, 7, 0, 0));
        assert_eq!(r.at.weekday(), chrono::Weekday::Mon);
        let r = next_run(&[slot(0, SAT | SUN, 9, 30, true)], wed_morning()).unwrap();
        assert_eq!(r.at, dt(2026, 11, 14, 9, 30, 0));
    }

    #[test]
    fn next_one_shot() {
        let r = next_run(&[slot(0, 0, 22, 5, true)], wed_morning()).unwrap();
        assert_eq!(r.at, dt(2026, 11, 11, 22, 5, 0));
        let r = next_run(&[slot(0, 0, 5, 5, true)], wed_morning()).unwrap();
        assert_eq!(r.at, dt(2026, 11, 12, 5, 5, 0));
    }

    #[test]
    fn next_same_weekday_next_week() {
        let r = next_run(&[slot(0, WED, 7, 0, true)], dt(2026, 11, 11, 12, 0, 0)).unwrap();
        assert_eq!(r.at, dt(2026, 11, 18, 7, 0, 0));
    }

    #[test]
    fn next_crosses_year() {
        let r = next_run(&[slot(0, 0x7F, 1, 0, true)], dt(2026, 12, 31, 23, 0, 0)).unwrap();
        assert_eq!(r.at, dt(2027, 1, 1, 1, 0, 0));
    }

    #[test]
    fn next_earliest_of_many() {
        let r = next_run(
            &[
                slot(0, 0x7F, 9, 0, true),
                slot(1, 0x7F, 6, 30, true),
                slot(2, 0x7F, 6, 15, false),
            ],
            wed_morning(),
        )
        .unwrap();
        assert_eq!(r.slot.id, 1);
        assert_eq!(r.at, dt(2026, 11, 11, 6, 30, 0));
    }

    #[test]
    fn next_tie_smaller_id() {
        let r = next_run(
            &[slot(5, 0x7F, 7, 0, true), slot(2, 0x7F, 7, 0, true)],
            wed_morning(),
        )
        .unwrap();
        assert_eq!(r.slot.id, 2);
    }

    #[test]
    fn next_same_minute() {
        let s = [slot(0, 0x7F, 7, 0, true)];
        assert_eq!(
            next_run(&s, dt(2026, 11, 11, 7, 0, 0)).unwrap().at,
            dt(2026, 11, 11, 7, 0, 0)
        );
        assert_eq!(
            next_run(&s, dt(2026, 11, 11, 7, 0, 1)).unwrap().at,
            dt(2026, 11, 12, 7, 0, 0)
        );
        assert_eq!(
            next_run(&s, dt(2026, 11, 11, 6, 59, 59)).unwrap().at,
            dt(2026, 11, 11, 7, 0, 0)
        );
    }

    #[test]
    fn until_labels() {
        let now = dt(2026, 11, 11, 6, 0, 0);
        assert_eq!(until_label(now, now), "まもなく");
        assert_eq!(until_label(dt(2026, 11, 11, 6, 30, 0), now), "あと 30分");
        assert_eq!(until_label(dt(2026, 11, 11, 7, 0, 0), now), "あと 1時間");
        assert_eq!(
            until_label(dt(2026, 11, 11, 12, 12, 0), now),
            "あと 6時間12分"
        );
        assert_eq!(until_label(dt(2026, 11, 13, 9, 0, 0), now), "あと 2日3時間");
        assert_eq!(until_label(dt(2026, 11, 11, 6, 0, 1), now), "あと 1分");
    }
}
