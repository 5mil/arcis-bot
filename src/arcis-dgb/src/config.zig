//! DGB paper desk configuration. PAPER ONLY: no exchange accounts, API keys, wallets or orders.
//! Mirrors /workspace/dgb/paper/config.py value-for-value. All constants are typed f64 so that
//! derived values (e.g. `maj_cost`) are computed with f64 rounding, exactly like Python.

pub const paper: bool = true;
comptime {
    if (!paper) @compileError("arcis-dgb: PAPER must be true; this module contains no live trading code");
}

pub const Strategy = enum { grid, regime };

/// Per-ledger strategy parameters (Python `LEDGERS[...]` / state `params`).
pub const Params = struct {
    strategy: Strategy,
    k: f64,
    levels: u32,
    smin: f64,
    smax: f64,
    vol_days: u32,
    recenter_days: u32,
    /// regime only
    band: f64 = 0,
    /// regime only (MA length in days)
    n: u32 = 0,
};

/// S1: volatility-scaled grid (lab best params, tuned Oct 2022 - Mar 2025).
pub const s1: Params = .{ .strategy = .grid, .k = 1.0, .levels = 6, .smin = 0.04, .smax = 0.15, .vol_days = 14, .recenter_days = 30 };
/// S5: regime switch: grid while DGB is strong vs the BTC/LTC/SOL basket, parks everything in BTC when weak.
pub const s5: Params = .{ .strategy = .regime, .k = 1.0, .levels = 10, .smin = 0.03, .smax = 0.15, .vol_days = 14, .recenter_days = 30, .band = 0.10, .n = 90 };

pub const LedgerDef = struct { name: []const u8, params: Params };
pub const ledgers = [_]LedgerDef{ .{ .name = "S1", .params = s1 }, .{ .name = "S5", .params = s5 } };

/// Hard upper bound on grid levels (open lots are stored in a fixed array, no allocation).
pub const max_levels: usize = 32;
/// Hard upper bound on vol_days / n windows handled on the stack.
pub const max_window: usize = 512;

pub const SiphonMode = enum {
    /// coin among BTC/LTC/SOL with the lowest price / 30-day average
    cheapest,
    /// skim to USDT, convert to SOL when SOL < its 30-day avg or after 30 days
    usdt_sol,
};

pub const Coin = enum(u2) { BTC = 0, LTC = 1, SOL = 2 };
pub const siphon_coins = [_]Coin{ .BTC, .LTC, .SOL };

/// Runtime-overridable copy of every global knob. `default` == config.py. Engine functions take
/// `*const Config` so tests can exercise e.g. usdt_sol mode without editing anything.
pub const Config = struct {
    start_usd: f64 = 1000.0,
    start_dgb_fraction: f64 = 0.5,

    // Siphon: share of each profitable round trip (realized USD gain) moved to a vault, never traded back.
    siphon_share: f64 = 0.30,
    siphon_mode: SiphonMode = .cheapest,
    siphon_trend_days: u32 = 30,
    usdt_sol_max_wait_days: f64 = 30,
    usd_to_usdt_cost: f64 = 0.001, // estimate

    // SOL vault line: paper "withdrawal" (ledger move only) at quarter start or when >= 1 SOL.
    sol_withdraw_min: f64 = 1.0,
    sol_withdraw_fee_sol: f64 = 0.01, // estimate, not a quoted fee

    // Costs (Crypto.com-like estimates; same as the lab)
    dgb_maker_fee: f64 = 0.0025, // grid limit orders
    dgb_adverse: f64 = 0.0010, // adverse fill vs the grid level
    dgb_taker_fee: f64 = 0.0050, // market orders (S5 park / return)
    dgb_half_spread: f64 = 0.0065,
    dgb_depth_usd: f64 = 1500.0, // impact = 1% x size/depth (capped at 3x)
    maj_taker_fee: f64 = 0.0050,
    maj_half_spread: f64 = 0.0001,

    // Alerts: freeze a ledger (no auto-sell) when its USD value <= (1 - this) x start
    halt_drawdown_from_start: f64 = 0.30,

    // Data
    max_replay_hours: usize = 72,

    pub fn majCost(c: *const Config) f64 {
        return c.maj_taker_fee + c.maj_half_spread;
    }

    /// Market-order cost for a DGB trade of `usd` notional (fee + half spread + depth impact).
    pub fn dgbCost(c: *const Config, usd: f64) f64 {
        return c.dgb_taker_fee + c.dgb_half_spread + 0.01 * @min(usd / c.dgb_depth_usd, 3.0);
    }
};

pub const default: Config = .{};

/// DGB price sources, in order (informational; the live feed is NOT implemented here).
pub const dgb_sources = [_][]const u8{ "cryptocom", "binance" };
