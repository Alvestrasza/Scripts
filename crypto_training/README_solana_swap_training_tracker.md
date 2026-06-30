# Solana Swap Training Tracker v0.2.2

<!--
File Name     : README_solana_swap_training_tracker_v0.2.2.md
Version       : v0.2.2
Created       : 2026-06-29
Last Modified : 2026-06-29
Author        : Alice Endelgard / Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Description   : Usage notes for the privacy-preserving Solana swap training tracker with Solscan Pro and Solana RPC holder snapshots.
-->

## Purpose

This tool evaluates Solana swap training exercises without linking participant names to wallet addresses.

It supports two holder snapshot modes:

1. `snapshot-holders` using Solscan Pro API.
2. `snapshot-holders-rpc` using Solana JSON-RPC `getProgramAccounts` only.

The RPC mode is intended for users who do not have access to Solscan Pro endpoints.

## Install

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
```

The script uses only Python standard-library modules.

## Create holder snapshot without Solscan Pro

```powershell
python .\solana_swap_training_tracker_v0.2.2.py snapshot-holders-rpc `
  --source-token-mint "TOKEN_X_MINT_ADDRESS" `
  --rpc-url "https://api.mainnet-beta.solana.com" `
  --min-amount "0.000001" `
  --output holder_snapshot.csv
```

For large tokens, the public Solana RPC endpoint may reject or rate-limit the request. Use a dedicated RPC endpoint if that happens.

## Token-2022

For Token-2022 mints, use the Token-2022 program ID:

```powershell
python .\solana_swap_training_tracker_v0.2.2.py snapshot-holders-rpc `
  --source-token-mint "TOKEN_X_MINT_ADDRESS" `
  --token-program-id "TokenzQdBNbLqP5VEhdkAS6EPFAbf6Zp6EGH4Wk8BBQP" `
  --no-data-size-filter `
  --output holder_snapshot.csv
```

## Analyze swaps

```powershell
python .\solana_swap_training_tracker_v0.2.2.py analyze `
  --wallets holder_snapshot.csv `
  --rules training_rules.example.json `
  --public-output swap_training_public_results.csv `
  --html-output swap_training_public_report.html `
  --private-output "" `
  --events-output ""
```

## Privacy model

The public report contains:

- wallet_id, for example `W000001`
- rule name
- status
- expected and actual token direction

The public report intentionally does not contain:

- participant names
- wallet addresses

The holder snapshot itself still contains wallet addresses because the analyzer needs them. Treat it as private evidence data.

## v0.2.2 CSV Compatibility Fix

Version v0.2.2 fixes the analyzer input reader. Holder snapshot files are written as semicolon-separated CSV files for German Excel compatibility, while older analyzer code expected comma-separated CSV files. The analyzer now auto-detects comma, semicolon, or tab delimiters.

If you saw this error, use v0.2.2:

```text
ERROR: Wallet source CSV must contain a 'wallet' column.
```

