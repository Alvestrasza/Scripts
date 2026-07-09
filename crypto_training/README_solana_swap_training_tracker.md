# Solana Swap Training Tracker v0.4.3

Privacy-preserving Solana token-history based swap training analyzer.

## What changed in v0.4.3

Solscan token-history CSV exports may contain raw base-unit amounts in `Amount1` and `Amount2` while the decimal precision is stored separately in `TokenDecimals1` and `TokenDecimals2`.

Example from Solscan:

```csv
Token1,Amount1,TokenDecimals1,Token2,Amount2,TokenDecimals2
So11111111111111111111111111111111111111112,30000000,9,TokenX,62828895104,9
```

This means:

```text
30000000 / 10^9 = 0.03 SOL
62828895104 / 10^9 = 62.828895104 TokenX
```

Earlier versions treated `30000000` as a human amount during the CSV prefilter, so valid training buys such as `0.029–0.032 SOL` were filtered out before the RPC transaction check.

v0.4.3 normalizes `Amount1/Amount2` with `TokenDecimals1/TokenDecimals2` before applying the CSV step/value prefilter.

## Recommended command

```powershell
python .\solana_swap_training_tracker_v0.4.3.py analyze-token-history `
  --token-history token_history.csv `
  --wallets holder_snapshot.csv `
  --rules token_history_rules.json `
  --public-output token_history_public_results.csv `
  --summary-output token_history_summary.csv `
  --html-output token_history_public_report.html `
  --private-output "" `
  --events-output "" `
  --debug-token-history-csv `
  --rate-limit-calls 10 `
  --rate-limit-wait-seconds 10
```

## New option

```powershell
--csv-amount-mode auto|raw|ui
```

Default:

```powershell
--csv-amount-mode auto
```

Modes:

| Mode | Meaning |
|---|---|
| `auto` | If `TokenDecimals1/2` exists, treat `Amount1/2` as raw base units and divide by `10^decimals`. Recommended for Solscan CSV exports. |
| `raw` | Same normalization behavior as `auto`; useful when you want to state the intent explicitly. |
| `ui` | Treat `Amount1/2` as already human-readable. Use this only if your CSV already contains values like `0.03` instead of `30000000`. |

## Diagnostic hint

Run with:

```powershell
--debug-token-history-csv
```

The script prints how many rows/signatures were accepted and which CSV amount mode was used.

## Privacy model

The public report contains only pseudonymous wallet IDs. Wallet addresses remain private unless you explicitly enable private output files.
