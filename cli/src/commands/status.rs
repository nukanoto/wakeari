use anyhow::Result;
use chrono::{DateTime, Local, Offset};

use crate::ble::{Session, describe};
use crate::output::*;
use crate::schedule::{next_run, repeat_label, until_label, weekday_label};
use chrono::Datelike;
use wakeari_protocol::NO_ACTIVE_SLOT;

pub async fn run(s: &Session, json: bool) -> Result<()> {
    let st = s.status().await?;
    let cfg = s.config().await?;
    let slots = s.schedules().await?;
    let name = s.device_name().await?;

    let local_now = Local::now();
    let offset_min = local_now.offset().fix().local_minus_utc() / 60;
    // 時刻は接続直後に同期済み。デバイスの時刻をローカル時刻で表示する。
    let device_time = if st.time_synced {
        DateTime::from_timestamp(st.now_epoch, 0).map(|t| t.with_timezone(&Local).naive_local())
    } else {
        None
    };
    let now = local_now.naive_local();
    let next = next_run(&slots, now);
    let active = (st.valve_on && st.active_slot != NO_ACTIVE_SLOT).then_some(st.active_slot);

    if json {
        print_json(&StatusJson {
            device: DeviceJson {
                name: s.found.name.clone(),
                id: s.found.id.clone(),
                rssi: s.found.rssi,
            },
            device_name: name,
            time_synced: st.time_synced,
            device_time: device_time.map(|t| t.format("%Y-%m-%dT%H:%M:%S").to_string()),
            valve_on: st.valve_on,
            remaining_s: st.remaining_s,
            active_slot: active,
            duration_s: cfg.duration_s,
            next_alarm: next.map(|n| NextJson {
                id: n.slot.id,
                at: n.at.format("%Y-%m-%dT%H:%M").to_string(),
                until: until_label(n.at, now),
            }),
        });
        return Ok(());
    }

    println!("接続: {}", describe(&s.found));
    println!("デバイス名: {name}");
    match device_time {
        Some(t) => println!(
            "デバイス時刻: {}（{}）",
            format_datetime(t),
            format_utc_offset(offset_min)
        ),
        None => println!("デバイス時刻: 未同期"),
    }
    if st.valve_on {
        let mut line = String::from("バルブ: 動作中");
        if let Some(id) = active {
            let label = slots
                .iter()
                .find(|x| x.id == id)
                .map(alarm_summary)
                .unwrap_or_else(|| format!("ID {id}"));
            line.push_str(&format!("（アラーム {label}）"));
        }
        line.push_str(&format!("　残り {}", format_seconds(st.remaining_s)));
        println!("{line}");
    } else {
        println!("バルブ: 停止中");
    }
    println!("ON の長さ: {}", format_seconds(cfg.duration_s));
    match next {
        Some(n) => println!(
            "次のアラーム: {}（{}）{} ・ ID {} ・ {}",
            format_time(n.slot.hour, n.slot.minute),
            weekday_label(n.at.date().weekday().num_days_from_monday()),
            until_label(n.at, now),
            n.slot.id,
            repeat_label(n.slot.weekday_mask)
        ),
        None => println!("次のアラーム: なし"),
    }
    Ok(())
}
