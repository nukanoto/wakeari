#![no_std]
#![no_main]
#![deny(
    clippy::mem_forget,
    reason = "mem::forget is generally not safe to do with esp_hal types, especially those \
    holding buffers for the duration of a data transfer."
)]

use bt_hci::controller::ExternalController;
use embassy_executor::Spawner;
use esp_backtrace as _;
use esp_hal::clock::CpuClock;
use esp_hal::gpio::{Level, Output, OutputConfig};
use esp_hal::timer::timg::TimerGroup;
use esp_radio::ble::controller::BleConnector;
use esp_storage::FlashStorage;

mod ble;
mod clock;
mod config;
mod name;
mod scheduler;
mod storage;
mod valve;

extern crate alloc;

// This creates a default app-descriptor required by the esp-idf bootloader.
esp_bootloader_esp_idf::esp_app_desc!();

#[esp_rtos::main]
async fn main(spawner: Spawner) -> ! {
    let config = esp_hal::Config::default().with_cpu_clock(CpuClock::max());
    let peripherals = esp_hal::init(config);

    // バルブ（GPIO2）は何よりも先に Low（OFF）にする
    let valve_pin = Output::new(peripherals.GPIO2, Level::Low, OutputConfig::default());

    esp_alloc::heap_allocator!(#[esp_hal::ram(reclaimed)] size: 65536);

    let timg0 = TimerGroup::new(peripherals.TIMG0);
    esp_rtos::start(timg0.timer0, peripherals.FROM_CPU_INTR0);

    // 保存済みの tz / スケジュールを復元
    let mut st = storage::Storage::new(FlashStorage::new(peripherals.FLASH));
    match st.load().await {
        Ok((tz, sched, cfg, nm)) => {
            if let Some(tz) = tz {
                clock::restore_tz(tz);
            }
            esp_println::println!(
                "storage: loaded tz={:?} slots={} duration={:?}",
                tz,
                sched.count(),
                cfg.map(|c| c.duration_s)
            );
            if let Some(cfg) = cfg {
                config::restore(cfg);
            }
            if let Some(nm) = &nm {
                name::restore(nm.as_bytes());
            }
            esp_println::println!("storage: name={}", name::get());
            scheduler::restore(sched);
        }
        Err(e) => esp_println::println!("storage: load failed: {}", e),
    }

    spawner.spawn(valve::valve_task(valve_pin).unwrap());
    spawner.spawn(scheduler::scheduler_task().unwrap());
    spawner.spawn(storage::storage_task(st).unwrap());

    let transport = BleConnector::new(peripherals.BT, Default::default()).unwrap();
    let controller: ble::BleController = ExternalController::new(transport);
    ble::run(controller).await
}
