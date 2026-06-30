# Solana Swap Training Tracker v0.2.3

Privacy-preserving Solana swap training analysis for anonymous wallet groups.

## What changed in v0.2.3

- Added configurable request pacing / wait logic.
- By default the script waits after every 10 RPC/API requests.
- This helps with public Solana RPC endpoints that start timing out or rate-limiting after a short burst of requests.

## Analyze with wait after 10 requests

```powershell
python .\solana_swap_training_tracker.py analyze `
  --wallets holder_snapshot.csv `
  --rules training_rules.example.json `
  --public-output swap_training_public_results.csv `
  --html-output swap_training_public_report.html `
  --rate-limit-calls 1 `
  --rate-limit-wait-seconds 1
```

The two new parameters are:

| Parameter | Meaning |
|---|---|
| `--rate-limit-calls 10` | Wait after every 10 RPC/API requests |
| `--rate-limit-wait-seconds 15` | Wait 15 seconds before continuing |

Use `--rate-limit-calls 0` to disable request pacing.

## Holder snapshot via RPC with wait

```powershell
python .\solana_swap_training_tracker.py snapshot-holders-rpc `
  --source-token-mint "TOKEN_X_MINT_ADDRESS" `
  --min-amount "0.000001" `
  --output holder_snapshot.csv `
  --rate-limit-calls 10 `
  --rate-limit-wait-seconds 15
```

## Notes

- Public RPC endpoints can still fail for large tokens or many wallets.
- If this happens, increase `--rate-limit-wait-seconds` to `30` or use a dedicated Solana RPC provider.
- The public report still contains only pseudonymous wallet IDs, not names and not wallet addresses.
