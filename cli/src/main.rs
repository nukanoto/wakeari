mod ble;
mod commands;
mod output;
mod schedule;

use std::process::ExitCode;
use std::time::Duration;

use clap::{Args, Parser, Subcommand};

/// wakeari（BLE バルブアラーム）をパソコンから操作するコマンドラインツール。
#[derive(Parser)]
#[command(name = "wakeari", version, about, propagate_version = true)]
pub struct Cli {
    /// デバイスを探す時間（秒）
    #[arg(long, global = true, default_value_t = 10, value_name = "秒")]
    pub timeout: u64,

    /// 接続するデバイス（名前、または id / アドレス）。省略時は見つかったデバイスを使う
    #[arg(long, short = 'd', global = true, value_name = "名前またはID")]
    pub device: Option<String>,

    /// 読み取り系コマンド（scan / status / list）の出力を JSON にする
    #[arg(long, global = true)]
    pub json: bool,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// 近くのデバイスを探して一覧表示する
    Scan,
    /// デバイスの状態（時刻・バルブ・ON の長さ・次のアラーム）を表示する
    Status,
    /// アラームの一覧を表示する
    #[command(visible_alias = "ls")]
    List,
    /// アラームを追加する
    Add(AddArgs),
    /// アラームを変更する
    Edit(EditArgs),
    /// アラームを有効にする
    Enable(IdArg),
    /// アラームを無効にする
    Disable(IdArg),
    /// アラームを削除する
    #[command(visible_alias = "delete")]
    Rm(IdArg),
    /// すべてのアラームを削除する
    Clear {
        /// 確認せずに削除する
        #[arg(long, short = 'y')]
        yes: bool,
    },
    /// 動作中のバルブを止める
    Stop,
    /// デバイスの時刻を同期して表示する
    Sync,
    /// デバイス名を表示する。NEW を指定すると変更する
    Name {
        /// 新しいデバイス名（29 バイト以内の UTF-8）
        new: Option<String>,
    },
    /// デバッグ用のコマンド
    #[command(subcommand)]
    Debug(DebugCommand),
}

#[derive(Args)]
pub struct IdArg {
    /// アラームの ID（0〜7）
    #[arg(value_parser = clap::value_parser!(u8).range(0..8))]
    pub id: u8,
}

#[derive(Args)]
pub struct AddArgs {
    /// 時刻（HH:MM）
    pub time: String,
    /// 繰り返す曜日。平日 / 土日 / 毎日 / 月,水,金 / weekdays / weekends / daily / mon,wed,fri。省略すると 1 回のみ
    #[arg(long, value_name = "曜日")]
    pub days: Option<String>,
}

#[derive(Args)]
pub struct EditArgs {
    /// アラームの ID（0〜7）
    #[arg(value_parser = clap::value_parser!(u8).range(0..8))]
    pub id: u8,
    /// 新しい時刻（HH:MM）
    #[arg(long, value_name = "HH:MM")]
    pub time: Option<String>,
    /// 新しい繰り返し曜日（add の --days と同じ書き方）
    #[arg(long, value_name = "曜日", conflicts_with = "once")]
    pub days: Option<String>,
    /// 1 回のみにする
    #[arg(long)]
    pub once: bool,
}

#[derive(Subcommand)]
pub enum DebugCommand {
    /// バルブを手動で ON にする（ON の長さが過ぎると自動で止まる）
    On,
    /// バルブを OFF にする
    Off,
    /// ON の長さ（Config）を表示・変更する
    Duration {
        /// 秒数（1〜3600）。省略すると表示だけ
        #[arg(value_parser = clap::value_parser!(u16).range(1..=3600))]
        seconds: Option<u16>,
        /// 初期値（30 秒）に戻す
        #[arg(long, conflicts_with = "seconds")]
        reset: bool,
    },
    /// Status の生の値を表示する
    Raw,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    match commands::run(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("エラー: {e:#}");
            ExitCode::FAILURE
        }
    }
}

pub fn timeout(cli: &Cli) -> Duration {
    Duration::from_secs(cli.timeout.max(1))
}
