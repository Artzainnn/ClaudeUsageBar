#!/usr/bin/env python3
"""Export successful Stripe payments with donor/contact details.

Reads STRIPE_API_KEY from the environment. The key is never printed.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from decimal import Decimal
from typing import Any, Dict, Iterable, List


STRIPE_API = "https://api.stripe.com/v1"


def stripe_get(path: str, params: Dict[str, Any], api_key: str) -> Dict[str, Any]:
    query = urllib.parse.urlencode(params, doseq=True)
    token = base64.b64encode(f"{api_key}:".encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        f"{STRIPE_API}{path}?{query}",
        headers={"Authorization": f"Basic {token}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def stripe_list(path: str, params: Dict[str, Any], api_key: str) -> Iterable[Dict[str, Any]]:
    request_params = dict(params)
    request_params.setdefault("limit", 100)
    starting_after = None

    while True:
        if starting_after:
            request_params["starting_after"] = starting_after

        payload = stripe_get(path, request_params, api_key)
        data = payload.get("data", [])

        for item in data:
            yield item

        if not payload.get("has_more") or not data:
            break

        starting_after = data[-1]["id"]


def export_payments(api_key: str) -> List[Dict[str, str]]:
    sessions_by_payment_intent: Dict[str, Dict[str, Any]] = {}
    for session in stripe_list("/checkout/sessions", {"status": "complete"}, api_key):
        payment_intent = session.get("payment_intent")
        if payment_intent:
            sessions_by_payment_intent[payment_intent] = session

    rows: List[Dict[str, str]] = []
    for payment_intent in stripe_list(
        "/payment_intents",
        {"expand[]": ["data.latest_charge"]},
        api_key,
    ):
        if payment_intent.get("status") != "succeeded":
            continue

        payment_intent_id = payment_intent.get("id", "")
        session = sessions_by_payment_intent.get(payment_intent_id, {})
        customer_details = session.get("customer_details") or {}
        charge = payment_intent.get("latest_charge")
        if not isinstance(charge, dict):
            charge = {}
        billing_details = charge.get("billing_details") or {}

        amount = Decimal(payment_intent.get("amount_received") or payment_intent.get("amount") or 0)
        created = payment_intent.get("created")
        date = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(created)) if created else ""

        rows.append(
            {
                "date": date,
                "name": customer_details.get("name") or billing_details.get("name") or "",
                "email": (
                    customer_details.get("email")
                    or billing_details.get("email")
                    or payment_intent.get("receipt_email")
                    or ""
                ),
                "amount": str(amount / Decimal(100)),
                "currency": (payment_intent.get("currency") or "").upper(),
                "payment_intent": payment_intent_id,
                "checkout_session": session.get("id", ""),
                "charge": charge.get("id", ""),
            }
        )

    return sorted(rows, key=lambda row: row["date"], reverse=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Export successful Stripe payment contacts to CSV.")
    parser.add_argument("--output", default="stripe_payments.csv", help="CSV output path")
    args = parser.parse_args()

    api_key = os.environ.get("STRIPE_API_KEY", "").strip()
    if not api_key:
        print("Missing STRIPE_API_KEY environment variable.", file=sys.stderr)
        return 2

    rows = export_payments(api_key)
    with open(args.output, "w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(
            file,
            fieldnames=[
                "date",
                "name",
                "email",
                "amount",
                "currency",
                "payment_intent",
                "checkout_session",
                "charge",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Exported {len(rows)} successful payments to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
