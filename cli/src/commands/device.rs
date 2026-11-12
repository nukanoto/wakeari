use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, Local, Offset};
use wakeari_protocol as proto;

use crate::ble::{self, Session, Target, Until};
use crate::output::*;

pub fn validate_name(name: &str) -> Result<()> {
    match proto::validate_name(name.as_bytes()) {
        Ok(_) => Ok(()),
        Err(proto::Error::Length) => bail!(
            "デバイス名は 1〜{} バイト（UTF-8）で指定してください（日本語なら全角 9 文字まで。今回は {} バイト）",
            proto::NAME_MAX_LEN,
            name.len()
        ),
        Err(_) => bail!("デバイス名に使えない文字が含まれています（制御文字は使えません）"),
    }
}

pub async fn stop(s: &Session) -> Result<()> {
    s.send(proto::Command::Off).await?;
    s.settle().await;
    let st = s.status().await?;
    if st.valve_on {
        println!("OFF を送りましたが、バルブはまだ動作中です。");
    } else {
        println!("バルブを停止しました。");
    }
    Ok(())
}

pub async fn sync(s: &Session) -> Result<()> {
    // 接続時にも同期しているが、明示的なコマンドなのでもう一度送る。
    s.sync_time().await?;
    s.settle().await;
    let st = s.status().await?;
    let off = Local::now().offset().fix().local_minus_utc() / 60;
    match st
        .time_synced
        .then(|| DateTime::from_timestamp(st.now_epoch, 0))
        .flatten()
    {
        Some(t) => println!(
            "時刻を同期しました: {}（{}）",
            format_datetime(t.with_timezone(&Local).naive_local()),
            format_utc_offset(off)
        ),
        None => println!("時刻を送りましたが、デバイスはまだ未同期と報告しています。"),
    }
    Ok(())
}

pub async fn name(s: &Session, target: &Target, new: Option<&str>) -> Result<()> {
    let Some(new) = new else {
        println!("{}", s.device_name().await?);
        return Ok(());
    };
    validate_name(new)?;
    let id = s.found.id.clone();
    println!("デバイス名を「{new}」に変更します。デバイスが再起動します...");
    s.write_name(new).await?;
    s.close().await;

    // デバイスは約 500ms 後にリセットする。再起動を待って探し直す。
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let deadline = Instant::now() + Duration::from_secs(20);
    let adapter = s.adapter.clone();
    let mut last_err = None;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let found = ble::scan(
            &adapter,
            remaining.min(target.timeout),
            Until::Rediscover { id: &id, name: new },
        )
        .await?;
        let pick = found
            .iter()
            .find(|f| f.id == id)
            .or_else(|| found.iter().find(|f| f.name.as_deref() == Some(new)))
            .cloned();
        if let Some(f) = pick {
            match Session::connect(adapter.clone(), f).await {
                Ok(ns) => {
                    let confirmed = ns.device_name().await;
                    ns.close().await;
                    let confirmed = confirmed?;
                    if confirmed == new {
                        println!("デバイス名を変更しました: {confirmed}");
                        return Ok(());
                    }
                    bail!("デバイス名が変更されていません（現在の名前: {confirmed}）");
                }
                Err(e) => last_err = Some(e),
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    match last_err {
        Some(e) => Err(anyhow!(
            "再起動後のデバイスに接続できませんでした: {e}。名前は変更されている可能性があります。`wakeari scan` で確認してください"
        )),
        None => Err(anyhow!(
            "再起動後のデバイスが見つかりませんでした（20 秒待ちました）。名前は変更されている可能性があります。`wakeari scan` で確認してください"
        )),
    }
}
