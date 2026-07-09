#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# File Name     : solana_swap_training_tracker_v0.4.3.py
# Version       : v0.4.3
# Created       : 2026-06-30
# Last Modified : 2026-06-30
# Author        : Alice Endelgard / Nouramon Alvestrasza
# Organization  : Alvestrasza Corporation
# Description   : Privacy-preserving Solana token-history based swap training analyzer. Adds Solscan Amount/TokenDecimals normalization for CSV prefiltering.

"""
Solana Swap Training Tracker v0.4.3

This version is optimized for large training groups.

Instead of scanning every wallet history, it expects a token-history CSV that
contains transaction signatures for the token and time window to analyze. For
those candidate transactions only, it loads the Solana transaction details via
JSON-RPC and calculates wallet-level Token/SOL deltas. Version v0.4.3 adds Solscan Amount/TokenDecimals normalization so CSV prefiltering uses human token/SOL amounts instead of raw base units.

No private keys are required. Names are never required. Public reports use
wallet_id values only.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

NATIVE_SOL_MINT = "So11111111111111111111111111111111111111112"
LAMPORTS_PER_SOL = Decimal("1000000000")
ZERO = Decimal("0")
DEFAULT_RPC_URL = "https://api.mainnet-beta.solana.com"


class RpcError(RuntimeError):
    """Raised when the Solana RPC endpoint returns an error."""


@dataclass
class RateLimiter:
    """Simple request pacing helper for public RPC/API endpoints."""

    calls: int = 0
    wait_seconds: float = 0.0
    counter: int = 0

    def wait_if_needed(self) -> None:
        if self.calls <= 0 or self.wait_seconds <= 0:
            return
        if self.counter > 0 and self.counter % self.calls == 0:
            print(
                f"Rate limit: waiting {self.wait_seconds:g}s after {self.counter} requests ...",
                file=sys.stderr,
            )
            time.sleep(self.wait_seconds)
        self.counter += 1


@dataclass
class WalletSource:
    wallet_id: str
    wallet: str


@dataclass
class TokenHistorySignature:
    signature: str
    source_block_time: Optional[int] = None
    human_time: str = ""
    action: str = ""
    from_wallet: str = ""
    token1: str = ""
    amount1: Optional[Decimal] = None
    token_decimals1: Optional[int] = None
    token2: str = ""
    amount2: Optional[Decimal] = None
    token_decimals2: Optional[int] = None
    value: Optional[Decimal] = None



@dataclass
class TokenTrade:
    wallet_id: str
    wallet: str
    signature: str
    block_time: Optional[int]
    slot: Optional[int]
    direction: str
    token_delta: Decimal
    quote_delta: Decimal
    token_amount: Decimal
    quote_amount: Decimal
    solscan_url: str


@dataclass
class StepResult:
    wallet_id: str
    wallet: str
    step_name: str
    expected_direction: str
    status: str
    reason: str
    actual_direction: str = ""
    signature: str = ""
    block_time: str = ""
    token_amount: str = ""
    quote_amount: str = ""
    solscan_url: str = ""


def parse_decimal(value: Any, default: Optional[Decimal] = None) -> Optional[Decimal]:
    if value is None or value == "":
        return default
    text = str(value).strip()
    if not text:
        return default
    # Solscan and spreadsheet exports may contain currency symbols, spaces,
    # or thousands separators. Keep decimal dots intact and strip grouping.
    text = text.replace("$", "").replace("€", "").replace("SOL", "").replace("sol", "").strip()
    text = text.replace(" ", "")
    if "," in text and "." in text:
        text = text.replace(",", "")
    elif "," in text and "." not in text:
        # Be conservative: if this looks like a decimal comma, normalize it.
        if re.fullmatch(r"-?\d+,\d+", text):
            text = text.replace(",", ".")
        else:
            text = text.replace(",", "")
    try:
        return Decimal(text)
    except (InvalidOperation, ValueError) as exc:
        raise ValueError(f"Invalid decimal value: {value!r}") from exc


def format_amount(amount: Decimal) -> str:
    normalized = amount.normalize()
    text = format(normalized, "f")
    return "0" if text == "-0" else text


def parse_tz_offset(value: str) -> timezone:
    value = (value or "+00:00").strip()
    if value.upper() == "UTC" or value == "Z":
        return timezone.utc
    match = re.fullmatch(r"([+-])(\d{2}):(\d{2})", value)
    if not match:
        raise ValueError("Timezone offset must be UTC, Z, or in format +HH:MM / -HH:MM.")
    sign = 1 if match.group(1) == "+" else -1
    hours = int(match.group(2))
    minutes = int(match.group(3))
    return timezone(sign * timedelta(hours=hours, minutes=minutes))


def parse_datetime_to_ts(value: str, naive_tz: timezone = timezone.utc) -> int:
    text = str(value).strip()
    if not text:
        raise ValueError("Empty datetime value.")
    if re.fullmatch(r"\d{10}", text):
        return int(text)
    if re.fullmatch(r"\d{13}", text):
        return int(int(text) / 1000)
    normalized = text.replace("Z", "+00:00")
    # Solscan exports sometimes use a blank separator instead of T.
    if " " in normalized and "T" not in normalized:
        normalized = normalized.replace(" ", "T", 1)
    dt = datetime.fromisoformat(normalized)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=naive_tz)
    return int(dt.astimezone(timezone.utc).timestamp())


def unix_to_text(ts: Optional[int]) -> str:
    if ts is None:
        return ""
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def now_utc_text() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalize_column_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", (value or "").strip().lower()).strip("_")


def extract_solana_signature(value: str) -> str:
    """Extract a Solana transaction signature from plain cells, URLs, or spreadsheet formulas."""
    text = (value or "").strip()
    if not text:
        return ""

    # Solscan exports are usually plain signatures, but spreadsheet tools may
    # turn them into formulas or hyperlinks. A Solana signature is base58 and is
    # commonly around 86-88 chars long. Use a broad but safe range here.
    base58_chars = r"[1-9A-HJ-NP-Za-km-z]"
    matches = re.findall(rf"(?<!{base58_chars})({base58_chars}{{80,100}})(?!{base58_chars})", text)
    if matches:
        # If a URL/formula contains multiple base58-looking strings, the longest
        # one is normally the transaction signature.
        return max(matches, key=len)

    # Fallback for non-standard exports that already contain only the signature
    # but may have been quoted or surrounded by whitespace.
    cleaned = text.strip().strip('"').strip("'")
    if re.fullmatch(rf"{base58_chars}{{40,120}}", cleaned):
        return cleaned
    return ""


def detect_csv_delimiter(sample: str) -> str:
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=";,\t,")
        return dialect.delimiter
    except csv.Error:
        first_line = sample.splitlines()[0] if sample.splitlines() else ""
        counts = {";": first_line.count(";"), ",": first_line.count(","), "\t": first_line.count("\t")}
        return max(counts, key=counts.get) if max(counts.values()) > 0 else ","


def read_csv_rows(path: Path) -> Tuple[List[Dict[str, str]], Dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(8192)
        handle.seek(0)
        delimiter = detect_csv_delimiter(sample)
        reader = csv.DictReader(handle, delimiter=delimiter)
        if not reader.fieldnames:
            raise ValueError(f"CSV has no header: {path}")
        normalized_map = {normalize_column_name(field): field for field in reader.fieldnames}
        rows = [{key: value or "" for key, value in row.items()} for row in reader]
        return rows, normalized_map


def get_by_alias(row: Dict[str, str], normalized_map: Dict[str, str], aliases: Iterable[str]) -> str:
    for alias in aliases:
        normalized = normalize_column_name(alias)
        original = normalized_map.get(normalized)
        if original is not None:
            return (row.get(original) or "").strip()
    return ""


def read_wallet_sources(path: Path) -> List[WalletSource]:
    rows, normalized_map = read_csv_rows(path)
    wallet_aliases = ["wallet", "owner", "address", "wallet_address", "holder", "account"]
    id_aliases = ["wallet_id", "id", "participant_id", "alias"]

    wallets: List[WalletSource] = []
    seen: set[str] = set()
    for index, row in enumerate(rows, start=1):
        wallet = get_by_alias(row, normalized_map, wallet_aliases)
        if not wallet or wallet in seen:
            continue
        seen.add(wallet)
        wallet_id = get_by_alias(row, normalized_map, id_aliases) or f"W{index:06d}"
        wallets.append(WalletSource(wallet_id=wallet_id, wallet=wallet))

    if not wallets:
        detected = ", ".join(normalized_map.values())
        raise ValueError(f"No wallets found. CSV must contain a wallet column. Detected columns: {detected}")
    return wallets


def parse_optional_decimal(value: str) -> Optional[Decimal]:
    try:
        return parse_decimal(value, None)
    except ValueError:
        return None


def parse_optional_int(value: str) -> Optional[int]:
    text = (value or "").strip()
    if not text:
        return None
    try:
        # Some spreadsheet tools may render integer columns as "9.0".
        return int(Decimal(text))
    except (InvalidOperation, ValueError):
        return None


def normalize_csv_token_amount(
    amount_value: str,
    decimals_value: str = "",
    mode: str = "auto",
) -> Optional[Decimal]:
    """Normalize Solscan Amount/TokenDecimals columns to human units.

    Solscan token-history CSV exports commonly store Amount1/Amount2 in raw base
    units and provide TokenDecimals1/TokenDecimals2 separately. For example:
    30000000 with decimals 9 means 0.03 SOL, not 30000000 SOL.

    mode:
      - auto: divide by 10^decimals when a TokenDecimals column is present
      - raw: always divide by 10^decimals when decimals can be parsed
      - ui: treat Amount columns as already human-readable
    """
    amount = parse_optional_decimal(amount_value)
    if amount is None:
        return None
    normalized_mode = (mode or "auto").lower().strip()
    if normalized_mode not in {"auto", "raw", "ui"}:
        raise ValueError("--csv-amount-mode must be auto, raw, or ui.")
    if normalized_mode == "ui":
        return amount

    decimals = parse_optional_int(decimals_value)
    if decimals is None:
        return amount
    if decimals < 0 or decimals > 30:
        return amount

    # In Solscan exports with TokenDecimals columns present, Amount is normally
    # raw base units. auto intentionally follows that convention.
    return amount / (Decimal(10) ** decimals)


def read_token_history_signatures(
    path: Path,
    start_ts: int,
    end_ts: int,
    naive_tz: timezone,
    disable_time_prefilter: bool = False,
    debug_csv: bool = False,
    csv_amount_mode: str = "auto",
) -> List[TokenHistorySignature]:
    rows, normalized_map = read_csv_rows(path)
    signature_aliases = [
        "signature", "tx", "tx_hash", "txhash", "transaction", "transaction_hash", "trans_id", "hash",
        "signature_hash", "transaction signature", "transaction_signature",
    ]
    time_aliases = ["block_time", "time", "date", "timestamp", "block time", "datetime"]
    human_time_aliases = ["human_time", "human time", "human_date", "human date"]
    action_aliases = ["action", "activity", "type"]
    from_aliases = ["from", "signer", "wallet", "owner", "user", "authority"]
    token1_aliases = ["token1", "token_1", "input_token", "token_in"]
    token2_aliases = ["token2", "token_2", "output_token", "token_out"]
    amount1_aliases = ["amount1", "amount_1", "input_amount", "amount_in"]
    amount2_aliases = ["amount2", "amount_2", "output_amount", "amount_out"]
    token_decimals1_aliases = ["tokendecimals1", "token_decimals1", "token_decimals_1", "decimals1", "decimals_1"]
    token_decimals2_aliases = ["tokendecimals2", "token_decimals2", "token_decimals_2", "decimals2", "decimals_2"]
    value_aliases = ["value", "usd_value", "amount_usd", "value_usd"]

    signature_column = ""
    for alias in signature_aliases:
        original = normalized_map.get(normalize_column_name(alias))
        if original is not None:
            signature_column = original
            break

    signatures: List[TokenHistorySignature] = []
    seen: set[str] = set()
    total_rows = 0
    non_empty_signature_cells = 0
    parsed_signature_cells = 0
    time_filtered_rows = 0
    time_parse_failed_rows = 0

    for row in rows:
        total_rows += 1
        raw_signature = get_by_alias(row, normalized_map, signature_aliases)
        if raw_signature:
            non_empty_signature_cells += 1
        signature = extract_solana_signature(raw_signature)
        if not signature:
            continue
        parsed_signature_cells += 1
        if signature in seen:
            continue
        source_ts: Optional[int] = None
        time_value = get_by_alias(row, normalized_map, time_aliases)
        human_time = get_by_alias(row, normalized_map, human_time_aliases)
        if time_value:
            try:
                source_ts = parse_datetime_to_ts(time_value, naive_tz)
            except Exception:
                time_parse_failed_rows += 1
                source_ts = None
        if source_ts is None and human_time:
            try:
                source_ts = parse_datetime_to_ts(human_time, naive_tz)
            except Exception:
                time_parse_failed_rows += 1
                source_ts = None

        # If the CSV has a usable timestamp, pre-filter it unless disabled. If
        # disabled or no timestamp exists, the on-chain block_time filter still
        # runs after getTransaction.
        if not disable_time_prefilter and source_ts is not None and not (start_ts <= source_ts <= end_ts):
            time_filtered_rows += 1
            continue

        seen.add(signature)
        signatures.append(
            TokenHistorySignature(
                signature=signature,
                source_block_time=source_ts,
                human_time=human_time,
                action=get_by_alias(row, normalized_map, action_aliases),
                from_wallet=get_by_alias(row, normalized_map, from_aliases),
                token1=get_by_alias(row, normalized_map, token1_aliases),
                amount1=normalize_csv_token_amount(
                    get_by_alias(row, normalized_map, amount1_aliases),
                    get_by_alias(row, normalized_map, token_decimals1_aliases),
                    csv_amount_mode,
                ),
                token_decimals1=parse_optional_int(get_by_alias(row, normalized_map, token_decimals1_aliases)),
                token2=get_by_alias(row, normalized_map, token2_aliases),
                amount2=normalize_csv_token_amount(
                    get_by_alias(row, normalized_map, amount2_aliases),
                    get_by_alias(row, normalized_map, token_decimals2_aliases),
                    csv_amount_mode,
                ),
                token_decimals2=parse_optional_int(get_by_alias(row, normalized_map, token_decimals2_aliases)),
                value=parse_optional_decimal(get_by_alias(row, normalized_map, value_aliases)),
            )
        )

    if debug_csv or not signatures:
        print(
            "Token-history CSV diagnostics: "
            f"rows={total_rows}, "
            f"signature_column={signature_column or '<not detected>'}, "
            f"non_empty_signature_cells={non_empty_signature_cells}, "
            f"parsed_signature_cells={parsed_signature_cells}, "
            f"time_filtered_rows={time_filtered_rows}, "
            f"time_parse_failed_rows={time_parse_failed_rows}, "
            f"accepted_signatures={len(signatures)}, "
            f"csv_amount_mode={csv_amount_mode}.",
            file=sys.stderr,
        )

    if not signatures:
        detected = ", ".join(normalized_map.values())
        if parsed_signature_cells and time_filtered_rows == parsed_signature_cells:
            raise ValueError(
                "Token history CSV contains signatures, but all of them were filtered out by the CSV time window. "
                "Check rules.start_time/rules.end_time and --history-timezone-offset, or retry with "
                "--disable-history-time-prefilter. "
                f"Detected columns: {detected}."
            )
        if signature_column and non_empty_signature_cells and parsed_signature_cells == 0:
            raise ValueError(
                "A signature column was found, but the values do not look like Solana transaction signatures. "
                "If Solscan exported links or formulas, export as plain CSV or provide the raw Signature column. "
                f"Detected columns: {detected}."
            )
        raise ValueError(
            "No transaction signatures found in token history CSV. "
            f"Detected columns: {detected}. Expected a column like Signature, signature, tx_hash, trans_id, or hash."
        )
    return signatures

def label_matches_token(label: str, mint: str, symbol: str = "") -> bool:
    text = (label or "").strip().lower()
    if not text:
        return False
    mint_text = str(mint or "").strip().lower()
    symbol_text = str(symbol or "").strip().lower()
    values = {mint_text, symbol_text}
    if mint == NATIVE_SOL_MINT:
        values.update({"sol", "wsol", "wrapped sol", "wrapped solana", "solana"})
    values = {value for value in values if value}
    if text in values:
        return True
    # Solscan exports may contain labels like "TOKENX (mint...)". Allow
    # mint substring matches and symbol word-boundary matches, but avoid overly
    # broad accidental matches for very short symbols.
    if mint_text and mint_text in text:
        return True
    if symbol_text and len(symbol_text) >= 3:
        return re.search(rf"(^|[^a-z0-9]){re.escape(symbol_text)}([^a-z0-9]|$)", text) is not None
    return False


def infer_csv_trade(item: TokenHistorySignature, rules: Dict[str, Any]) -> Optional[Tuple[str, Decimal, Decimal]]:
    """Infer direction, token amount and quote amount from Solscan Token1/Token2 columns.

    Returns None if the row is ambiguous. The on-chain transaction check remains
    the source of truth; this is only used to reduce candidate RPC calls.
    """
    token_mint = str(rules.get("token_mint", ""))
    token_symbol = str(rules.get("token_symbol", ""))
    quote_mint = str(rules.get("quote_mint", ""))
    quote_symbol = str(rules.get("quote_symbol", ""))

    t1_is_token = label_matches_token(item.token1, token_mint, token_symbol)
    t2_is_token = label_matches_token(item.token2, token_mint, token_symbol)
    t1_is_quote = label_matches_token(item.token1, quote_mint, quote_symbol)
    t2_is_quote = label_matches_token(item.token2, quote_mint, quote_symbol)

    if t1_is_quote and t2_is_token and item.amount1 is not None and item.amount2 is not None:
        return "buy", abs(item.amount2), abs(item.amount1)
    if t1_is_token and t2_is_quote and item.amount1 is not None and item.amount2 is not None:
        return "sell", abs(item.amount1), abs(item.amount2)
    return None


def row_amount_may_match_step(direction: str, token_amount: Decimal, quote_amount: Decimal, step: Dict[str, Any]) -> bool:
    # Direction is intentionally not checked here. Wrong-direction trades with
    # matching value ranges must remain in scope so they can be reported.
    basis = amount_basis_for_step(step)
    value = quote_amount if basis == "quote" else token_amount
    min_value, max_value, tolerance = range_for_step(step, basis)
    if min_value is not None and value < min_value:
        return False
    if max_value is not None and value > max_value + tolerance:
        return False
    return True


def row_may_belong_to_any_step(
    item: TokenHistorySignature,
    rules: Dict[str, Any],
    global_start: int,
    global_end: int,
    naive_tz: timezone,
) -> bool:
    inferred = infer_csv_trade(item, rules)
    if inferred is None:
        # Keep ambiguous rows; the RPC transaction details will decide.
        return True
    direction, token_amount, quote_amount = inferred
    for step in rules["steps"]:
        start, end = step_time_window(step, global_start, global_end, naive_tz)
        if item.source_block_time is not None and not (start <= item.source_block_time <= end):
            continue
        if row_amount_may_match_step(direction, token_amount, quote_amount, step):
            return True
    return False


def prefilter_token_history_rows(
    history_signatures: List[TokenHistorySignature],
    wallet_sources: List[WalletSource],
    rules: Dict[str, Any],
    global_start: int,
    global_end: int,
    naive_tz: timezone,
    from_wallet_prefilter: str,
    csv_step_prefilter: bool,
) -> List[TokenHistorySignature]:
    original_count = len(history_signatures)
    filtered = list(history_signatures)

    mode = (from_wallet_prefilter or "auto").lower().strip()
    if mode not in {"auto", "on", "off"}:
        raise ValueError("--from-wallet-prefilter must be auto, on, or off.")

    allowed_wallets = {source.wallet for source in wallet_sources}
    rows_with_from = [item for item in filtered if item.from_wallet]
    matching_from = [item for item in rows_with_from if item.from_wallet in allowed_wallets]

    if mode == "on":
        filtered = matching_from
        print(f"From-wallet prefilter: {original_count} -> {len(filtered)} rows.", file=sys.stderr)
    elif mode == "auto" and rows_with_from and matching_from:
        no_from_rows = [item for item in filtered if not item.from_wallet]
        filtered = matching_from + no_from_rows
        print(f"From-wallet prefilter auto: {original_count} -> {len(filtered)} rows.", file=sys.stderr)
    elif mode == "auto" and rows_with_from and not matching_from:
        print("From-wallet prefilter auto: no overlap with wallet list detected; keeping all rows.", file=sys.stderr)

    before_step_filter = len(filtered)
    if csv_step_prefilter:
        filtered = [
            item for item in filtered
            if row_may_belong_to_any_step(item, rules, global_start, global_end, naive_tz)
        ]
        print(f"CSV step/value prefilter: {before_step_filter} -> {len(filtered)} rows.", file=sys.stderr)

    if not filtered:
        print("WARNING: token-history prefilter produced zero rows. Disable prefilters if this is unexpected.", file=sys.stderr)
    return filtered


def rpc_call(
    rpc_url: str,
    method: str,
    params: List[Any],
    timeout: int = 30,
    retries: int = 3,
    rate_limiter: Optional[RateLimiter] = None,
) -> Any:
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
            if rate_limiter:
                rate_limiter.wait_if_needed()
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = json.loads(response.read().decode("utf-8"))
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


def get_transaction(rpc_url: str, signature: str, rate_limiter: Optional[RateLimiter] = None) -> Optional[Dict[str, Any]]:
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
        timeout=45,
        retries=3,
        rate_limiter=rate_limiter,
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


def collect_all_token_balances(meta: Dict[str, Any], side: str) -> Dict[str, Dict[str, Decimal]]:
    key = "preTokenBalances" if side == "pre" else "postTokenBalances"
    balances: Dict[str, Dict[str, Decimal]] = {}
    for entry in meta.get(key, []) or []:
        owner = entry.get("owner")
        mint = entry.get("mint")
        if not owner or not mint:
            continue
        balances.setdefault(owner, {})[mint] = balances.setdefault(owner, {}).get(mint, ZERO) + token_amount_from_balance(entry)
    return balances


def collect_all_token_deltas(transaction: Dict[str, Any]) -> Dict[str, Dict[str, Decimal]]:
    meta = transaction.get("meta") or {}
    pre = collect_all_token_balances(meta, "pre")
    post = collect_all_token_balances(meta, "post")
    owners = set(pre) | set(post)
    result: Dict[str, Dict[str, Decimal]] = {}
    for owner in owners:
        mints = set(pre.get(owner, {})) | set(post.get(owner, {}))
        for mint in mints:
            delta = post.get(owner, {}).get(mint, ZERO) - pre.get(owner, {}).get(mint, ZERO)
            if delta != ZERO:
                result.setdefault(owner, {})[mint] = delta
    return result


def collect_native_sol_deltas(transaction: Dict[str, Any]) -> Dict[str, Decimal]:
    meta = transaction.get("meta") or {}
    account_keys = get_account_keys(transaction)
    pre_balances = meta.get("preBalances") or []
    post_balances = meta.get("postBalances") or []
    result: Dict[str, Decimal] = {}
    for index, key in enumerate(account_keys):
        if index >= len(pre_balances) or index >= len(post_balances):
            continue
        delta = (Decimal(post_balances[index]) - Decimal(pre_balances[index])) / LAMPORTS_PER_SOL
        if delta != ZERO:
            result[key] = delta
    return result


def quote_delta_for_wallet(
    wallet: str,
    quote_mint: str,
    token_deltas: Dict[str, Dict[str, Decimal]],
    native_deltas: Dict[str, Decimal],
) -> Decimal:
    token_quote_delta = token_deltas.get(wallet, {}).get(quote_mint, ZERO)
    if quote_mint == NATIVE_SOL_MINT:
        # Include both native SOL balance change and possible temporary wSOL
        # token-balance changes owned by the same wallet.
        return native_deltas.get(wallet, ZERO) + token_quote_delta
    return token_quote_delta


def load_trades_from_token_history(
    rpc_url: str,
    history_signatures: List[TokenHistorySignature],
    wallet_sources: List[WalletSource],
    token_mint: str,
    quote_mint: str,
    start_ts: int,
    end_ts: int,
    rate_limiter: Optional[RateLimiter],
) -> List[TokenTrade]:
    wallet_id_by_address = {source.wallet: source.wallet_id for source in wallet_sources}
    allowed_wallets = set(wallet_id_by_address)
    trades: List[TokenTrade] = []

    for index, item in enumerate(history_signatures, start=1):
        print(f"Loading transaction {index}/{len(history_signatures)} ...", file=sys.stderr)
        tx = get_transaction(rpc_url, item.signature, rate_limiter=rate_limiter)
        if not tx:
            continue
        meta = tx.get("meta") or {}
        if meta.get("err") is not None:
            continue
        block_time = tx.get("blockTime") or item.source_block_time
        if isinstance(block_time, int) and not (start_ts <= block_time <= end_ts):
            continue

        token_deltas = collect_all_token_deltas(tx)
        native_deltas = collect_native_sol_deltas(tx)
        candidate_wallets = allowed_wallets & set(token_deltas.keys())

        for wallet in sorted(candidate_wallets):
            token_delta = token_deltas.get(wallet, {}).get(token_mint, ZERO)
            if token_delta == ZERO:
                continue
            q_delta = quote_delta_for_wallet(wallet, quote_mint, token_deltas, native_deltas)
            direction = "buy" if token_delta > ZERO else "sell"
            token_amount = abs(token_delta)
            quote_amount = abs(q_delta)
            trades.append(
                TokenTrade(
                    wallet_id=wallet_id_by_address[wallet],
                    wallet=wallet,
                    signature=item.signature,
                    block_time=block_time if isinstance(block_time, int) else None,
                    slot=tx.get("slot"),
                    direction=direction,
                    token_delta=token_delta,
                    quote_delta=q_delta,
                    token_amount=token_amount,
                    quote_amount=quote_amount,
                    solscan_url=f"https://solscan.io/tx/{item.signature}",
                )
            )

    trades.sort(key=lambda trade: (trade.block_time or 0, trade.signature, trade.wallet_id))
    return trades


def read_history_rules(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        rules = json.load(handle)
    required = ["token_mint", "quote_mint", "start_time", "end_time", "steps"]
    missing = [key for key in required if key not in rules]
    if missing:
        raise ValueError(f"Rules file is missing required keys: {', '.join(missing)}")
    if not isinstance(rules["steps"], list) or not rules["steps"]:
        raise ValueError("Rules file must contain at least one step.")
    for index, step in enumerate(rules["steps"], start=1):
        direction = str(step.get("direction", "")).lower()
        if direction not in {"buy", "sell"}:
            raise ValueError(f"Step {index} must use direction buy or sell.")
    return rules


def amount_basis_for_step(step: Dict[str, Any]) -> str:
    basis = str(step.get("amount_basis") or "").lower().strip()
    if basis in {"token", "quote"}:
        return basis
    direction = str(step.get("direction", "")).lower()
    return "quote" if direction == "buy" else "token"


def amount_for_basis(trade: TokenTrade, basis: str) -> Decimal:
    return trade.quote_amount if basis == "quote" else trade.token_amount


def range_for_step(step: Dict[str, Any], basis: str) -> Tuple[Optional[Decimal], Optional[Decimal], Decimal]:
    if basis == "quote":
        min_value = parse_decimal(step.get("min_quote") or step.get("min_sol") or step.get("min_input"), None)
        max_value = parse_decimal(step.get("max_quote") or step.get("max_sol") or step.get("max_input"), None)
        tolerance = parse_decimal(step.get("quote_tolerance") or step.get("fee_tolerance_quote") or step.get("sol_fee_tolerance"), ZERO) or ZERO
        return min_value, max_value, tolerance
    min_value = parse_decimal(step.get("min_token") or step.get("min_token_amount") or step.get("min_input"), None)
    max_value = parse_decimal(step.get("max_token") or step.get("max_token_amount") or step.get("max_input"), None)
    tolerance = parse_decimal(step.get("token_tolerance"), ZERO) or ZERO
    return min_value, max_value, tolerance


def amount_matches_step(trade: TokenTrade, step: Dict[str, Any]) -> Tuple[bool, str]:
    basis = amount_basis_for_step(step)
    value = amount_for_basis(trade, basis)
    min_value, max_value, tolerance = range_for_step(step, basis)
    label = "quote" if basis == "quote" else "token"

    if min_value is not None and value < min_value:
        return False, f"{label} amount too small: {format_amount(value)} < {format_amount(min_value)}."
    if max_value is not None and value > max_value + tolerance:
        extra = f" + tolerance {format_amount(tolerance)}" if tolerance else ""
        return False, f"{label} amount too large: {format_amount(value)} > {format_amount(max_value)}{extra}."
    return True, f"{label} amount matches."


def trade_matches_step(trade: TokenTrade, step: Dict[str, Any]) -> Tuple[bool, str]:
    expected_direction = str(step.get("direction", "")).lower()
    if trade.direction != expected_direction:
        return False, f"Wrong direction: expected {expected_direction}, got {trade.direction}."
    return amount_matches_step(trade, step)


def trade_has_relevant_wrong_direction(trade: TokenTrade, step: Dict[str, Any]) -> bool:
    expected_direction = str(step.get("direction", "")).lower()
    if trade.direction == expected_direction:
        return False
    matches, _reason = amount_matches_step(trade, step)
    return matches


def step_time_window(step: Dict[str, Any], global_start: int, global_end: int, naive_tz: timezone) -> Tuple[int, int]:
    start = parse_datetime_to_ts(step.get("start_time"), naive_tz) if step.get("start_time") else global_start
    end = parse_datetime_to_ts(step.get("end_time"), naive_tz) if step.get("end_time") else global_end
    if end <= start:
        raise ValueError(f"Invalid step time window for {step.get('name') or step.get('direction')}: end_time <= start_time")
    return start, end


def evaluate_wallet_with_step_windows(
    source: WalletSource,
    wallet_trades: List[TokenTrade],
    rules: Dict[str, Any],
    global_start: int,
    global_end: int,
    naive_tz: timezone,
) -> List[StepResult]:
    results: List[StepResult] = []
    for index, step in enumerate(rules["steps"], start=1):
        step_name = step.get("name") or f"Step {index} {step['direction']}"
        expected_direction = str(step["direction"]).lower()
        start, end = step_time_window(step, global_start, global_end, naive_tz)
        candidates = [trade for trade in wallet_trades if trade.block_time is None or start <= trade.block_time <= end]
        candidates.sort(key=lambda trade: trade.block_time or 0)

        wrong = next((trade for trade in candidates if trade_has_relevant_wrong_direction(trade, step)), None)
        if wrong:
            results.append(result_from_trade(source, step_name, expected_direction, "WRONG_DIRECTION", "Wrong direction with matching amount range.", wrong))
            continue

        correct: Optional[TokenTrade] = None
        wrong_amount: Optional[Tuple[TokenTrade, str]] = None
        for trade in candidates:
            if trade.direction != expected_direction:
                continue
            ok, reason = amount_matches_step(trade, step)
            if ok:
                correct = trade
                break
            if wrong_amount is None:
                wrong_amount = (trade, reason)

        if correct:
            results.append(result_from_trade(source, step_name, expected_direction, "OK", "Expected direction and amount range found.", correct))
        elif wrong_amount:
            trade, reason = wrong_amount
            results.append(result_from_trade(source, step_name, expected_direction, "WRONG_AMOUNT", reason, trade))
        else:
            results.append(StepResult(source.wallet_id, source.wallet, step_name, expected_direction, "MISSING", "No matching token-history trade found in this step window."))
    return results


def evaluate_wallet_as_sequence(
    source: WalletSource,
    wallet_trades: List[TokenTrade],
    rules: Dict[str, Any],
) -> List[StepResult]:
    results: List[StepResult] = []
    cursor = 0
    trades = sorted(wallet_trades, key=lambda trade: trade.block_time or 0)

    for index, step in enumerate(rules["steps"], start=1):
        step_name = step.get("name") or f"Step {index} {step['direction']}"
        expected_direction = str(step["direction"]).lower()
        found = False
        first_wrong_amount: Optional[Tuple[TokenTrade, str]] = None

        i = cursor
        while i < len(trades):
            trade = trades[i]
            if trade_has_relevant_wrong_direction(trade, step):
                results.append(result_from_trade(source, step_name, expected_direction, "WRONG_DIRECTION", "Wrong direction before the expected sequence step was completed.", trade))
                cursor = i + 1
                found = True
                break
            if trade.direction == expected_direction:
                ok, reason = amount_matches_step(trade, step)
                if ok:
                    results.append(result_from_trade(source, step_name, expected_direction, "OK", "Expected sequence step found.", trade))
                    cursor = i + 1
                    found = True
                    break
                if first_wrong_amount is None:
                    first_wrong_amount = (trade, reason)
            i += 1

        if found:
            continue
        if first_wrong_amount:
            trade, reason = first_wrong_amount
            results.append(result_from_trade(source, step_name, expected_direction, "WRONG_AMOUNT", reason, trade))
        else:
            results.append(StepResult(source.wallet_id, source.wallet, step_name, expected_direction, "MISSING", "No matching trade found in the expected sequence."))
    return results


def result_from_trade(
    source: WalletSource,
    step_name: str,
    expected_direction: str,
    status: str,
    reason: str,
    trade: TokenTrade,
) -> StepResult:
    return StepResult(
        wallet_id=source.wallet_id,
        wallet=source.wallet,
        step_name=step_name,
        expected_direction=expected_direction,
        status=status,
        reason=reason,
        actual_direction=trade.direction,
        signature=trade.signature,
        block_time=unix_to_text(trade.block_time),
        token_amount=format_amount(trade.token_amount),
        quote_amount=format_amount(trade.quote_amount),
        solscan_url=trade.solscan_url,
    )


def evaluate_token_history_trades(
    wallet_sources: List[WalletSource],
    trades: List[TokenTrade],
    rules: Dict[str, Any],
    global_start: int,
    global_end: int,
    naive_tz: timezone,
) -> List[StepResult]:
    trades_by_wallet: Dict[str, List[TokenTrade]] = {}
    for trade in trades:
        trades_by_wallet.setdefault(trade.wallet, []).append(trade)

    use_step_windows = any(step.get("start_time") or step.get("end_time") for step in rules["steps"])
    results: List[StepResult] = []
    for source in wallet_sources:
        wallet_trades = trades_by_wallet.get(source.wallet, [])
        if use_step_windows:
            results.extend(evaluate_wallet_with_step_windows(source, wallet_trades, rules, global_start, global_end, naive_tz))
        else:
            results.extend(evaluate_wallet_as_sequence(source, wallet_trades, rules))
    return results


def build_summary(wallet_sources: List[WalletSource], trades: List[TokenTrade], results: List[StepResult]) -> Dict[str, Any]:
    by_wallet: Dict[str, List[StepResult]] = {}
    for row in results:
        by_wallet.setdefault(row.wallet_id, []).append(row)

    unique_wallets_with_values = {trade.wallet_id for trade in trades if trade.token_amount > ZERO or trade.quote_amount > ZERO}
    wrong_direction_wallets = {row.wallet_id for row in results if row.status == "WRONG_DIRECTION"}
    all_ok_wallets = {wallet_id for wallet_id, rows in by_wallet.items() if rows and all(row.status == "OK" for row in rows)}
    any_ok_wallets = {row.wallet_id for row in results if row.status == "OK"}

    status_counts: Dict[str, int] = {}
    for row in results:
        status_counts[row.status] = status_counts.get(row.status, 0) + 1

    return {
        "total_wallets_in_scope": len(wallet_sources),
        "candidate_token_trades_in_scope": len(trades),
        "unique_wallets_with_matching_values": len(unique_wallets_with_values),
        "unique_wallets_with_at_least_one_ok_step": len(any_ok_wallets),
        "unique_wallets_all_steps_ok": len(all_ok_wallets),
        "unique_wallets_with_wrong_direction": len(wrong_direction_wallets),
        "all_swaps_correct_direction": "yes" if not wrong_direction_wallets else "no",
        "status_counts": status_counts,
    }


def write_token_history_public_csv(path: Path, rows: List[StepResult]) -> None:
    fieldnames = [
        "wallet_id", "step_name", "expected_direction", "status", "reason", "actual_direction",
        "block_time", "token_amount", "quote_amount",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: getattr(row, field) for field in fieldnames})


def write_token_history_private_csv(path: Path, rows: List[StepResult]) -> None:
    fieldnames = [
        "wallet_id", "wallet", "step_name", "expected_direction", "status", "reason", "actual_direction",
        "signature", "block_time", "token_amount", "quote_amount", "solscan_url",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: getattr(row, field) for field in fieldnames})


def write_token_history_events_csv(path: Path, trades: List[TokenTrade]) -> None:
    fieldnames = [
        "wallet_id", "wallet", "signature", "block_time", "slot", "direction",
        "token_delta", "quote_delta", "token_amount", "quote_amount", "solscan_url",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
        writer.writeheader()
        for trade in trades:
            writer.writerow(
                {
                    "wallet_id": trade.wallet_id,
                    "wallet": trade.wallet,
                    "signature": trade.signature,
                    "block_time": unix_to_text(trade.block_time),
                    "slot": trade.slot or "",
                    "direction": trade.direction,
                    "token_delta": format_amount(trade.token_delta),
                    "quote_delta": format_amount(trade.quote_delta),
                    "token_amount": format_amount(trade.token_amount),
                    "quote_amount": format_amount(trade.quote_amount),
                    "solscan_url": trade.solscan_url,
                }
            )


def write_summary_csv(path: Path, summary: Dict[str, Any]) -> None:
    rows: List[Tuple[str, Any]] = []
    for key, value in summary.items():
        if key == "status_counts":
            for status, count in sorted(value.items()):
                rows.append((f"status_{status}", count))
        else:
            rows.append((key, value))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter=";")
        writer.writerow(["metric", "value"])
        writer.writerows(rows)


def write_token_history_html_report(path: Path, rows: List[StepResult], summary: Dict[str, Any], rules: Dict[str, Any], include_links: bool) -> None:
    title = html.escape(str(rules.get("training_name", "Solana Token History Swap Training")))
    generated = html.escape(now_utc_text())

    def td(value: Any) -> str:
        return f"<td>{html.escape(str(value or ''))}</td>"

    metric_boxes = []
    for label, key in [
        ("Wallets in scope", "total_wallets_in_scope"),
        ("Candidate trades", "candidate_token_trades_in_scope"),
        ("Unique wallets with values", "unique_wallets_with_matching_values"),
        ("All steps OK", "unique_wallets_all_steps_ok"),
        ("Wrong direction wallets", "unique_wallets_with_wrong_direction"),
        ("All directions correct", "all_swaps_correct_direction"),
    ]:
        metric_boxes.append(f"<div class='box'><strong>{html.escape(label)}</strong><br>{html.escape(str(summary.get(key, '')))}</div>")

    body_rows = []
    for row in rows:
        link_cell = ""
        if include_links and row.solscan_url:
            link_cell = f'<td><a href="{html.escape(row.solscan_url)}">Solscan</a></td>'
        body_rows.append(
            "<tr>"
            + td(row.wallet_id)
            + td(row.step_name)
            + td(row.expected_direction)
            + td(row.status)
            + td(row.actual_direction)
            + td(row.token_amount)
            + td(row.quote_amount)
            + td(row.block_time)
            + td(row.reason)
            + link_cell
            + "</tr>"
        )
    link_header = "<th>Transaction</th>" if include_links else ""

    html_content = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{title}</title>
  <style>
    body {{ font-family: system-ui, -apple-system, Segoe UI, sans-serif; margin: 2rem; }}
    table {{ border-collapse: collapse; width: 100%; font-size: 0.9rem; }}
    th, td {{ border: 1px solid #ddd; padding: 0.5rem; vertical-align: top; }}
    th {{ background: #f2f2f2; text-align: left; }}
    .summary {{ display: flex; flex-wrap: wrap; gap: 1rem; margin: 1rem 0; }}
    .box {{ border: 1px solid #ddd; border-radius: 0.5rem; padding: 1rem; min-width: 12rem; }}
    .privacy {{ background: #fafafa; border: 1px solid #ddd; padding: 1rem; border-radius: 0.5rem; }}
  </style>
</head>
<body>
  <h1>{title}</h1>
  <p>Generated: {generated}</p>
  <div class="privacy">
    This public report intentionally contains no participant names and no wallet addresses.
  </div>
  <div class="summary">{''.join(metric_boxes)}</div>
  <table>
    <thead>
      <tr>
        <th>Wallet ID</th><th>Step</th><th>Expected Direction</th><th>Status</th><th>Actual Direction</th>
        <th>Token Amount</th><th>Quote Amount</th><th>Block Time</th><th>Reason</th>{link_header}
      </tr>
    </thead>
    <tbody>{''.join(body_rows)}</tbody>
  </table>
</body>
</html>
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html_content, encoding="utf-8")


def build_rate_limiter(args: argparse.Namespace) -> Optional[RateLimiter]:
    calls = int(getattr(args, "rate_limit_calls", 0) or 0)
    wait_seconds = float(getattr(args, "rate_limit_wait_seconds", 0) or 0)
    if calls <= 0 or wait_seconds <= 0:
        return None
    return RateLimiter(calls=calls, wait_seconds=wait_seconds)


def command_analyze_token_history(args: argparse.Namespace) -> int:
    naive_tz = parse_tz_offset(args.history_timezone_offset)
    rules = read_history_rules(Path(args.rules))
    global_start = parse_datetime_to_ts(rules["start_time"], naive_tz)
    global_end = parse_datetime_to_ts(rules["end_time"], naive_tz)
    if global_end <= global_start:
        raise ValueError("rules.end_time must be later than rules.start_time.")

    wallet_sources = read_wallet_sources(Path(args.wallets))
    history_signatures = read_token_history_signatures(
        Path(args.token_history),
        global_start,
        global_end,
        naive_tz,
        disable_time_prefilter=args.disable_history_time_prefilter,
        debug_csv=args.debug_token_history_csv,
        csv_amount_mode=args.csv_amount_mode,
    )
    print(f"Loaded {len(wallet_sources)} wallet IDs and {len(history_signatures)} token-history signatures.", file=sys.stderr)

    history_signatures = prefilter_token_history_rows(
        history_signatures=history_signatures,
        wallet_sources=wallet_sources,
        rules=rules,
        global_start=global_start,
        global_end=global_end,
        naive_tz=naive_tz,
        from_wallet_prefilter=args.from_wallet_prefilter,
        csv_step_prefilter=not args.disable_csv_step_prefilter,
    )
    print(f"Scanning {len(history_signatures)} token-history signatures after prefiltering.", file=sys.stderr)

    rate_limiter = build_rate_limiter(args)
    trades = load_trades_from_token_history(
        rpc_url=args.rpc_url,
        history_signatures=history_signatures,
        wallet_sources=wallet_sources,
        token_mint=rules["token_mint"],
        quote_mint=rules["quote_mint"],
        start_ts=global_start,
        end_ts=global_end,
        rate_limiter=rate_limiter,
    )
    print(f"Detected {len(trades)} token trades for wallets in scope.", file=sys.stderr)

    results = evaluate_token_history_trades(wallet_sources, trades, rules, global_start, global_end, naive_tz)
    summary = build_summary(wallet_sources, trades, results)

    public_output = Path(args.public_output)
    write_token_history_public_csv(public_output, results)
    write_summary_csv(Path(args.summary_output), summary)

    if args.private_output:
        write_token_history_private_csv(Path(args.private_output), results)
    if args.events_output:
        write_token_history_events_csv(Path(args.events_output), trades)
    if args.html_output:
        write_token_history_html_report(Path(args.html_output), results, summary, rules, args.include_evidence_links_in_public_report)

    print(f"Wrote public token-history results: {public_output}", file=sys.stderr)
    print(f"Wrote summary: {args.summary_output}", file=sys.stderr)
    if args.private_output:
        print(f"Wrote private evidence: {args.private_output}", file=sys.stderr)
    if args.events_output:
        print(f"Wrote private event CSV: {args.events_output}", file=sys.stderr)
    if args.html_output:
        print(f"Wrote public HTML report: {args.html_output}", file=sys.stderr)

    print(
        "Summary: "
        f"unique_wallets_with_matching_values={summary['unique_wallets_with_matching_values']}, "
        f"unique_wallets_with_wrong_direction={summary['unique_wallets_with_wrong_direction']}, "
        f"all_swaps_correct_direction={summary['all_swaps_correct_direction']}",
        file=sys.stderr,
    )
    return 0


def add_rate_limit_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--rate-limit-calls", type=int, default=10, help="Number of RPC requests before waiting. Use 0 to disable request pacing.")
    parser.add_argument("--rate-limit-wait-seconds", type=float, default=10.0, help="Seconds to wait after --rate-limit-calls requests.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Privacy-preserving Solana token-history swap training analyzer.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    analyze = subparsers.add_parser(
        "analyze-token-history",
        help="Analyze a token-history CSV candidate stream against anonymous wallet IDs and ordered training steps.",
    )
    analyze.add_argument("--token-history", required=True, help="Token history CSV containing transaction signatures from Solscan or another explorer/API.")
    analyze.add_argument("--wallets", required=True, help="Anonymous wallet source CSV with wallet_id and wallet columns.")
    analyze.add_argument("--rules", required=True, help="JSON training rules file for token-history analysis.")
    analyze.add_argument("--rpc-url", default=DEFAULT_RPC_URL, help="Solana JSON-RPC endpoint used for getTransaction.")
    analyze.add_argument("--history-timezone-offset", default="+00:00", help="Timezone for naive CSV timestamps, for example +00:00 or +02:00.")
    analyze.add_argument("--disable-history-time-prefilter", action="store_true", help="Do not discard token-history CSV rows by CSV Block Time/Human Time before RPC loading. On-chain block_time is still checked after getTransaction.")
    analyze.add_argument("--debug-token-history-csv", action="store_true", help="Print token-history CSV diagnostics such as detected signature column and time-filtered row counts.")
    analyze.add_argument("--public-output", default="token_history_public_results.csv", help="Public pseudonymous result CSV path.")
    analyze.add_argument("--summary-output", default="token_history_summary.csv", help="Summary metric CSV path.")
    analyze.add_argument("--private-output", default="token_history_private_evidence.csv", help="Private CSV with wallet addresses; pass empty string to disable.")
    analyze.add_argument("--events-output", default="token_history_private_events.csv", help="Private CSV with detected candidate trades; pass empty string to disable.")
    analyze.add_argument("--html-output", default="token_history_public_report.html", help="Public HTML report path; pass empty string to disable.")
    analyze.add_argument("--include-evidence-links-in-public-report", action="store_true", help="Include Solscan transaction links in the public HTML report.")
    analyze.add_argument("--from-wallet-prefilter", choices=["auto", "on", "off"], default="auto", help="Use Solscan CSV From column to skip rows outside the wallet list. auto uses it only when overlap is detected.")
    analyze.add_argument("--csv-amount-mode", choices=["auto", "raw", "ui"], default="auto", help="How to interpret Solscan Amount1/Amount2 columns. auto/raw divide by TokenDecimals when present; ui treats Amount columns as already human-readable.")
    analyze.add_argument("--disable-csv-step-prefilter", action="store_true", help="Disable prefiltering by Solscan Token1/Token2 Amount1/Amount2 against rule step ranges.")
    add_rate_limit_arguments(analyze)
    analyze.set_defaults(func=command_analyze_token_history)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - command-line tool should show readable errors
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
