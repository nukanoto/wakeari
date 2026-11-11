//! wakeari BLE GATT プロトコル（docs/protocol.md）の実装。
//! ホストでテストできるよう no_std かつ依存なし。
#![cfg_attr(not(test), no_std)]

// ---- UUID ----
/// デバイス名の初期値
pub const DEFAULT_NAME: &str = "wakeari";
pub const SERVICE_UUID: &str = "9643763d-ca0d-45be-bae0-e3d2170256fe";
pub const TIME_UUID: &str = "59049d1c-3f43-4b9a-b9cd-ff479d454afa";
pub const COMMAND_UUID: &str = "6e0e3b6f-0aa8-40ad-855e-d527c4ce7e2e";
pub const STATUS_UUID: &str = "5eb782eb-b27c-4a34-ac18-03cf8f2ad6ff";
pub const SCHEDULES_UUID: &str = "75f7c1b1-0233-4282-a2d0-0932961212a8";
pub const CONFIG_UUID: &str = "8dbfbc93-2938-4495-a466-b2c67133bfd4";
pub const NAME_UUID: &str = "85fae2ad-ab1d-436a-922b-a3435a12154b";

pub const SERVICE_UUID_U128: u128 = 0x9643763d_ca0d_45be_bae0_e3d2170256fe;
pub const TIME_UUID_U128: u128 = 0x59049d1c_3f43_4b9a_b9cd_ff479d454afa;
pub const COMMAND_UUID_U128: u128 = 0x6e0e3b6f_0aa8_40ad_855e_d527c4ce7e2e;
pub const STATUS_UUID_U128: u128 = 0x5eb782eb_b27c_4a34_ac18_03cf8f2ad6ff;
pub const SCHEDULES_UUID_U128: u128 = 0x75f7c1b1_0233_4282_a2d0_0932961212a8;
pub const CONFIG_UUID_U128: u128 = 0x8dbfbc93_2938_4495_a466_b2c67133bfd4;
pub const NAME_UUID_U128: u128 = 0x85fae2ad_ab1d_436a_922b_a3435a12154b;

// ---- 定数 ----
pub const MAX_SLOTS: usize = 8;
pub const MAX_DURATION_S: u16 = 3600;
/// Config の初期値（秒）
pub const DEFAULT_DURATION_S: u16 = 30;
/// `active_slot` が「なし（手動 ON または OFF）」を表す値
pub const NO_ACTIVE_SLOT: u8 = 0xFF;
pub const SLOT_LEN: usize = 5;
pub const TIME_LEN: usize = 10;
pub const STATUS_LEN: usize = 13;
pub const CONFIG_LEN: usize = 2;
/// デバイス名の最大バイト数（スキャン応答 31 bytes から Complete Local Name のヘッダ 2 bytes を引いた値）
pub const NAME_MAX_LEN: usize = 29;
/// Command の最大長（PUT: 1 + 5）
pub const COMMAND_MAX_LEN: usize = 1 + SLOT_LEN;
/// Schedules characteristic の最大長（1 + 5*8 = 41）
pub const SCHEDULES_MAX_LEN: usize = 1 + SLOT_LEN * MAX_SLOTS;

pub const OP_ON: u8 = 0x01;
pub const OP_OFF: u8 = 0x02;
pub const OP_PUT: u8 = 0x10;
pub const OP_DELETE: u8 = 0x11;
pub const OP_CLEAR: u8 = 0x12;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// 長さが不正
    Length,
    /// 未知の opcode
    UnknownOpcode,
    /// 値が範囲外
    OutOfRange,
    /// 出力バッファが小さい
    BufferTooSmall,
}

// ---- Name ----
/// Name の検証。1〜29 bytes、正しい UTF-8、制御文字（U+0000〜U+001F, U+007F）なし。
pub fn validate_name(b: &[u8]) -> Result<&str, Error> {
    if b.is_empty() || b.len() > NAME_MAX_LEN {
        return Err(Error::Length);
    }
    let s = core::str::from_utf8(b).map_err(|_| Error::OutOfRange)?;
    if s.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7F) {
        return Err(Error::OutOfRange);
    }
    Ok(s)
}

// ---- Slot ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot {
    pub id: u8,
    pub enabled: bool,
    /// bit0=月 ... bit6=日。0 は単発
    pub weekday_mask: u8,
    pub hour: u8,
    pub minute: u8,
}

impl Slot {
    pub fn validate(&self) -> Result<(), Error> {
        if self.id as usize >= MAX_SLOTS
            || self.weekday_mask > 0x7F
            || self.hour > 23
            || self.minute > 59
        {
            return Err(Error::OutOfRange);
        }
        Ok(())
    }

    pub fn parse(b: &[u8]) -> Result<Slot, Error> {
        if b.len() != SLOT_LEN {
            return Err(Error::Length);
        }
        if b[1] > 1 {
            return Err(Error::OutOfRange);
        }
        let s = Slot {
            id: b[0],
            enabled: b[1] == 1,
            weekday_mask: b[2],
            hour: b[3],
            minute: b[4],
        };
        s.validate()?;
        Ok(s)
    }

    pub fn encode(&self) -> [u8; SLOT_LEN] {
        [
            self.id,
            self.enabled as u8,
            self.weekday_mask,
            self.hour,
            self.minute,
        ]
    }
}

// ---- Config ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    /// 1 回の ON の長さ（1..=MAX_DURATION_S）
    pub duration_s: u16,
}

impl Default for Config {
    fn default() -> Self {
        Config { duration_s: DEFAULT_DURATION_S }
    }
}

impl Config {
    pub fn validate(&self) -> Result<(), Error> {
        if self.duration_s == 0 || self.duration_s > MAX_DURATION_S {
            return Err(Error::OutOfRange);
        }
        Ok(())
    }

    pub fn parse(b: &[u8]) -> Result<Config, Error> {
        if b.len() != CONFIG_LEN {
            return Err(Error::Length);
        }
        let c = Config { duration_s: u16::from_le_bytes([b[0], b[1]]) };
        c.validate()?;
        Ok(c)
    }

    pub fn encode(&self) -> [u8; CONFIG_LEN] {
        self.duration_s.to_le_bytes()
    }
}

/// Schedules characteristic のエンコード。書き込んだバイト数を返す。
/// スロットは id 昇順に並べ替えず渡された順に書く（呼び出し側が昇順で渡す）。
/// バッファが足りない／件数超過のときは 0 を返す。
pub fn encode_schedules(slots: &[Slot], out: &mut [u8]) -> usize {
    let n = slots.len();
    if n > MAX_SLOTS || out.len() < 1 + SLOT_LEN * n {
        return 0;
    }
    out[0] = n as u8;
    for (i, s) in slots.iter().enumerate() {
        let o = 1 + i * SLOT_LEN;
        out[o..o + SLOT_LEN].copy_from_slice(&s.encode());
    }
    1 + SLOT_LEN * n
}

/// Schedules のデコード（永続化・テスト用）。
pub fn decode_schedules(b: &[u8], out: &mut [Slot; MAX_SLOTS]) -> Result<usize, Error> {
    if b.is_empty() {
        return Err(Error::Length);
    }
    let n = b[0] as usize;
    if n > MAX_SLOTS || b.len() != 1 + n * SLOT_LEN {
        return Err(Error::Length);
    }
    for i in 0..n {
        let o = 1 + i * SLOT_LEN;
        out[i] = Slot::parse(&b[o..o + SLOT_LEN])?;
    }
    Ok(n)
}

// ---- Command ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    On,
    Off,
    Put(Slot),
    Delete(u8),
    Clear,
}

impl Command {
    pub fn parse(b: &[u8]) -> Result<Command, Error> {
        let (&op, rest) = b.split_first().ok_or(Error::Length)?;
        match op {
            OP_ON => {
                if !rest.is_empty() {
                    return Err(Error::Length);
                }
                Ok(Command::On)
            }
            OP_OFF => {
                if !rest.is_empty() {
                    return Err(Error::Length);
                }
                Ok(Command::Off)
            }
            OP_PUT => Ok(Command::Put(Slot::parse(rest)?)),
            OP_DELETE => {
                if rest.len() != 1 {
                    return Err(Error::Length);
                }
                if rest[0] as usize >= MAX_SLOTS {
                    return Err(Error::OutOfRange);
                }
                Ok(Command::Delete(rest[0]))
            }
            OP_CLEAR => {
                if !rest.is_empty() {
                    return Err(Error::Length);
                }
                Ok(Command::Clear)
            }
            _ => Err(Error::UnknownOpcode),
        }
    }

    /// エンコード（アプリ側仕様の確認・テスト用）。最大 6 bytes。
    pub fn encode(&self, out: &mut [u8; COMMAND_MAX_LEN]) -> usize {
        match self {
            Command::On => {
                out[0] = OP_ON;
                1
            }
            Command::Off => {
                out[0] = OP_OFF;
                1
            }
            Command::Put(s) => {
                out[0] = OP_PUT;
                out[1..6].copy_from_slice(&s.encode());
                6
            }
            Command::Delete(id) => {
                out[0] = OP_DELETE;
                out[1] = *id;
                2
            }
            Command::Clear => {
                out[0] = OP_CLEAR;
                1
            }
        }
    }
}

// ---- TimeSync ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeSync {
    pub epoch_s: i64,
    pub tz_offset_min: i16,
}

impl TimeSync {
    pub fn parse(b: &[u8]) -> Result<TimeSync, Error> {
        if b.len() != TIME_LEN {
            return Err(Error::Length);
        }
        let mut e = [0u8; 8];
        e.copy_from_slice(&b[0..8]);
        let tz = i16::from_le_bytes([b[8], b[9]]);
        // -12:00 .. +14:00
        if !(-720..=840).contains(&tz) {
            return Err(Error::OutOfRange);
        }
        Ok(TimeSync {
            epoch_s: i64::from_le_bytes(e),
            tz_offset_min: tz,
        })
    }

    pub fn encode(&self) -> [u8; TIME_LEN] {
        let mut o = [0u8; TIME_LEN];
        o[0..8].copy_from_slice(&self.epoch_s.to_le_bytes());
        o[8..10].copy_from_slice(&self.tz_offset_min.to_le_bytes());
        o
    }
}

// ---- Status ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Status {
    pub valve_on: bool,
    pub remaining_s: u16,
    pub time_synced: bool,
    /// 未同期なら 0
    pub now_epoch: i64,
    /// 予約で ON 中ならその id。手動 ON / OFF なら NO_ACTIVE_SLOT
    pub active_slot: u8,
}

impl Default for Status {
    fn default() -> Self {
        Status {
            valve_on: false,
            remaining_s: 0,
            time_synced: false,
            now_epoch: 0,
            active_slot: NO_ACTIVE_SLOT,
        }
    }
}

impl Status {
    pub fn encode(&self) -> [u8; STATUS_LEN] {
        let mut o = [0u8; STATUS_LEN];
        o[0] = self.valve_on as u8;
        o[1..3].copy_from_slice(&self.remaining_s.to_le_bytes());
        o[3] = self.time_synced as u8;
        o[4..12].copy_from_slice(&self.now_epoch.to_le_bytes());
        o[12] = self.active_slot;
        o
    }

    pub fn parse(b: &[u8]) -> Result<Status, Error> {
        if b.len() != STATUS_LEN {
            return Err(Error::Length);
        }
        let mut e = [0u8; 8];
        e.copy_from_slice(&b[4..12]);
        Ok(Status {
            valve_on: b[0] != 0,
            remaining_s: u16::from_le_bytes([b[1], b[2]]),
            time_synced: b[3] != 0,
            now_epoch: i64::from_le_bytes(e),
            active_slot: b[12],
        })
    }
}

// ---- 時刻計算 ----
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalTime {
    /// 0=月 ... 6=日
    pub weekday: u8,
    pub hour: u8,
    pub minute: u8,
    /// ローカル時刻での 1970-01-01 00:00 からの分数
    pub epoch_minute: i64,
}

impl LocalTime {
    pub fn from_epoch(epoch_s: i64, tz_offset_min: i16) -> LocalTime {
        let local_s = epoch_s + tz_offset_min as i64 * 60;
        let local_min = local_s.div_euclid(60);
        let days = local_min.div_euclid(24 * 60);
        let min_of_day = local_min.rem_euclid(24 * 60);
        // 1970-01-01 は木曜（月=0 → 3）
        let weekday = (days + 3).rem_euclid(7) as u8;
        LocalTime {
            weekday,
            hour: (min_of_day / 60) as u8,
            minute: (min_of_day % 60) as u8,
            epoch_minute: local_min,
        }
    }
}

// ---- スケジュール ----
/// 発火したスロット。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Fired {
    pub count: usize,
    /// 発火したスロット id（id 昇順）
    pub items: [u8; MAX_SLOTS],
    /// 単発が無効化された（永続化が必要）
    pub one_shot_disabled: bool,
}

impl Fired {
    pub fn iter(&self) -> impl Iterator<Item = &u8> {
        self.items[..self.count].iter()
    }

    /// 発火したスロットのうち最小の id（active_slot に使う）
    pub fn min_id(&self) -> Option<u8> {
        self.iter().copied().min()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Schedule {
    pub slots: [Option<Slot>; MAX_SLOTS],
    last_fired: [Option<i64>; MAX_SLOTS],
}

impl Default for Schedule {
    fn default() -> Self {
        Self::new()
    }
}

impl Schedule {
    pub const fn new() -> Self {
        Schedule {
            slots: [None; MAX_SLOTS],
            last_fired: [None; MAX_SLOTS],
        }
    }

    pub fn put(&mut self, s: Slot) -> Result<(), Error> {
        s.validate()?;
        let i = s.id as usize;
        self.slots[i] = Some(s);
        self.last_fired[i] = None;
        Ok(())
    }

    pub fn delete(&mut self, id: u8) {
        if (id as usize) < MAX_SLOTS {
            self.slots[id as usize] = None;
            self.last_fired[id as usize] = None;
        }
    }

    pub fn clear(&mut self) {
        *self = Schedule::new();
    }

    pub fn apply(&mut self, c: &Command) {
        match c {
            Command::Put(s) => {
                let _ = self.put(*s);
            }
            Command::Delete(id) => self.delete(*id),
            Command::Clear => self.clear(),
            _ => {}
        }
    }

    pub fn count(&self) -> usize {
        self.slots.iter().flatten().count()
    }

    /// id 昇順のスロット列。件数を返す。
    pub fn collect(&self, out: &mut [Slot; MAX_SLOTS]) -> usize {
        let mut n = 0;
        for s in self.slots.iter().flatten() {
            out[n] = *s;
            n += 1;
        }
        n
    }

    /// Schedules characteristic の値にエンコード。
    pub fn encode(&self, out: &mut [u8]) -> usize {
        let mut tmp = [Slot {
            id: 0,
            enabled: false,
            weekday_mask: 0,
            hour: 0,
            minute: 0,
        }; MAX_SLOTS];
        let n = self.collect(&mut tmp);
        encode_schedules(&tmp[..n], out)
    }

    /// 現在のローカル時刻で発火すべきスロットを返し、状態を更新する。
    /// 単発スロットは発火と同時に enabled=false になる。
    pub fn tick(&mut self, t: LocalTime) -> Fired {
        let mut f = Fired::default();
        for i in 0..MAX_SLOTS {
            let Some(s) = self.slots[i].as_mut() else {
                continue;
            };
            if !s.enabled || s.hour != t.hour || s.minute != t.minute {
                continue;
            }
            let day_ok = s.weekday_mask == 0 || (s.weekday_mask >> t.weekday) & 1 == 1;
            if !day_ok || self.last_fired[i] == Some(t.epoch_minute) {
                continue;
            }
            self.last_fired[i] = Some(t.epoch_minute);
            f.items[f.count] = s.id;
            f.count += 1;
            if s.weekday_mask == 0 {
                s.enabled = false;
                f.one_shot_disabled = true;
            }
        }
        f
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slot(id: u8, mask: u8, h: u8, m: u8) -> Slot {
        Slot { id, enabled: true, weekday_mask: mask, hour: h, minute: m }
    }

    #[test]
    fn uuid_strings_match_u128() {
        fn parse(s: &str) -> u128 {
            u128::from_str_radix(&s.replace('-', ""), 16).unwrap()
        }
        assert_eq!(parse(SERVICE_UUID), SERVICE_UUID_U128);
        assert_eq!(parse(TIME_UUID), TIME_UUID_U128);
        assert_eq!(parse(COMMAND_UUID), COMMAND_UUID_U128);
        assert_eq!(parse(STATUS_UUID), STATUS_UUID_U128);
        assert_eq!(parse(SCHEDULES_UUID), SCHEDULES_UUID_U128);
        assert_eq!(parse(CONFIG_UUID), CONFIG_UUID_U128);
        assert_eq!(CONFIG_UUID, "8dbfbc93-2938-4495-a466-b2c67133bfd4");
    }

    #[test]
    fn slot_roundtrip_and_layout() {
        let s = slot(3, 0b0100101, 7, 30);
        let b = s.encode();
        assert_eq!(b, [3, 1, 0b0100101, 7, 30]);
        assert_eq!(b.len(), 5);
        assert_eq!(Slot::parse(&b), Ok(s));
    }

    #[test]
    fn slot_invalid() {
        let ok = slot(0, 0, 0, 0).encode();
        assert!(Slot::parse(&ok).is_ok());
        assert_eq!(Slot::parse(&ok[..4]), Err(Error::Length));
        // v1 の 7 bytes 形式は拒否
        assert_eq!(Slot::parse(&[0, 1, 0, 6, 0, 30, 0]), Err(Error::Length));
        for (idx, v) in [(0, 8), (1, 2), (2, 0x80), (3, 24), (4, 60)] {
            let mut b = ok;
            b[idx] = v;
            assert_eq!(Slot::parse(&b), Err(Error::OutOfRange), "idx {idx}");
        }
    }

    #[test]
    fn config_layout_and_range() {
        assert_eq!(Config::default().duration_s, 30);
        assert_eq!(DEFAULT_DURATION_S, 30);
        assert_eq!(Config { duration_s: 30 }.encode(), [30, 0]);
        assert_eq!(Config { duration_s: 3600 }.encode(), [0x10, 0x0e]);
        assert_eq!(Config::parse(&[0x2c, 0x01]), Ok(Config { duration_s: 300 }));
        assert_eq!(Config::parse(&[1, 0]), Ok(Config { duration_s: 1 }));
        assert_eq!(Config::parse(&[0x10, 0x0e]), Ok(Config { duration_s: 3600 }));
        assert_eq!(Config::parse(&[0, 0]), Err(Error::OutOfRange));
        assert_eq!(Config::parse(&[0x11, 0x0e]), Err(Error::OutOfRange)); // 3601
        assert_eq!(Config::parse(&[0xff, 0xff]), Err(Error::OutOfRange));
        assert_eq!(Config::parse(&[30]), Err(Error::Length));
        assert_eq!(Config::parse(&[30, 0, 0]), Err(Error::Length));
        assert_eq!(Config::parse(&[]), Err(Error::Length));
        assert_eq!(Config { duration_s: 0 }.validate(), Err(Error::OutOfRange));
    }

    #[test]
    fn command_parse() {
        assert_eq!(Command::parse(&[0x01]), Ok(Command::On));
        assert_eq!(Command::parse(&[0x02]), Ok(Command::Off));
        assert_eq!(Command::parse(&[0x11, 7]), Ok(Command::Delete(7)));
        assert_eq!(Command::parse(&[0x12]), Ok(Command::Clear));
        let s = slot(1, 0x7F, 23, 59);
        assert_eq!(
            Command::parse(&[0x10, 1, 1, 0x7F, 23, 59]),
            Ok(Command::Put(s))
        );
    }

    #[test]
    fn command_invalid() {
        assert_eq!(Command::parse(&[]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x99]), Err(Error::UnknownOpcode));
        // ON はペイロードなし（v1 の duration 付きは拒否）
        assert_eq!(Command::parse(&[0x01, 0x2c, 0x01]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x01, 0]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x02, 0]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x11]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x11, 8]), Err(Error::OutOfRange));
        assert_eq!(Command::parse(&[0x12, 0]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x10, 1, 2]), Err(Error::Length));
        // v1 の 7 bytes Slot
        assert_eq!(Command::parse(&[0x10, 1, 1, 0, 6, 0, 30, 0]), Err(Error::Length));
        assert_eq!(Command::parse(&[0x10, 8, 1, 0, 6, 0]), Err(Error::OutOfRange));
    }

    #[test]
    fn command_encode_roundtrip() {
        let cmds = [
            Command::On,
            Command::Off,
            Command::Put(slot(2, 1, 6, 0)),
            Command::Delete(4),
            Command::Clear,
        ];
        for c in cmds {
            let mut b = [0u8; COMMAND_MAX_LEN];
            let n = c.encode(&mut b);
            assert_eq!(Command::parse(&b[..n]), Ok(c));
        }
        let mut b = [0u8; COMMAND_MAX_LEN];
        assert_eq!(Command::Put(slot(2, 1, 6, 0)).encode(&mut b), 6);
        assert_eq!(b, [0x10, 2, 1, 1, 6, 0]);
    }

    #[test]
    fn time_sync() {
        let t = TimeSync { epoch_s: 1_700_000_000, tz_offset_min: 540 };
        let b = t.encode();
        assert_eq!(b.len(), 10);
        assert_eq!(&b[8..], &[0x1c, 0x02]);
        assert_eq!(TimeSync::parse(&b), Ok(t));
        let neg = TimeSync { epoch_s: -5, tz_offset_min: -300 };
        assert_eq!(TimeSync::parse(&neg.encode()), Ok(neg));
        assert_eq!(TimeSync::parse(&b[..9]), Err(Error::Length));
        let bad = TimeSync { epoch_s: 0, tz_offset_min: 2000 }.encode();
        assert_eq!(TimeSync::parse(&bad), Err(Error::OutOfRange));
    }

    #[test]
    fn status_layout() {
        let s = Status {
            valve_on: true,
            remaining_s: 258,
            time_synced: true,
            now_epoch: 1,
            active_slot: 3,
        };
        let b = s.encode();
        assert_eq!(b, [1, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 3]);
        assert_eq!(b.len(), 13);
        assert_eq!(Status::parse(&b), Ok(s));
        // 既定は OFF / 未同期 / active_slot なし
        let mut d = [0u8; 13];
        d[12] = 0xFF;
        assert_eq!(Status::default().encode(), d);
        assert_eq!(Status::default().active_slot, NO_ACTIVE_SLOT);
        // v1 の 12 bytes は拒否
        assert_eq!(Status::parse(&b[..12]), Err(Error::Length));
    }

    #[test]
    fn schedules_encode() {
        let slots = [slot(0, 1, 1, 2), slot(5, 0, 4, 5)];
        let mut buf = [0u8; SCHEDULES_MAX_LEN];
        let n = encode_schedules(&slots, &mut buf);
        assert_eq!(n, 11);
        assert_eq!(&buf[..n], &[2, 0, 1, 1, 1, 2, 5, 1, 0, 4, 5]);
        let mut out = [slot(0, 0, 0, 0); MAX_SLOTS];
        assert_eq!(decode_schedules(&buf[..n], &mut out), Ok(2));
        assert_eq!(&out[..2], &slots);
        assert_eq!(encode_schedules(&[], &mut buf), 1);
        assert_eq!(buf[0], 0);
        let mut small = [0u8; 5];
        assert_eq!(encode_schedules(&slots, &mut small), 0);
        let full = [slot(0, 1, 1, 1); MAX_SLOTS];
        assert_eq!(encode_schedules(&full, &mut buf), 41);
        assert_eq!(SCHEDULES_MAX_LEN, 41);
    }

    #[test]
    fn decode_v1_schedules_fails() {
        // v1: count=1, 7 bytes slot
        let v1 = [1u8, 0, 1, 0x7F, 6, 0, 30, 0];
        let mut out = [slot(0, 0, 0, 0); MAX_SLOTS];
        assert!(decode_schedules(&v1, &mut out).is_err());
    }

    #[test]
    fn weekday_calc() {
        // 1970-01-01 00:00 UTC = 木曜
        let t = LocalTime::from_epoch(0, 0);
        assert_eq!((t.weekday, t.hour, t.minute), (3, 0, 0));
        // 2023-11-14 22:13:20 UTC = 火曜
        let t = LocalTime::from_epoch(1_700_000_000, 0);
        assert_eq!((t.weekday, t.hour, t.minute), (1, 22, 13));
        // JST: 翌日 07:13 水曜
        let t = LocalTime::from_epoch(1_700_000_000, 540);
        assert_eq!((t.weekday, t.hour, t.minute), (2, 7, 13));
        // 負の tz: 1970-01-01 00:00 UTC, UTC-5 → 1969-12-31 19:00 水曜
        let t = LocalTime::from_epoch(0, -300);
        assert_eq!((t.weekday, t.hour, t.minute), (2, 19, 0));
        assert_eq!(t.epoch_minute, -300);
        // 負の epoch: 1969-12-31 23:59:59 UTC = 水曜
        let t = LocalTime::from_epoch(-1, 0);
        assert_eq!((t.weekday, t.hour, t.minute), (2, 23, 59));
        // 日曜: 1970-01-04
        let t = LocalTime::from_epoch(3 * 86400, 0);
        assert_eq!(t.weekday, 6);
        // 月曜: 1970-01-05
        let t = LocalTime::from_epoch(4 * 86400 + 3600, 0);
        assert_eq!((t.weekday, t.hour), (0, 1));
    }

    // 2023-11-13(月) 06:00 JST = 2023-11-12 21:00 UTC
    const MON_0600_JST: i64 = 1_699_822_800;

    #[test]
    fn repeat_fires_on_matching_day_only() {
        let mut sch = Schedule::new();
        sch.put(slot(0, 0b0000001, 6, 0)).unwrap(); // 月のみ
        let t = LocalTime::from_epoch(MON_0600_JST, 540);
        assert_eq!(t.weekday, 0);
        let f = sch.tick(t);
        assert_eq!(f.count, 1);
        assert_eq!(f.items[0], 0);
        assert!(!f.one_shot_disabled);
        // 翌日(火) は発火しない
        let t2 = LocalTime::from_epoch(MON_0600_JST + 86400, 540);
        assert_eq!(sch.tick(t2).count, 0);
        // 翌週の月曜は再び発火する
        let t3 = LocalTime::from_epoch(MON_0600_JST + 7 * 86400, 540);
        assert_eq!(sch.tick(t3).count, 1);
    }

    #[test]
    fn no_double_fire_in_same_minute() {
        let mut sch = Schedule::new();
        sch.put(slot(1, 0x7F, 6, 0)).unwrap();
        for s in 0..60 {
            let t = LocalTime::from_epoch(MON_0600_JST + s, 540);
            let f = sch.tick(t);
            assert_eq!(f.count, if s == 0 { 1 } else { 0 }, "sec {s}");
        }
        // 次の日は再度発火
        let f = sch.tick(LocalTime::from_epoch(MON_0600_JST + 86400 + 5, 540));
        assert_eq!(f.count, 1);
    }

    #[test]
    fn disabled_and_wrong_time_do_not_fire() {
        let mut sch = Schedule::new();
        let mut s = slot(0, 0x7F, 6, 0);
        s.enabled = false;
        sch.put(s).unwrap();
        sch.put(slot(1, 0x7F, 6, 1)).unwrap();
        assert_eq!(sch.tick(LocalTime::from_epoch(MON_0600_JST, 540)).count, 0);
    }

    #[test]
    fn one_shot_fires_once_and_disables() {
        let mut sch = Schedule::new();
        sch.put(slot(2, 0, 6, 0)).unwrap();
        let f = sch.tick(LocalTime::from_epoch(MON_0600_JST, 540));
        assert_eq!(f.count, 1);
        assert_eq!(f.items[0], 2);
        assert!(f.one_shot_disabled);
        let s = sch.slots[2].unwrap();
        assert!(!s.enabled); // スロット自体は残る
        // 翌日の同時刻でも発火しない
        assert_eq!(sch.tick(LocalTime::from_epoch(MON_0600_JST + 86400, 540)).count, 0);
        // 再度 enabled で PUT すれば再び発火する
        sch.put(slot(2, 0, 6, 0)).unwrap();
        assert_eq!(sch.tick(LocalTime::from_epoch(MON_0600_JST + 86400, 540)).count, 1);
    }

    #[test]
    fn multiple_slots_same_minute() {
        let mut sch = Schedule::new();
        sch.put(slot(0, 0x7F, 6, 0)).unwrap();
        sch.put(slot(7, 0x7F, 6, 0)).unwrap();
        let f = sch.tick(LocalTime::from_epoch(MON_0600_JST, 540));
        assert_eq!(f.count, 2);
        let v: Vec<_> = f.iter().copied().collect();
        assert_eq!(v, vec![0, 7]);
        assert_eq!(f.min_id(), Some(0));
    }

    #[test]
    fn schedule_put_delete_clear_encode() {
        let mut sch = Schedule::new();
        sch.apply(&Command::Put(slot(5, 1, 1, 1)));
        sch.apply(&Command::Put(slot(2, 1, 2, 2)));
        assert_eq!(sch.count(), 2);
        let mut buf = [0u8; SCHEDULES_MAX_LEN];
        let n = sch.encode(&mut buf);
        assert_eq!(n, 11);
        assert_eq!(buf[1], 2); // id 昇順
        assert_eq!(buf[6], 5);
        sch.apply(&Command::Delete(2));
        assert_eq!(sch.count(), 1);
        sch.apply(&Command::Clear);
        assert_eq!(sch.count(), 0);
        assert_eq!(sch.encode(&mut buf), 1);
        // 不正な Put は状態を変えない
        let mut bad = slot(0, 0, 0, 0);
        bad.hour = 30;
        assert!(sch.put(bad).is_err());
        assert_eq!(sch.count(), 0);
    }

    #[test]
    fn name_uuid_matches() {
        let v = u128::from_str_radix(&NAME_UUID.replace('-', ""), 16).unwrap();
        assert_eq!(v, NAME_UUID_U128);
        assert_eq!(NAME_UUID, "85fae2ad-ab1d-436a-922b-a3435a12154b");
    }

    #[test]
    fn name_validation() {
        assert_eq!(validate_name(b"wakeari"), Ok("wakeari"));
        assert_eq!(validate_name(DEFAULT_NAME.as_bytes()), Ok(DEFAULT_NAME));
        assert_eq!(validate_name(b"a"), Ok("a"));
        assert!(validate_name(&[b'a'; 29]).is_ok());
        assert_eq!(validate_name(&[b'a'; 30]), Err(Error::Length));
        // 日本語 9 文字 = 27 bytes は可、10 文字 = 30 bytes は不可
        let ok = "あいうえおかきくけ";
        assert_eq!(ok.len(), 27);
        assert_eq!(validate_name(ok.as_bytes()), Ok(ok));
        let ng = "あいうえおかきくけこ";
        assert_eq!(ng.len(), 30);
        assert_eq!(validate_name(ng.as_bytes()), Err(Error::Length));
        assert_eq!(validate_name(b""), Err(Error::Length));
        assert_eq!(validate_name(&[0xFF, 0xFE]), Err(Error::OutOfRange));
        assert_eq!(validate_name(&"あ".as_bytes()[..2]), Err(Error::OutOfRange));
        for bad in [&b"a\0b"[..], b"a\nb", b"\x1f", b"a\x7f", b"\ttab"] {
            assert_eq!(validate_name(bad), Err(Error::OutOfRange), "{:?}", bad);
        }
        assert!(validate_name(b"a b").is_ok());
    }
}
