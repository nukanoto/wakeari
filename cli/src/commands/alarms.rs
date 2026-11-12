use std::io::Write;

use anyhow::{Result, anyhow, bail};
use wakeari_protocol::{Command, MAX_SLOTS, Slot};

use crate::ble::Session;
use crate::output::*;
use crate::schedule::{parse_days, parse_time, smallest_free_id};
use crate::{AddArgs, EditArgs};

pub fn validate_add(a: &AddArgs) -> Result<()> {
    parse_time(&a.time)?;
    if let Some(d) = &a.days {
        parse_days(d)?;
    }
    Ok(())
}

pub fn validate_edit(e: &EditArgs) -> Result<()> {
    if e.time.is_none() && e.days.is_none() && !e.once {
        bail!("変更する内容を --time / --days / --once のどれかで指定してください");
    }
    if let Some(t) = &e.time {
        parse_time(t)?;
    }
    if let Some(d) = &e.days {
        parse_days(d)?;
    }
    Ok(())
}

pub fn confirm_clear() -> Result<bool> {
    print!("すべてのアラームを削除します。よろしいですか？ [y/N] ");
    std::io::stdout().flush()?;
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    Ok(matches!(
        line.trim().to_lowercase().as_str(),
        "y" | "yes" | "はい"
    ))
}

pub async fn list(s: &Session, json: bool) -> Result<()> {
    let slots = s.schedules().await?;
    if json {
        let v: Vec<AlarmJson> = slots.iter().map(alarm_json).collect();
        print_json(&v);
    } else if slots.is_empty() {
        println!("アラームはありません。");
    } else {
        println!("{}", alarm_table(&slots));
    }
    Ok(())
}

pub async fn add(s: &Session, a: &AddArgs) -> Result<()> {
    let (hour, minute) = parse_time(&a.time)?;
    let mask = match &a.days {
        Some(d) => parse_days(d)?,
        None => 0,
    };
    let slots = s.schedules().await?;
    let id = smallest_free_id(&slots).ok_or_else(|| {
        anyhow!("アラームがいっぱいです（最大 {MAX_SLOTS} 件）。不要なものを削除してください")
    })?;
    let slot = Slot {
        id,
        enabled: true,
        weekday_mask: mask,
        hour,
        minute,
    };
    s.put(slot).await?;
    println!(
        "アラームを追加しました: {}",
        alarm_summary(&confirmed(s, slot).await)
    );
    Ok(())
}

/// 書き込み後の値を読み直す。読めなければ送った値を返す。
async fn confirmed(s: &Session, sent: Slot) -> Slot {
    s.settle().await;
    match s.schedules().await {
        Ok(v) => v.into_iter().find(|x| x.id == sent.id).unwrap_or(sent),
        Err(_) => sent,
    }
}

async fn find(s: &Session, id: u8) -> Result<Slot> {
    s.schedules()
        .await?
        .into_iter()
        .find(|x| x.id == id)
        .ok_or_else(|| anyhow!("ID {id} のアラームはありません"))
}

pub async fn edit(s: &Session, e: &EditArgs) -> Result<()> {
    let mut slot = find(s, e.id).await?;
    if let Some(t) = &e.time {
        (slot.hour, slot.minute) = parse_time(t)?;
    }
    if let Some(d) = &e.days {
        slot.weekday_mask = parse_days(d)?;
    }
    if e.once {
        slot.weekday_mask = 0;
    }
    s.put(slot).await?;
    println!(
        "アラームを変更しました: {}",
        alarm_summary(&confirmed(s, slot).await)
    );
    Ok(())
}

pub async fn set_enabled(s: &Session, id: u8, enabled: bool) -> Result<()> {
    let mut slot = find(s, id).await?;
    slot.enabled = enabled;
    s.put(slot).await?;
    let verb = if enabled {
        "有効にしました"
    } else {
        "無効にしました"
    };
    println!(
        "アラームを{verb}: {}",
        alarm_summary(&confirmed(s, slot).await)
    );
    Ok(())
}

pub async fn remove(s: &Session, id: u8) -> Result<()> {
    let slot = find(s, id).await?;
    s.send(Command::Delete(id)).await?;
    println!("アラームを削除しました: {}", alarm_summary(&slot));
    Ok(())
}

pub async fn clear(s: &Session) -> Result<()> {
    s.send(Command::Clear).await?;
    println!("すべてのアラームを削除しました。");
    Ok(())
}
