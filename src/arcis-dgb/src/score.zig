//! Valuation, DGB-equivalent score and benchmarks. Port of engine.py valuation + report.py.
const std = @import("std");
const engine = @import("engine.zig");
const Config = engine.Config;
const Ledger = engine.Ledger;
const Prices = engine.Prices;
const PySum = engine.PySum;

/// USD value of the siphon vault (exchange BTC/LTC/SOL + pending USDT + SOL wallet line).
pub fn vaultUsd(s: *const Ledger, px: Prices) f64 {
    const v = s.vault;
    var a: PySum = .{};
    for (0..3) |i| a.add(v.maj[i] * px.maj[i]);
    return a.result() + v.usdt_pending + v.sol_wallet * px.sol();
}

/// Total USD value: book (USD + DGB + majors) + vault.
pub fn usdTotal(cfg: *const Config, s: *const Ledger, px: Prices) f64 {
    _ = cfg;
    const h = s.h;
    var a: PySum = .{};
    for (0..3) |i| a.add(h.maj[i] * px.maj[i]);
    return h.usd + h.dgb * px.dgb + a.result() + vaultUsd(s, px);
}

/// Book converted to DGB at modeled cost (majors -> USD at taker cost, USD -> DGB at market cost).
pub fn bookDgbEquiv(cfg: *const Config, s: *const Ledger, px: Prices) f64 {
    const h = s.h;
    const mc = cfg.majCost();
    var a: PySum = .{};
    for (0..3) |i| a.add(h.maj[i] * px.maj[i] * (1 - mc));
    const usd = h.usd + a.result();
    return h.dgb + (if (usd > 0) usd * (1 - cfg.dgbCost(usd)) / px.dgb else 0);
}

/// The ledger's score: DGB-equivalent of the book plus the vault's USD value in DGB.
pub fn dgbScore(cfg: *const Config, s: *const Ledger, px: Prices) f64 {
    return bookDgbEquiv(cfg, s, px) + vaultUsd(s, px) / px.dgb;
}

/// Benchmarks since start, as DGB-count multiples of the start count (report.py).
/// hold DGB = 1.0 by definition; 50/50 = half DGB, half USD rebought at the end;
/// park in BTC = sell all DGB -> BTC at start, back to DGB now.
pub const Benchmarks = struct {
    hold_dgb: f64,
    fifty_fifty: f64,
    park_btc: f64,
};

pub fn benchmarks(cfg: *const Config, start_px: Prices, px: Prices) Benchmarks {
    const c1 = cfg.dgbCost(500);
    const c2 = cfg.dgbCost(1000);
    const mc = cfg.majCost();
    // same association as Python: x ** 2 is a single rounded square
    const a1 = (1 - c1) * (1 - c1);
    const a2 = (1 - c2) * (1 - c2);
    const m2 = (1 - mc) * (1 - mc);
    return .{
        .hold_dgb = 1.0,
        .fifty_fifty = 0.5 + 0.5 * a1 * start_px.dgb / px.dgb,
        .park_btc = a2 * m2 * (px.btc() / start_px.btc()) * start_px.dgb / px.dgb,
    };
}

pub const Report = struct {
    dgb_score: f64,
    start_dgb: f64,
    vs_start: f64, // dgb_score / start_dgb - 1
    usd_total: f64,
    usd_vs_start: f64,
    vault_usd: f64,
    max_dd: f64,
    bench: Benchmarks,
    /// score multiple minus each benchmark multiple (positive = beating it)
    edge_vs_hold: f64,
    edge_vs_5050: f64,
    edge_vs_btc: f64,
};

pub fn report(cfg: *const Config, s: *const Ledger, px: Prices) Report {
    const sc = dgbScore(cfg, s, px);
    const u = usdTotal(cfg, s, px);
    const b = benchmarks(cfg, s.start_px, px);
    const m = sc / s.start_dgb;
    return .{
        .dgb_score = sc,
        .start_dgb = s.start_dgb,
        .vs_start = m - 1,
        .usd_total = u,
        .usd_vs_start = u / s.start_usd - 1,
        .vault_usd = vaultUsd(s, px),
        .max_dd = s.max_dd,
        .bench = b,
        .edge_vs_hold = m - b.hold_dgb,
        .edge_vs_5050 = m - b.fifty_fifty,
        .edge_vs_btc = m - b.park_btc,
    };
}

/// Max drawdown of an equity series (min over t of value/peak - 1), same rule tick.py tracks live.
pub fn maxDrawdown(start_peak: f64, values: []const f64) f64 {
    var peak = start_peak;
    var dd: f64 = 0;
    for (values) |v| {
        peak = @max(peak, v);
        dd = @min(dd, v / peak - 1);
    }
    return dd;
}
