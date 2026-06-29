# Solana Swap Training Tracker v0.2.0

eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJjcmVhdGVkQXQiOjE3ODI3NTI5NDIwODMsImVtYWlsIjoibm91cmFtb25AYWx2ZXN0cmFzemEuY29tIiwiYWN0aW9uIjoidG9rZW4tYXBpIiwiYXBpVmVyc2lvbiI6InYyIiwiaWF0IjoxNzgyNzUyOTQyfQ.vWszM6tczrKXz0VM7Z0hB9io8-zwnoNZQoFqYj879Is


Privacy-preserving CLI tool to evaluate Solana swap trainings without linking participant names to wallet addresses.

## Privacy model

The public report contains only anonymous wallet IDs such as `W000001`, `W000002`, and so on.

Names are never required. The recommended workflow is:

1. Before the training starts, snapshot all wallets that currently hold Token X.
2. Use that anonymous snapshot as the source list.
3. After the training window, analyze whether those anonymous wallets swapped Token X to Token Y.
4. Share only the public CSV/HTML report with the group.
5. Keep private evidence files restricted to admins, or disable them.

## Requirements

- Python 3.9 or newer
- No Python packages required
- Solana RPC endpoint for analysis
- Solscan Pro API key for automatic holder snapshots

## Step 1: Snapshot Token X holders

```bash
python solana_swap_training_tracker_v0.2.0.py snapshot-holders --source-token-mint "6VdVk3ngmTDBrZDgHCWE3U1VmKFmFTh5mnN43LJQeE9U" --solscan-api-key "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJjcmVhdGVkQXQiOjE3ODI3NTM2NTA5MzQsImVtYWlsIjoibm91cmFtb25AYWx2ZXN0cmFzemEuY29tIiwiYWN0aW9uIjoidG9rZW4tYXBpIiwiYXBpVmVyc2lvbiI6InYyIiwiaWF0IjoxNzgyNzUzNjUwfQ.5-E_9rQLQEq_26_tjm0H8Qmgd5ISLs-jShOkCvfw-uM" --min-amount "1000" --output holder_snapshot.csv
```

You can also set the API key as an environment variable:

```bash
export SOLSCAN_API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJjcmVhdGVkQXQiOjE3ODI3NTM2NTA5MzQsImVtYWlsIjoibm91cmFtb25AYWx2ZXN0cmFzemEuY29tIiwiYWN0aW9uIjoidG9rZW4tYXBpIiwiYXBpVmVyc2lvbiI6InYyIiwiaWF0IjoxNzgyNzUzNjUwfQ.5-E_9rQLQEq_26_tjm0H8Qmgd5ISLs-jShOkCvfw-uM"
```

Then run:

```bash
python solana_swap_training_tracker_v0.2.0.py snapshot-holders \
  --source-token-mint "ReplaceWithTokenXMint" \
  --min-amount "0.000001" \
  --output holder_snapshot.csv
```

## Step 2: Analyze Token X -> Token Y swaps

Configure `training_rules.example.json` with:

- `start_time`
- `end_time`
- `from_mint` = Token X mint
- `to_mint` = Token Y mint
- optional min/max input and output amounts

Then run:

```bash
python solana_swap_training_tracker_v0.2.0.py analyze \
  --wallets holder_snapshot.csv \
  --rules training_rules.example.json \
  --public-output swap_training_public_results.csv \
  --html-output swap_training_public_report.html
```

For larger groups, use a private RPC endpoint:

```bash
python solana_swap_training_tracker_v0.2.0.py analyze \
  --wallets holder_snapshot.csv \
  --rules training_rules.example.json \
  --rpc-url "https://your-private-rpc.example" \
  --public-output swap_training_public_results.csv \
  --html-output swap_training_public_report.html
```

## Disable private evidence files

By default, v0.2.0 writes private evidence files for admins:

- `swap_training_private_evidence.csv`
- `swap_training_private_events.csv`

Disable them like this:

```bash
python solana_swap_training_tracker_v0.2.0.py analyze \
  --wallets holder_snapshot.csv \
  --rules training_rules.example.json \
  --private-output "" \
  --events-output "" \
  --public-output swap_training_public_results.csv \
  --html-output swap_training_public_report.html
```

## Important limitation

A Token X holder list is a current snapshot. If you create it after the training, wallets that successfully swapped all Token X away may no longer appear in the holder list. For fair results, create the snapshot immediately before the training begins.

## Output files

| File | Privacy level | Content |
|---|---|---|
| `holder_snapshot.csv` | Admin | Anonymous wallet IDs plus wallet addresses |
| `swap_training_public_results.csv` | Public | Wallet IDs, status, rule, actual token movement summary |
| `swap_training_public_report.html` | Public | Browser-friendly report without names or wallet addresses |
| `swap_training_private_evidence.csv` | Admin | Wallet addresses, signatures, Solscan links |
| `swap_training_private_events.csv` | Admin | All detected swap-like events |

## Status meanings

| Status | Meaning |
|---|---|
| `OK` | Expected input token was spent and expected output token was received. |
| `WRONG_SWAP` | A swap-like transaction happened, but it did not match the rule. |
| `MISSING` | No swap-like transaction was found in the configured time window. |

## Notes

- No private keys are needed.
- No wallet connection is needed.
- No participant names are needed.
- Public reports intentionally do not contain wallet addresses.
- Transaction links can deanonymize wallet behavior; public HTML reports omit them by default.
