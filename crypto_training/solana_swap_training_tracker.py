#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# File Name     : solana_swap_training_tracker_v0.2.2.py
# Version       : v0.2.2
# Created       : 2026-06-29
# Last Modified : 2026-06-29
# Author        : Alice Endelgard / Nouramon Alvestrasza
# Organization  : Alvestrasza Corporation
# Description   : Snapshot anonymous Solana token holders via Solscan Pro or Solana RPC and evaluate swap training transactions without linking names to wallets. Supports comma and semicolon CSV input.

"""
Solana Swap Training Tracker

This CLI supports a privacy-preserving workflow for group swap trainings:

1. Snapshot all current holders of Token X into an anonymous wallet source CSV using Solscan Pro or Solana RPC.
2. After the training window, analyze whether each anonymous wallet swapped Token X to Token Y.
3. Export a public pseudonymous report and an optional private evidence file.

No private keys are required. Only public on-chain data is queried.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

NATIVE_SOL_MINT = "So11111111111111111111111111111111111111112"
LAMPORTS_PER_SOL = Decimal("1000000000")
ZERO = Decimal("0")
DEFAULT_RPC_URL = "https://api.mainnet-beta.solana.com"
DEFAULT_SOLSCAN_API_URL = "https://pro-api.solscan.io/v2.0"
SPL_TOKEN_PROGRAM_ID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
SPL_TOKEN_2022_PROGRAM_ID = "TokenzQdBNbLqP5VEhdkAS6EPFAbf6Zp6EGH4Wk8BBQP"


class RpcError(RuntimeError):
    """Raised when the Solana RPC endpoint returns an error."""


class SolscanError(RuntimeError):
    """Raised when the Solscan Pro API endpoint returns an error."""


@dataclass
class WalletSource:
    wallet_id: str
    wallet: str
    source_mint: str = ""
    source_amount: str = ""
    source_rank: str = ""
    source_token_account: str = ""
    snapshot_time: str = ""


@dataclass
class SwapEvent:
    wallet_id: str
    wallet: str
    signature: str
    block_time: Optional[int]
    slot: Optional[int]
    status: str
    negatives: Dict[str, Decimal]
    positives: Dict[str, Decimal]
    solscan_url: str


@dataclass
class RuleResult:
    wallet_id: str
    wallet: str
    rule_name: str
    expected_from: str
    expected_to: str
    status: str
    reason: str
    signature: str = ""
    block_time: str = ""
    actual_from: str = ""
    actual_to: str = ""
    solscan_url: str = ""


def parse_decimal(value: Any, default: Optional[Decimal] = None) -> Optional[Decimal]:
    if value is None or value == "":
        return default
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise ValueError(f"Invalid decimal value: {value!r}") from exc


def parse_iso_datetime(value: str) -> datetime:
    normalized = value.strip().replace("Z", "+00:00")
    dt = datetime.fromisoformat(normalized)
    if dt.tzinfo is None:
        raise ValueError(f"Datetime must include a timezone offset: {value}")
    return dt.astimezone(timezone.utc)


def unix_to_text(ts: Optional[int]) -> str:
    if ts is None:
        return ""
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def now_utc_text() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_rules(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        rules = json.load(handle)
    required = {"start_time", "end_time", "required_swaps"}
    missing = required - set(rules.keys())
    if missing:
        raise ValueError(f"Rules file is missing required keys: {', '.join(sorted(missing))}")
    if not isinstance(rules["required_swaps"], list) or not rules["required_swaps"]:
        raise ValueError("Rules file must contain at least one required swap.")
    return rules


def detect_csv_delimiter(sample: str) -> str:
    """Detect the CSV delimiter used by wallet source files.

    The tracker writes semicolon-separated CSV files for German Excel compatibility.
    Older/manual participant files may use commas. This helper accepts both.
    """
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=";,\t")
        return dialect.delimiter
    except csv.Error:
        first_line = sample.splitlines()[0] if sample.splitlines() else ""
        if first_line.count(";") >= first_line.count(","):
            return ";"
        return ","


def read_wallet_sources(path: Path) -> List[WalletSource]:
    wallets: List[WalletSource] = []
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(4096)
        handle.seek(0)
        delimiter = detect_csv_delimiter(sample)
        reader = csv.DictReader(handle, delimiter=delimiter)
        fieldnames = {field.strip() for field in (reader.fieldnames or [])}
        if "wallet" not in fieldnames:
            visible_fields = ", ".join(reader.fieldnames or []) or "none"
            raise ValueError(
                "Wallet source CSV must contain a 'wallet' column. "
                f"Detected delimiter {delimiter!r}; detected columns: {visible_fields}"
            )

        seen_wallets: set[str] = set()
        for index, row in enumerate(reader, start=1):
            normalized_row = {(key or "").strip(): (value or "") for key, value in row.items()}
            wallet = normalized_row.get("wallet", "").strip()
            if not wallet or wallet in seen_wallets:
                continue
            seen_wallets.add(wallet)
            wallet_id = (normalized_row.get("wallet_id") or f"W{index:06d}").strip()
            wallets.append(
                WalletSource(
                    wallet_id=wallet_id,
                    wallet=wallet,
                    source_mint=normalized_row.get("source_mint", "").strip(),
                    source_amount=normalized_row.get("source_amount", "").strip(),
                    source_rank=normalized_row.get("source_rank", "").strip(),
                    source_token_account=normalized_row.get("source_token_account", "").strip(),
                    snapshot_time=normalized_row.get("snapshot_time", "").strip(),
                )
            )

    if not wallets:
        raise ValueError("No wallet sources found.")
    return wallets


def write_wallet_sources(path: Path, wallets: List[WalletSource]) -> None:
    fieldnames = [
        "wallet_id",
        "wallet",
        "source_mint",
        "source_amount",
        "source_rank",
        "source_token_account",
        "snapshot_time",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for wallet in wallets:
            writer.writerow(wallet.__dict__)


def rpc_call(rpc_url: str, method: str, params: List[Any], timeout: int = 30, retries: int = 3) -> Any:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode("utf-8")
    request = urllib.request.Request(
        rpc_url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    last_error: Optional[BaseException] = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
                data = json.loads(body)
                if "error" in data:
                    raise RpcError(f"RPC error for {method}: {data['error']}")
                return data.get("result")
        except (urllib.error.URLError, TimeoutError, RpcError, json.JSONDecodeError) as exc:
            last_error = exc
            if attempt < retries:
                time.sleep(1.5 * attempt)
            else:
                break
    raise RpcError(f"RPC call failed after {retries} attempts: {method}: {last_error}")


def solscan_get(api_base_url: str, api_key: str, path: str, query: Dict[str, Any], timeout: int = 30, retries: int = 3) -> Dict[str, Any]:
    clean_base = api_base_url.rstrip("/")
    encoded_query = urllib.parse.urlencode({key: value for key, value in query.items() if value is not None and value != ""})
    url = f"{clean_base}{path}?{encoded_query}"
    request = urllib.request.Request(
        url,
        headers={
            "accept": "application/json",
            "token": api_key,
        },
        method="GET",
    )

    last_error: Optional[BaseException] = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = json.loads(response.read().decode("utf-8"))
                if data.get("success") is False:
                    raise SolscanError(f"Solscan API error: {data.get('errors') or data}")
                return data
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError, SolscanError) as exc:
            last_error = exc
            if attempt < retries:
                time.sleep(1.5 * attempt)
            else:
                break
    raise SolscanError(f"Solscan API call failed after {retries} attempts: {last_error}")


def snapshot_holders_solscan(
    api_base_url: str,
    api_key: str,
    token_mint: str,
    min_amount: Optional[str],
    max_pages: int,
    page_size: int,
) -> List[WalletSource]:
    wallets: List[WalletSource] = []
    seen_owners: set[str] = set()
    snapshot_time = now_utc_text()

    for page in range(1, max_pages + 1):
        response = solscan_get(
            api_base_url,
            api_key,
            "/token/holders",
            {
                "address": token_mint,
                "page": page,
                "page_size": page_size,
                "from_amount": min_amount,
            },
        )
        data = response.get("data") or {}
        items = data.get("items") or []
        if not items:
            break

        for item in items:
            owner = str(item.get("owner") or "").strip()
            token_account = str(item.get("address") or "").strip()
            if not owner or owner in seen_owners:
                continue
            seen_owners.add(owner)
            amount = item.get("amount_str")
            if amount in (None, ""):
                amount = item.get("amount", "")
            rank = item.get("rank", "")
            wallets.append(
                WalletSource(
                    wallet_id=f"W{len(wallets) + 1:06d}",
                    wallet=owner,
                    source_mint=token_mint,
                    source_amount=str(amount or ""),
                    source_rank=str(rank or ""),
                    source_token_account=token_account,
                    snapshot_time=snapshot_time,
                )
            )

        total = int(data.get("total") or 0)
        if total and len(wallets) >= total:
            break
        if len(items) < page_size:
            break

    return wallets


def token_amount_from_parsed_info(info: Dict[str, Any]) -> Decimal:
    token_amount = info.get("tokenAmount") or {}
    raw_amount = token_amount.get("amount")
    decimals = token_amount.get("decimals", 0)
    if raw_amount is not None:
        return Decimal(str(raw_amount)) / (Decimal(10) ** int(decimals))
    ui_amount_string = token_amount.get("uiAmountString")
    return parse_decimal(ui_amount_string, ZERO) or ZERO


def snapshot_holders_rpc(
    rpc_url: str,
    token_mint: str,
    min_amount: Optional[str],
    token_program_id: str,
    include_data_size_filter: bool,
) -> List[WalletSource]:
    """Create a holder snapshot from Solana RPC getProgramAccounts.

    This avoids Solscan Pro, but the RPC provider must allow sufficiently large
    getProgramAccounts requests for the selected token mint.
    """
    filters: List[Dict[str, Any]] = []
    if include_data_size_filter:
        filters.append({"dataSize": 165})
    filters.append({"memcmp": {"offset": 0, "bytes": token_mint}})

    result = rpc_call(
        rpc_url,
        "getProgramAccounts",
        [
            token_program_id,
            {
                "commitment": "finalized",
                "encoding": "jsonParsed",
                "filters": filters,
            },
        ],
        timeout=120,
        retries=3,
    )

    min_amount_decimal = parse_decimal(min_amount, ZERO) or ZERO
    snapshot_time = now_utc_text()
    by_owner: Dict[str, Dict[str, Any]] = {}

    for item in result or []:
        token_account = str(item.get("pubkey") or "").strip()
        account = item.get("account") or {}
        data = account.get("data") or {}
        parsed = data.get("parsed") if isinstance(data, dict) else None
        info = parsed.get("info") if isinstance(parsed, dict) else None
        if not isinstance(info, dict):
            continue

        owner = str(info.get("owner") or "").strip()
        mint = str(info.get("mint") or "").strip()
        if not owner or mint != token_mint:
            continue

        amount = token_amount_from_parsed_info(info)
        if amount <= ZERO:
            continue

        entry = by_owner.setdefault(owner, {"amount": ZERO, "token_accounts": []})
        entry["amount"] += amount
        if token_account:
            entry["token_accounts"].append(token_account)

    sorted_holders = sorted(
        ((owner, data) for owner, data in by_owner.items() if data["amount"] >= min_amount_decimal),
        key=lambda pair: pair[1]["amount"],
        reverse=True,
    )

    wallets: List[WalletSource] = []
    for index, (owner, data) in enumerate(sorted_holders, start=1):
        wallets.append(
            WalletSource(
                wallet_id=f"W{index:06d}",
                wallet=owner,
                source_mint=token_mint,
                source_amount=format_amount(data["amount"]),
                source_rank=str(index),
                source_token_account=",".join(data["token_accounts"]),
                snapshot_time=snapshot_time,
            )
        )

    return wallets


def get_signatures_for_wallet(
    rpc_url: str,
    wallet: str,
    start_ts: int,
    end_ts: int,
    max_pages: int,
    page_limit: int,
) -> List[Dict[str, Any]]:
    signatures: List[Dict[str, Any]] = []
    before: Optional[str] = None

    for _page in range(max_pages):
        config: Dict[str, Any] = {"limit": page_limit, "commitment": "finalized"}
        if before:
            config["before"] = before

        result = rpc_call(rpc_url, "getSignaturesForAddress", [wallet, config])
        if not result:
            break

        oldest_seen: Optional[int] = None
        for item in result:
            block_time = item.get("blockTime")
            if isinstance(block_time, int):
                oldest_seen = block_time if oldest_seen is None else min(oldest_seen, block_time)
                if start_ts <= block_time <= end_ts:
                    signatures.append(item)
            else:
                signatures.append(item)

        before = result[-1].get("signature")
        if oldest_seen is not None and oldest_seen < start_ts:
            break

    signatures.sort(key=lambda x: x.get("blockTime") or 0)
    return signatures


def get_transaction(rpc_url: str, signature: str) -> Optional[Dict[str, Any]]:
    return rpc_call(
        rpc_url,
        "getTransaction",
        [
            signature,
            {
                "encoding": "jsonParsed",
                "commitment": "confirmed",
                "maxSupportedTransactionVersion": 0,
            },
        ],
    )


def get_account_keys(transaction: Dict[str, Any]) -> List[str]:
    keys = transaction.get("transaction", {}).get("message", {}).get("accountKeys", [])
    out: List[str] = []
    for key in keys:
        if isinstance(key, str):
            out.append(key)
        elif isinstance(key, dict):
            pubkey = key.get("pubkey")
            if isinstance(pubkey, str):
                out.append(pubkey)
    return out


def token_amount_from_balance(balance_entry: Dict[str, Any]) -> Decimal:
    amount_info = balance_entry.get("uiTokenAmount") or {}
    raw_amount = amount_info.get("amount")
    decimals = amount_info.get("decimals", 0)
    if raw_amount is not None:
        return Decimal(str(raw_amount)) / (Decimal(10) ** int(decimals))
    ui_amount_string = amount_info.get("uiAmountString")
    return parse_decimal(ui_amount_string, ZERO) or ZERO


def collect_token_balances(meta: Dict[str, Any], wallet: str, side: str) -> Dict[str, Decimal]:
    key = "preTokenBalances" if side == "pre" else "postTokenBalances"
    balances: Dict[str, Decimal] = {}
    for entry in meta.get(key, []) or []:
        if entry.get("owner") != wallet:
            continue
        mint = entry.get("mint")
        if not mint:
            continue
        balances[mint] = balances.get(mint, ZERO) + token_amount_from_balance(entry)
    return balances


def calculate_wallet_deltas(transaction: Dict[str, Any], wallet: str) -> Dict[str, Decimal]:
    meta = transaction.get("meta") or {}
    deltas: Dict[str, Decimal] = {}

    pre_tokens = collect_token_balances(meta, wallet, "pre")
    post_tokens = collect_token_balances(meta, wallet, "post")
    for mint in sorted(set(pre_tokens) | set(post_tokens)):
        delta = post_tokens.get(mint, ZERO) - pre_tokens.get(mint, ZERO)
        if delta != ZERO:
            deltas[mint] = deltas.get(mint, ZERO) + delta

    account_keys = get_account_keys(transaction)
    if wallet in account_keys:
        idx = account_keys.index(wallet)
        pre_balances = meta.get("preBalances") or []
        post_balances = meta.get("postBalances") or []
        if idx < len(pre_balances) and idx < len(post_balances):
            sol_delta = (Decimal(post_balances[idx]) - Decimal(pre_balances[idx])) / LAMPORTS_PER_SOL
            if sol_delta != ZERO:
                deltas[NATIVE_SOL_MINT] = deltas.get(NATIVE_SOL_MINT, ZERO) + sol_delta

    return {mint: amount for mint, amount in deltas.items() if amount != ZERO}


def classify_event(source: WalletSource, signature_info: Dict[str, Any], transaction: Dict[str, Any]) -> Optional[SwapEvent]:
    meta = transaction.get("meta") or {}
    if meta.get("err") is not None:
        return None

    deltas = calculate_wallet_deltas(transaction, source.wallet)
    negatives = {mint: amount for mint, amount in deltas.items() if amount < ZERO}
    positives = {mint: amount for mint, amount in deltas.items() if amount > ZERO}

    if not negatives or not positives:
        return None

    signature = signature_info.get("signature") or transaction.get("transaction", {}).get("signatures", [""])[0]
    return SwapEvent(
        wallet_id=source.wallet_id,
        wallet=source.wallet,
        signature=signature,
        block_time=transaction.get("blockTime") or signature_info.get("blockTime"),
        slot=transaction.get("slot") or signature_info.get("slot"),
        status="SWAP_LIKE",
        negatives=negatives,
        positives=positives,
        solscan_url=f"https://solscan.io/tx/{signature}",
    )


def format_amount(amount: Decimal) -> str:
    normalized = amount.normalize()
    return format(normalized, "f")


def token_name(mint: str, rules: Dict[str, Any]) -> str:
    tokens = rules.get("tokens") or {}
    info = tokens.get(mint) or {}
    symbol = info.get("symbol") or info.get("name")
    if symbol:
        return f"{symbol} ({mint})"
    if mint == NATIVE_SOL_MINT:
        return f"SOL ({mint})"
    return mint


def format_side(amounts: Dict[str, Decimal], rules: Dict[str, Any]) -> str:
    return "; ".join(f"{format_amount(abs(value))} {token_name(mint, rules)}" for mint, value in amounts.items())


def event_matches_rule(event: SwapEvent, rule: Dict[str, Any]) -> Tuple[bool, str]:
    expected_from = rule["from_mint"]
    expected_to = rule["to_mint"]
    from_delta = event.negatives.get(expected_from)
    to_delta = event.positives.get(expected_to)

    if from_delta is None:
        return False, "Expected input token not spent."
    if to_delta is None:
        return False, "Expected output token not received."

    input_amount = abs(from_delta)
    output_amount = to_delta
    min_input = parse_decimal(rule.get("min_input"), None)
    max_input = parse_decimal(rule.get("max_input"), None)
    min_output = parse_decimal(rule.get("min_output"), None)
    max_output = parse_decimal(rule.get("max_output"), None)
    sol_fee_tolerance = parse_decimal(rule.get("sol_fee_tolerance"), Decimal("0.02")) or ZERO

    if min_input is not None and input_amount < min_input:
        return False, f"Input amount too small: {format_amount(input_amount)} < {format_amount(min_input)}."
    if max_input is not None:
        tolerance = sol_fee_tolerance if expected_from == NATIVE_SOL_MINT else ZERO
        if input_amount > max_input + tolerance:
            return False, f"Input amount too large: {format_amount(input_amount)} > {format_amount(max_input)}."
    if min_output is not None and output_amount < min_output:
        return False, f"Output amount too small: {format_amount(output_amount)} < {format_amount(min_output)}."
    if max_output is not None and output_amount > max_output:
        return False, f"Output amount too large: {format_amount(output_amount)} > {format_amount(max_output)}."

    return True, "Expected swap found."


def evaluate_wallet(source: WalletSource, events: List[SwapEvent], rules: Dict[str, Any]) -> List[RuleResult]:
    results: List[RuleResult] = []

    for rule in rules["required_swaps"]:
        rule_name = rule.get("name") or f"{rule['from_mint']} -> {rule['to_mint']}"
        matched_event: Optional[SwapEvent] = None
        match_reason = "No matching swap found."

        for event in events:
            is_match, reason = event_matches_rule(event, rule)
            if is_match:
                matched_event = event
                match_reason = reason
                break
            match_reason = reason

        if matched_event:
            results.append(
                RuleResult(
                    wallet_id=source.wallet_id,
                    wallet=source.wallet,
                    rule_name=rule_name,
                    expected_from=token_name(rule["from_mint"], rules),
                    expected_to=token_name(rule["to_mint"], rules),
                    status="OK",
                    reason=match_reason,
                    signature=matched_event.signature,
                    block_time=unix_to_text(matched_event.block_time),
                    actual_from=format_side(matched_event.negatives, rules),
                    actual_to=format_side(matched_event.positives, rules),
                    solscan_url=matched_event.solscan_url,
                )
            )
        else:
            if events:
                first_event = events[0]
                status = "WRONG_SWAP"
                actual_from = format_side(first_event.negatives, rules)
                actual_to = format_side(first_event.positives, rules)
                signature = first_event.signature
                block_time = unix_to_text(first_event.block_time)
                solscan_url = first_event.solscan_url
                reason = f"Swap-like transaction found, but it does not match the rule. Last mismatch: {match_reason}"
            else:
                status = "MISSING"
                actual_from = ""
                actual_to = ""
                signature = ""
                block_time = ""
                solscan_url = ""
                reason = "No swap-like transaction found in the configured time window."

            results.append(
                RuleResult(
                    wallet_id=source.wallet_id,
                    wallet=source.wallet,
                    rule_name=rule_name,
                    expected_from=token_name(rule["from_mint"], rules),
                    expected_to=token_name(rule["to_mint"], rules),
                    status=status,
                    reason=reason,
                    signature=signature,
                    block_time=block_time,
                    actual_from=actual_from,
                    actual_to=actual_to,
                    solscan_url=solscan_url,
                )
            )

    return results


def write_public_results_csv(path: Path, rows: List[RuleResult]) -> None:
    fieldnames = [
        "wallet_id",
        "rule_name",
        "expected_from",
        "expected_to",
        "status",
        "reason",
        "block_time",
        "actual_from",
        "actual_to",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: getattr(row, field) for field in fieldnames})


def write_private_results_csv(path: Path, rows: List[RuleResult]) -> None:
    fieldnames = [
        "wallet_id",
        "wallet",
        "rule_name",
        "expected_from",
        "expected_to",
        "status",
        "reason",
        "signature",
        "block_time",
        "actual_from",
        "actual_to",
        "solscan_url",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: getattr(row, field) for field in fieldnames})


def write_private_events_csv(path: Path, events: List[SwapEvent], rules: Dict[str, Any]) -> None:
    fieldnames = [
        "wallet_id",
        "wallet",
        "signature",
        "block_time",
        "slot",
        "actual_from",
        "actual_to",
        "solscan_url",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for event in events:
            writer.writerow(
                {
                    "wallet_id": event.wallet_id,
                    "wallet": event.wallet,
                    "signature": event.signature,
                    "block_time": unix_to_text(event.block_time),
                    "slot": event.slot or "",
                    "actual_from": format_side(event.negatives, rules),
                    "actual_to": format_side(event.positives, rules),
                    "solscan_url": event.solscan_url,
                }
            )


def write_public_html_report(path: Path, rows: List[RuleResult], rules: Dict[str, Any], include_links: bool) -> None:
    training_name = html.escape(str(rules.get("training_name", "Solana Swap Training")))
    generated = html.escape(now_utc_text())

    ok_count = sum(1 for row in rows if row.status == "OK")
    wrong_count = sum(1 for row in rows if row.status == "WRONG_SWAP")
    missing_count = sum(1 for row in rows if row.status == "MISSING")

    def td(value: Any) -> str:
        return f"<td>{html.escape(str(value or ''))}</td>"

    body_rows = []
    for row in rows:
        tx_link_cell = ""
        if include_links and row.solscan_url:
            tx_link_cell = f'<td><a href="{html.escape(row.solscan_url)}">Solscan</a></td>'
        body_rows.append(
            "<tr>"
            + td(row.wallet_id)
            + td(row.rule_name)
            + td(row.status)
            + td(row.expected_from)
            + td(row.expected_to)
            + td(row.actual_from)
            + td(row.actual_to)
            + td(row.reason)
            + tx_link_cell
            + "</tr>"
        )

    link_header = "<th>Transaction</th>" if include_links else ""
    html_content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{training_name}</title>
  <style>
    body {{ font-family: system-ui, -apple-system, Segoe UI, sans-serif; margin: 2rem; }}
    table {{ border-collapse: collapse; width: 100%; font-size: 0.9rem; }}
    th, td {{ border: 1px solid #ddd; padding: 0.5rem; vertical-align: top; }}
    th {{ background: #f2f2f2; text-align: left; }}
    .summary {{ display: flex; gap: 1rem; margin: 1rem 0; }}
    .box {{ border: 1px solid #ddd; border-radius: 0.5rem; padding: 1rem; }}
    .privacy {{ background: #fafafa; border: 1px solid #ddd; padding: 1rem; border-radius: 0.5rem; }}
  </style>
</head>
<body>
  <h1>{training_name}</h1>
  <p>Generated: {generated}</p>
  <div class="privacy">
    This public report intentionally contains no participant names and no wallet addresses.
  </div>
  <div class="summary">
    <div class="box"><strong>OK</strong><br>{ok_count}</div>
    <div class="box"><strong>Wrong swap</strong><br>{wrong_count}</div>
    <div class="box"><strong>Missing</strong><br>{missing_count}</div>
  </div>
  <table>
    <thead>
      <tr>
        <th>Wallet ID</th>
        <th>Rule</th>
        <th>Status</th>
        <th>Expected From</th>
        <th>Expected To</th>
        <th>Actual From</th>
        <th>Actual To</th>
        <th>Reason</th>
        {link_header}
      </tr>
    </thead>
    <tbody>
      {''.join(body_rows)}
    </tbody>
  </table>
</body>
</html>
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html_content, encoding="utf-8")


def command_snapshot_holders(args: argparse.Namespace) -> int:
    api_key = args.solscan_api_key or os.environ.get("SOLSCAN_API_KEY")
    if not api_key:
        raise ValueError("Solscan Pro API key required. Use --solscan-api-key or environment variable SOLSCAN_API_KEY.")
    if args.page_size not in (10, 20, 30, 40):
        raise ValueError("Solscan token holder endpoint supports page sizes 10, 20, 30, or 40.")

    wallets = snapshot_holders_solscan(
        api_base_url=args.solscan_api_url,
        api_key=api_key,
        token_mint=args.source_token_mint,
        min_amount=args.min_amount,
        max_pages=args.max_pages,
        page_size=args.page_size,
    )
    if not wallets:
        raise ValueError("No token holders found. Check mint address, minimum amount, and API access.")

    output = Path(args.output)
    write_wallet_sources(output, wallets)
    print(f"Wrote anonymous holder snapshot: {output} ({len(wallets)} wallets)", file=sys.stderr)
    return 0


def command_snapshot_holders_rpc(args: argparse.Namespace) -> int:
    wallets = snapshot_holders_rpc(
        rpc_url=args.rpc_url,
        token_mint=args.source_token_mint,
        min_amount=args.min_amount,
        token_program_id=args.token_program_id,
        include_data_size_filter=not args.no_data_size_filter,
    )
    if not wallets:
        raise ValueError("No token holders found. Check mint address, token program, minimum amount, and RPC access.")

    output = Path(args.output)
    write_wallet_sources(output, wallets)
    print(f"Wrote anonymous holder snapshot via RPC: {output} ({len(wallets)} wallets)", file=sys.stderr)
    return 0


def command_analyze(args: argparse.Namespace) -> int:
    wallet_sources = read_wallet_sources(Path(args.wallets))
    rules = read_rules(Path(args.rules))
    start_ts = int(parse_iso_datetime(rules["start_time"]).timestamp())
    end_ts = int(parse_iso_datetime(rules["end_time"]).timestamp())
    if end_ts <= start_ts:
        raise ValueError("end_time must be later than start_time.")

    all_events: List[SwapEvent] = []
    all_results: List[RuleResult] = []

    for source in wallet_sources:
        print(f"Analyzing {source.wallet_id} ...", file=sys.stderr)
        signatures = get_signatures_for_wallet(
            args.rpc_url,
            source.wallet,
            start_ts,
            end_ts,
            max_pages=args.max_pages,
            page_limit=args.page_limit,
        )

        wallet_events: List[SwapEvent] = []
        for signature_info in signatures:
            signature = signature_info.get("signature")
            if not signature:
                continue
            tx = get_transaction(args.rpc_url, signature)
            if not tx:
                continue
            event = classify_event(source, signature_info, tx)
            if event:
                wallet_events.append(event)

        all_events.extend(wallet_events)
        all_results.extend(evaluate_wallet(source, wallet_events, rules))

    public_output = Path(args.public_output)
    write_public_results_csv(public_output, all_results)

    if args.private_output:
        write_private_results_csv(Path(args.private_output), all_results)
    if args.events_output:
        write_private_events_csv(Path(args.events_output), all_events, rules)
    if args.html_output:
        write_public_html_report(Path(args.html_output), all_results, rules, args.include_evidence_links_in_public_report)

    print(f"Wrote public result CSV: {public_output}", file=sys.stderr)
    if args.private_output:
        print(f"Wrote private evidence CSV: {args.private_output}", file=sys.stderr)
    if args.events_output:
        print(f"Wrote private event CSV: {args.events_output}", file=sys.stderr)
    if args.html_output:
        print(f"Wrote public HTML report: {args.html_output}", file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Privacy-preserving Solana swap training tracker.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot-holders", help="Create an anonymous CSV source from current holders of a token mint.")
    snapshot.add_argument("--source-token-mint", required=True, help="Token X mint address used to select eligible wallets")
    snapshot.add_argument("--output", default="holder_snapshot.csv", help="Anonymous holder snapshot CSV path")
    snapshot.add_argument("--solscan-api-key", default="", help="Solscan Pro API key; alternatively set SOLSCAN_API_KEY")
    snapshot.add_argument("--solscan-api-url", default=DEFAULT_SOLSCAN_API_URL, help="Solscan Pro API base URL")
    snapshot.add_argument("--min-amount", default="0", help="Minimum Token X holding amount for inclusion")
    snapshot.add_argument("--max-pages", type=int, default=25, help="Maximum holder pages to fetch")
    snapshot.add_argument("--page-size", type=int, default=40, help="Holder page size: 10, 20, 30, or 40")
    snapshot.set_defaults(func=command_snapshot_holders)

    snapshot_rpc = subparsers.add_parser("snapshot-holders-rpc", help="Create an anonymous CSV source from current holders of a token mint using Solana RPC only.")
    snapshot_rpc.add_argument("--source-token-mint", required=True, help="Token X mint address used to select eligible wallets")
    snapshot_rpc.add_argument("--output", default="holder_snapshot.csv", help="Anonymous holder snapshot CSV path")
    snapshot_rpc.add_argument("--rpc-url", default=DEFAULT_RPC_URL, help="Solana JSON-RPC endpoint")
    snapshot_rpc.add_argument("--token-program-id", default=SPL_TOKEN_PROGRAM_ID, help="SPL token program ID. Use Token-2022 program ID for Token-2022 mints.")
    snapshot_rpc.add_argument("--min-amount", default="0", help="Minimum Token X holding amount for inclusion")
    snapshot_rpc.add_argument("--no-data-size-filter", action="store_true", help="Disable the dataSize=165 filter, useful for some Token-2022 extension accounts")
    snapshot_rpc.set_defaults(func=command_snapshot_holders_rpc)

    analyze = subparsers.add_parser("analyze", help="Analyze anonymous wallets against swap training rules.")
    analyze.add_argument("--wallets", required=True, help="Anonymous wallet source CSV from snapshot-holders or a manually prepared wallet CSV")
    analyze.add_argument("--rules", required=True, help="JSON training rules file")
    analyze.add_argument("--public-output", default="swap_training_public_results.csv", help="Public pseudonymous result CSV path")
    analyze.add_argument("--private-output", default="swap_training_private_evidence.csv", help="Private CSV with wallet addresses and transaction evidence; pass empty string to disable")
    analyze.add_argument("--events-output", default="swap_training_private_events.csv", help="Private CSV with all swap-like events; pass empty string to disable")
    analyze.add_argument("--html-output", default="swap_training_public_report.html", help="Public HTML report path; pass empty string to disable")
    analyze.add_argument("--include-evidence-links-in-public-report", action="store_true", help="Include Solscan transaction links in the public HTML report")
    analyze.add_argument("--rpc-url", default=DEFAULT_RPC_URL, help="Solana JSON-RPC endpoint")
    analyze.add_argument("--max-pages", type=int, default=5, help="Maximum signature pages per wallet")
    analyze.add_argument("--page-limit", type=int, default=1000, help="Signatures per RPC page")
    analyze.set_defaults(func=command_analyze)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - command line tool should show readable errors
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
