# polycopy

A copy-trading bot for [Polymarket](https://polymarket.com). It watches one or
more wallets on Polymarket's public data API and mirrors their fills onto your
own CLOB account, subject to a risk and sizing policy you control.

**Dry run is the default at every layer.** Placing a real order requires
`live: true` in the config, `--live` on the command line, and typing `LIVE` at a
confirmation prompt.

---

## What it does

```
leader wallet fills  →  risk gate  →  sizing  →  limit order on the CLOB  →  ledger
   (data API)           (vetoes)     (shares)      (py-clob-client)         (SQLite)
```

Each poll fetches recent fills for every configured leader, discards ones it has
already processed, and runs the rest through the pipeline. Every decision —
copied or skipped — is written to SQLite with a reason, so you can always answer
"why didn't it take that trade?".

**Entries** (leader BUYs) are sized by your chosen policy: a fixed dollar amount,
a fraction of the leader's notional, or a fraction of your bankroll.

**Exits** (leader SELLs) are sized against *your* position, not theirs. What
transfers is the *fraction* of their position the leader exited — if they sold
40% of their stake, you sell 40% of yours. If their remaining position can't be
read, the bot exits in full, because flat is the safe default when the person
whose thesis you're renting may have already left.

---

## Install

```bash
cd polycopy
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
```

## Quick start

```bash
polycopy init                    # writes config.yaml and .env.example
$EDITOR config.yaml              # add leader addresses
polycopy doctor                  # check config, API reachability, credentials
polycopy watch --limit 20        # see what your leaders are doing (never trades)
polycopy run                     # paper-trade the strategy
```

Let it paper-trade for a while, read `polycopy status`, then consider going live.

## Going live

1. Fund a Polymarket account and note whether you sign as an EOA (`0`), an
   email/magic proxy (`1`), or a browser wallet proxy (`2`).
2. Copy `.env.example` to `.env` and fill in `POLYMARKET_PRIVATE_KEY`. Set
   `POLYMARKET_FUNDER` to your Polymarket deposit address when signature type is
   1 or 2. API credentials are derived from the key automatically if you leave
   them blank.
3. Set `live: true` in `config.yaml`.
4. `polycopy run --live` and type `LIVE` at the prompt.

Start with `max_order_usdc` and `daily_spend_cap_usdc` set to amounts you are
genuinely willing to lose while you find out how the strategy behaves.

---

## Commands

| Command | What it does |
|---|---|
| `polycopy init` | Write a starter `config.yaml` and `.env.example` |
| `polycopy doctor` | Validate config, ping both APIs, verify credentials and balance |
| `polycopy watch [-f]` | Print leader activity. Never places or simulates an order |
| `polycopy run [--live] [--once]` | Run the copy loop |
| `polycopy status [--reconcile]` | Positions, exposure, P&L, recent orders |

## Configuration

`config.yaml` holds strategy; `.env` holds secrets. They are separate so the
config can be committed and shared.

### `leaders`

```yaml
leaders:
  - address: "0xabc...123"
    label: whale-1
    weight: 1.0          # scales this leader's order sizes
    max_order_usdc: 25   # optional per-leader ceiling
```

The address is the wallet's **proxy address** — the one in the URL when you open
a trader's Polymarket profile.

### `sizing`

| Key | Meaning |
|---|---|
| `mode` | `fixed` (constant dollars), `proportional` (× leader's notional), `bankroll_fraction` (× your bankroll) |
| `fixed_usdc` / `proportional_factor` / `bankroll_fraction` | Parameter for the chosen mode |
| `min_order_usdc` / `max_order_usdc` | Clamp applied after sizing |
| `exit_policy` | `proportional`, `full`, or `off` (ignore leader sells) |

### `risk`

Every key here is a veto. Notable ones:

| Key | Why it exists |
|---|---|
| `min_price` / `max_price` | Longshots and near-resolved markets copy badly — the edge is gone by the time you see the fill |
| `min_leader_notional_usdc` | Ignore the leader's dust; only copy trades they meant |
| `max_trade_age_seconds` | Refuse fills you saw too late |
| `min_seconds_to_close` | Don't enter a market that's about to resolve |
| `max_market_exposure_usdc` | Per-market cap |
| `max_total_exposure_usdc` | Portfolio cap |
| `daily_spend_cap_usdc` | Rolling UTC-day cap on new entries |
| `max_open_markets` | Concurrency cap |
| `max_slippage_bps` | Ceiling on `execution.slippage_bps`; the tighter of the two wins |
| `block_keywords` / `block_condition_ids` / `allow_condition_ids` | Market filters |

Exits deliberately bypass the price band, the notional floor and the budget
caps: if the leader is getting out, a full budget is no reason to keep holding.

Budget caps *shrink* an order rather than rejecting it — a nearly-full daily cap
still trades, just smaller, until the remainder falls below the minimum.

### `execution`

| Key | Meaning |
|---|---|
| `order_type` | `FAK` (default — cross the spread, cancel the rest), `FOK`, or `GTC` |
| `slippage_bps` | Budget in bps *relative to* the leader's fill price: 100 bps on a 0.40 fill permits paying 0.404 |
| `round_shares_down` | Round to whole shares |

`FAK` is the right default for copying: a resting order that never fills is
worse than no order.

---

## How it stays out of trouble

- **Idempotency.** Every fill gets a SHA-256 key over `(leader, tx hash, asset,
  side, price, size, timestamp)`. A transaction hash alone isn't unique — one
  Polygon transaction can settle several fills.
- **Cold start.** On a fresh database the bot marks existing history as seen
  instead of copying 50 historic positions at once. Set
  `cold_start_lookback_seconds` if you do want recent history.
- **Skips are recorded.** A vetoed trade is marked seen, so it can't be copied
  late if the filter state changes on a later poll.
- **Failures are contained.** A flaky leader, a bad payload, or a rejected order
  can't stop the loop; each is logged and the poll continues.
- **Price rounding respects the tick grid**, always in the direction that helps
  the order fill.
- **Dust exits are promoted to full exits.** A trim that would strand a
  remainder below the market minimum — unsellable forever — closes the position.

## Reconciliation

The ledger assumes fills complete. Run `polycopy status --reconcile` to compare
it against on-chain balances and surface any drift.

---

## Tests

```bash
pytest
```

The suite runs entirely offline: HTTP is mocked with `respx`, and the executor
is a paper stub. It covers config validation, tick rounding, every risk veto,
entry and exit sizing, the position ledger, idempotency and the poll loop.

---

## Limitations, honestly

- **The paper executor is optimistic.** It fills everything at your limit price.
  It is a rehearsal of the plumbing, not a backtest, and it does not model the
  order book at all.
- **You will get worse prices than the leader.** You're trading after them, on
  the information their trade has already moved into the price. That adverse
  selection is structural and no setting fixes it — the slippage budget only
  bounds how much of it you accept.
- **Fill accounting is inferred.** The bot re-reads `size_matched` where it can,
  but falls back to assuming a matched order filled completely. Reconcile
  periodically.
- **Leader position lookups are best-effort.** Proportional exits depend on the
  positions endpoint; when it fails the bot exits in full.
- **The data API is unofficial** in the sense that field names have changed
  before. Parsing is defensive, but a schema change could quietly stop trades
  from being recognised. `polycopy doctor` is the canary — run it after any gap
  in activity.
- **No resolution handling.** Winning positions aren't redeemed automatically;
  cost basis stays in the exposure figures until you sell or redeem manually.

## Risk

Copy trading is not risk-free, and a profitable-looking wallet is not evidence
of skill: survivorship bias means you are shown the winners of a large field of
mostly-losing accounts, and a track record long enough to distinguish skill from
luck in a market this noisy is longer than most Polymarket accounts have existed.
You are also, structurally, always later than the person you're copying.

Prediction markets are restricted or prohibited in some jurisdictions, including
for US persons under some venues' terms. Check Polymarket's terms and your local
law before running this with real money. Trade only what you can afford to lose.

## License

MIT
