mod alarms;
mod debug;
mod device;
mod scan;
mod status;

use anyhow::{Result, anyhow};

use crate::ble::{self, Session, Target};
use crate::{Cli, Command};

pub async fn run(cli: Cli) -> Result<()> {
    // デバイスに接続する前に済ませられる入力の検証・確認。
    match &cli.command {
        Command::Scan => return scan::run(&cli).await,
        Command::Add(a) => {
            alarms::validate_add(a)?;
        }
        Command::Edit(e) => alarms::validate_edit(e)?,
        Command::Name { new: Some(n) } => device::validate_name(n)?,
        Command::Clear { yes: false } if !alarms::confirm_clear()? => {
            println!("キャンセルしました。");
            return Ok(());
        }
        _ => {}
    }

    let target = Target {
        timeout: crate::timeout(&cli),
        device: cli.device.clone(),
    };
    let interrupted = || anyhow!("中断しました");
    let session = tokio::select! {
        r = ble::open(&target) => r?,
        _ = tokio::signal::ctrl_c() => return Err(interrupted()),
    };
    let result = tokio::select! {
        r = dispatch(&cli, &target, &session) => r,
        _ = tokio::signal::ctrl_c() => Err(interrupted()),
    };
    session.close().await;
    result
}

async fn dispatch(cli: &Cli, target: &Target, s: &Session) -> Result<()> {
    match &cli.command {
        Command::Scan => unreachable!("scan は接続しない"),
        Command::Status => status::run(s, cli.json).await,
        Command::List => alarms::list(s, cli.json).await,
        Command::Add(a) => alarms::add(s, a).await,
        Command::Edit(e) => alarms::edit(s, e).await,
        Command::Enable(a) => alarms::set_enabled(s, a.id, true).await,
        Command::Disable(a) => alarms::set_enabled(s, a.id, false).await,
        Command::Rm(a) => alarms::remove(s, a.id).await,
        Command::Clear { .. } => alarms::clear(s).await,
        Command::Stop => device::stop(s).await,
        Command::Sync => device::sync(s).await,
        Command::Name { new } => device::name(s, target, new.as_deref()).await,
        Command::Debug(d) => debug::run(s, d).await,
    }
}
