# Solana Swap Training Tracker v0.4.0

This version is intended for large holder lists where per-wallet history scans are too slow.

## Core idea

Do not scan 70,000 wallet histories.

Instead:

1. Export or collect the token history for the relevant token and training time window.
2. Use that history as a candidate stream of transaction signatures.
3. Fetch only those transaction details via Solana RPC.
4. Calculate wallet-level Token/SOL balance deltas from the transaction metadata.
5. Compare only wallets from your anonymous wallet source list.

The public report contains only `wallet_id`, never participant names and never wallet addresses.

## Required files

### 1. Anonymous wallet source

A CSV with at least these columns:

```csv
wallet_id;wallet
W000001;WalletAddress1
W000002;WalletAddress2
```

You can use an existing holder snapshot CSV. The analyzer only needs `wallet_id` and `wallet`.

### 2. Token history CSV

A CSV exported from Solscan or another source. It must contain a transaction signature column. Supported column names include:

- `signature`
- `tx`
- `tx_hash`
- `transaction_hash`
- `trans_id`
- `hash`

Optional timestamp columns:

- `block_time`
- `time`
- `date`
- `timestamp`

Example:

```csv
signature;block_time
REAL_SIGNATURE_1;2026-06-30T16:01:00+00:00
REAL_SIGNATURE_2;2026-06-30T16:17:00+00:00
```

If the CSV timestamps are missing or cannot be parsed, the script still checks the on-chain transaction `blockTime` returned by RPC.

### 3. Training rules

Example for your current training pattern:

```json
{
  "training_name": "Token X Swap Training - Token History Mode",
  "token_mint": "TOKEN_X_MINT_ADDRESS",
  "quote_mint": "So11111111111111111111111111111111111111112",
  "start_time": "2026-06-30T18:00:00+02:00",
  "end_time": "2026-06-30T19:00:00+02:00",
  "steps": [
    {
      "name": "1. Buy Token X with SOL",
      "direction": "buy",
      "amount_basis": "quote",
      "min_quote": "0.029",
      "max_quote": "0.032",
      "fee_tolerance_quote": "0.003"
    },
    {
      "name": "2. Sell Token X amount X",
      "direction": "sell",
      "amount_basis": "token",
      "min_token": "1000",
      "max_token": "1000",
      "token_tolerance": "0.000001"
    },
    {
      "name": "3. Buy Token X with SOL",
      "direction": "buy",
      "amount_basis": "quote",
      "min_quote": "0.029",
      "max_quote": "0.032",
      "fee_tolerance_quote": "0.003"
    }
  ]
}
```

## Recommended: use step time windows

For best detection of wrong direction, define `start_time` and `end_time` for each step.

Without per-step windows, the script treats the steps as an ordered sequence.

## Run command

```powershell
python .\solana_swap_training_tracker.py analyze-token-history `
  --token-history token_history.csv `
  --wallets holder_snapshot.csv `
  --rules token_history_rules.example.json `
  --public-output token_history_public_results.csv `
  --summary-output token_history_summary.csv `
  --html-output token_history_public_report.html `
  --private-output "" `
  --events-output "" `
  --rate-limit-calls 1 `
  --rate-limit-wait-seconds 1
```

## Outputs

| File | Purpose |
|---|---|
| `token_history_public_results.csv` | Pseudonymous wallet_id-only step results |
| `token_history_summary.csv` | Summary metrics |
| `token_history_public_report.html` | Human-readable public report |
| `token_history_private_evidence.csv` | Optional private evidence with wallet addresses |
| `token_history_private_events.csv` | Optional private detected token trades |

## Important limitations

- Native SOL balance deltas include transaction fees. Use `fee_tolerance_quote` for SOL buy steps.
- This validates direction and amount by wallet-level deltas. It is much more precise than plain before/after snapshots, but still depends on the transaction metadata returned by the RPC provider.
- If a swap uses temporary wrapped SOL accounts, the script combines native SOL deltas and wallet-owned wSOL token deltas where visible in `preTokenBalances` and `postTokenBalances`.
