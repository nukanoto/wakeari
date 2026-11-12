use anyhow::Result;
use chrono::{DateTime, Local};
use wakeari_protocol as proto;

use crate::DebugCommand;
use crate::ble::Session;
use crate::output::*;

pub async fn run(s: &Session, cmd: &DebugCommand) -> Result<()> {
    match cmd {
        DebugCommand::On => {
            s.send(proto::Command::On).await?;
            let cfg = s.config().await?;
            println!(
                "バルブを ON にしました（{}後に自動で止まります）。止めるには `wakeari stop` を使います。",
                format_seconds(cfg.duration_s)
            );
        }
        DebugCommand::Off => {
            s.send(proto::Command::Off).await?;
            println!("バルブを OFF にしました。");
        }
        DebugCommand::Duration { seconds, reset } => {
            let new = if *reset {
                Some(proto::DEFAULT_DURATION_S)
            } else {
                *seconds
            };
            match new {
                None => println!(
                    "ON の長さ: {}",
                    format_seconds(s.config().await?.duration_s)
                ),
                Some(sec) => {
                    s.set_config(proto::Config { duration_s: sec }).await?;
                    s.settle().await;
                    println!(
                        "ON の長さを {} にしました。",
                        format_seconds(s.config().await?.duration_s)
                    );
                }
            }
        }
        DebugCommand::Raw => {
            let raw = s.status_raw().await?;
            let hex: Vec<String> = raw.iter().map(|b| format!("{b:02x}")).collect();
            println!("Status ({} バイト): {}", raw.len(), hex.join(" "));
            let st = proto::Status::parse(&raw)
                .map_err(|e| anyhow::anyhow!("Status を解釈できません: {e:?}"))?;
            println!("valve_on: {}", st.valve_on as u8);
            println!("remaining_s: {}", st.remaining_s);
            println!("time_synced: {}", st.time_synced as u8);
            let when = DateTime::from_timestamp(st.now_epoch, 0)
                .map(|t| format!(" ({})", t.with_timezone(&Local).format("%Y-%m-%d %H:%M:%S")))
                .unwrap_or_default();
            println!("now_epoch: {}{when}", st.now_epoch);
            println!("active_slot: 0x{:02x}", st.active_slot);
        }
    }
    Ok(())
}
