use anyhow::Result;

use crate::Cli;
use crate::ble::{self, Until};
use crate::output::{DeviceJson, print_json, table};

pub async fn run(cli: &Cli) -> Result<()> {
    let adapter = ble::adapter().await?;
    if !cli.json {
        eprintln!("{}秒間スキャンします...", cli.timeout.max(1));
    }
    let found = ble::scan(&adapter, crate::timeout(cli), Until::Timeout).await?;
    if cli.json {
        let v: Vec<DeviceJson> = found
            .iter()
            .map(|f| DeviceJson {
                name: f.name.clone(),
                id: f.id.clone(),
                rssi: f.rssi,
            })
            .collect();
        print_json(&v);
        return Ok(());
    }
    if found.is_empty() {
        println!("デバイスが見つかりませんでした。");
        return Ok(());
    }
    let rows: Vec<Vec<String>> = found
        .iter()
        .map(|f| {
            vec![
                f.display_name().to_string(),
                f.id.clone(),
                f.rssi
                    .map(|r| format!("{r} dBm"))
                    .unwrap_or_else(|| "-".into()),
            ]
        })
        .collect();
    println!("{}", table(&["名前", "ID", "電波強度"], &rows));
    Ok(())
}
