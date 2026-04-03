#!/usr/bin/env python3
"""Zoho SalesIQ source plugin for marketing-intel monitor.

Collects visitor analytics, chat metrics, page engagement, and visitor
intent signals from the Zoho SalesIQ REST API.

Required env vars:
    ZOHO_SALESIQ_DOMAIN         — Zoho data center domain (e.g. "www.zohoapis.com"
                                  or "www.zohoapis.eu" for EU DC)
    ZOHO_SALESIQ_APP_ID         — SalesIQ portal/app ID
    ZOHO_SALESIQ_ACCESS_TOKEN   — OAuth2 access token (scope: SalesIQ.visitors.READ,
                                  SalesIQ.analytics.READ)
    ZOHO_SALESIQ_REFRESH_TOKEN  — (Optional) Refresh token for auto-renewal
    ZOHO_SALESIQ_CLIENT_ID      — (Optional) Client ID for token refresh
    ZOHO_SALESIQ_CLIENT_SECRET  — (Optional) Client secret for token refresh

Usage:
    python3 zoho_salesiq.py --mode weekly --domain encypher.com --output /tmp/zoho.json
    python3 zoho_salesiq.py --mode anomaly --domain encypher.com --output /tmp/zoho.json
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

REQUIRED_ENV = [
    "ZOHO_SALESIQ_DOMAIN",
    "ZOHO_SALESIQ_APP_ID",
    "ZOHO_SALESIQ_ACCESS_TOKEN",
]


def check_env():
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        return f"Missing environment variables: {', '.join(missing)}"
    return None


def refresh_token_if_needed():
    """Attempt to refresh the access token if refresh credentials are available."""
    refresh_token = os.environ.get("ZOHO_SALESIQ_REFRESH_TOKEN")
    client_id = os.environ.get("ZOHO_SALESIQ_CLIENT_ID")
    client_secret = os.environ.get("ZOHO_SALESIQ_CLIENT_SECRET")
    domain = os.environ.get("ZOHO_SALESIQ_DOMAIN", "www.zohoapis.com")

    if not all([refresh_token, client_id, client_secret]):
        return None

    accounts_domain = domain.replace("www.zohoapis", "accounts.zoho")
    url = f"https://{accounts_domain}/oauth/v2/token"
    params = urlencode(
        {
            "refresh_token": refresh_token,
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "refresh_token",
        }
    ).encode()

    req = Request(url, data=params, method="POST")
    try:
        with urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
            new_token = data.get("access_token")
            if new_token:
                os.environ["ZOHO_SALESIQ_ACCESS_TOKEN"] = new_token
                return new_token
    except (HTTPError, OSError) as e:
        print(f"ZOHO: Token refresh failed: {e}", file=sys.stderr)

    return None


def api_get(endpoint, params=None):
    """Make an authenticated GET request to the SalesIQ API."""
    domain = os.environ["ZOHO_SALESIQ_DOMAIN"]
    app_id = os.environ["ZOHO_SALESIQ_APP_ID"]
    token = os.environ["ZOHO_SALESIQ_ACCESS_TOKEN"]

    base_url = f"https://{domain}/salesiq/v2/portals/{app_id}"
    url = f"{base_url}/{endpoint}"
    if params:
        url = f"{url}?{urlencode(params)}"

    req = Request(url)
    req.add_header("Authorization", f"Zoho-oauthtoken {token}")
    req.add_header("Content-Type", "application/json")

    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except HTTPError as e:
        if e.code == 401:
            # Try token refresh once
            new_token = refresh_token_if_needed()
            if new_token:
                req2 = Request(url)
                req2.add_header("Authorization", f"Zoho-oauthtoken {new_token}")
                req2.add_header("Content-Type", "application/json")
                with urlopen(req2, timeout=30) as resp:
                    return json.loads(resp.read())
        raise


def date_ranges(mode):
    today = datetime.now(timezone.utc).date()
    if mode == "weekly":
        end = today - timedelta(days=1)
        start = end - timedelta(days=6)
        comp_end = start - timedelta(days=1)
        comp_start = comp_end - timedelta(days=6)
    else:
        end = today - timedelta(days=1)
        start = end
        comp_end = end - timedelta(days=7)
        comp_start = comp_end
    return (
        start.isoformat(),
        end.isoformat(),
        comp_start.isoformat(),
        comp_end.isoformat(),
    )


def safe_change_pct(current, previous):
    if previous == 0:
        return 100.0 if current > 0 else 0.0
    return round(((current - previous) / previous) * 100, 1)


def get_visitor_stats(start, end):
    """Fetch visitor statistics for the given date range."""
    try:
        data = api_get("analytics/visitors", {
            "from": start,
            "to": end,
        })
        return data.get("data", data)
    except Exception as e:
        print(f"ZOHO: Visitor stats failed: {e}", file=sys.stderr)
        return {}


def get_chat_stats(start, end):
    """Fetch chat/conversation statistics."""
    try:
        data = api_get("analytics/chats", {
            "from": start,
            "to": end,
        })
        return data.get("data", data)
    except Exception as e:
        print(f"ZOHO: Chat stats failed: {e}", file=sys.stderr)
        return {}


def get_top_pages(start, end):
    """Fetch top visited pages."""
    try:
        data = api_get("analytics/pages", {
            "from": start,
            "to": end,
            "limit": 30,
        })
        return data.get("data", [])
    except Exception as e:
        print(f"ZOHO: Page stats failed: {e}", file=sys.stderr)
        return []


def get_visitor_sources(start, end):
    """Fetch visitor traffic sources breakdown."""
    try:
        data = api_get("analytics/sources", {
            "from": start,
            "to": end,
        })
        return data.get("data", [])
    except Exception as e:
        print(f"ZOHO: Source stats failed: {e}", file=sys.stderr)
        return []


def extract_metrics(stats, keys):
    """Safely extract numeric metrics from a stats dict."""
    result = {}
    for key in keys:
        val = stats.get(key, 0)
        if isinstance(val, (int, float)):
            result[key] = val
        elif isinstance(val, str):
            try:
                result[key] = float(val) if "." in val else int(val)
            except ValueError:
                result[key] = 0
        else:
            result[key] = 0
    return result


def collect_weekly(start, end, comp_start, comp_end):
    """Collect full weekly SalesIQ report."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    # -- Visitor stats current vs previous --
    cur_visitors = get_visitor_stats(start, end)
    prev_visitors = get_visitor_stats(comp_start, comp_end)

    visitor_metrics = [
        "total_visitors", "unique_visitors", "returning_visitors",
        "avg_time_on_site", "total_page_views",
    ]

    cur_v = extract_metrics(cur_visitors, visitor_metrics)
    prev_v = extract_metrics(prev_visitors, visitor_metrics)

    for m in visitor_metrics:
        cv, pv = cur_v.get(m, 0), prev_v.get(m, 0)
        data["summary"][m] = {
            "current": cv,
            "previous": pv,
            "change_pct": safe_change_pct(cv, pv),
        }

    # -- Chat stats --
    cur_chats = get_chat_stats(start, end)
    prev_chats = get_chat_stats(comp_start, comp_end)

    chat_metrics = [
        "total_chats", "missed_chats", "avg_response_time",
        "avg_chat_duration", "chat_initiated_by_visitor",
    ]

    cur_c = extract_metrics(cur_chats, chat_metrics)
    prev_c = extract_metrics(prev_chats, chat_metrics)

    for m in chat_metrics:
        cv, pv = cur_c.get(m, 0), prev_c.get(m, 0)
        data["summary"][m] = {
            "current": cv,
            "previous": pv,
            "change_pct": safe_change_pct(cv, pv),
        }

    # -- Top pages --
    pages = get_top_pages(start, end)
    if isinstance(pages, list):
        for p in pages[:20]:
            if isinstance(p, dict):
                data["top_items"].append({"type": "salesiq_page", **p})

    # -- Traffic sources --
    sources = get_visitor_sources(start, end)
    if isinstance(sources, list):
        for s in sources[:10]:
            if isinstance(s, dict):
                data["top_items"].append({"type": "salesiq_source", **s})

    # -- Anomaly detection --
    # Chat engagement anomalies
    if prev_c.get("total_chats", 0) >= 3:
        chat_change = safe_change_pct(
            cur_c.get("total_chats", 0), prev_c.get("total_chats", 0)
        )
        if abs(chat_change) > 40:
            data["anomalies"].append(
                {
                    "metric": "total_chats",
                    "dimension": "site-wide",
                    "expected": prev_c.get("total_chats", 0),
                    "actual": cur_c.get("total_chats", 0),
                    "deviation_pct": chat_change,
                    "severity": "high" if abs(chat_change) > 60 else "medium",
                }
            )

    # Missed chat rate
    cur_total = cur_c.get("total_chats", 0)
    prev_total = prev_c.get("total_chats", 0)
    if cur_total >= 5 and prev_total >= 5:
        cur_miss_rate = cur_c.get("missed_chats", 0) / cur_total
        prev_miss_rate = prev_c.get("missed_chats", 0) / prev_total
        miss_delta = cur_miss_rate - prev_miss_rate
        if abs(miss_delta) > 0.15:
            data["anomalies"].append(
                {
                    "metric": "missed_chat_rate",
                    "dimension": "site-wide",
                    "expected": round(prev_miss_rate, 3),
                    "actual": round(cur_miss_rate, 3),
                    "deviation_pct": round(miss_delta * 100, 1),
                    "severity": "high" if miss_delta > 0.25 else "medium",
                }
            )

    # Visitor volume anomalies
    cv_total = cur_v.get("total_visitors", 0)
    pv_total = prev_v.get("total_visitors", 0)
    if pv_total >= 10:
        visitor_change = safe_change_pct(cv_total, pv_total)
        if abs(visitor_change) > 30:
            data["anomalies"].append(
                {
                    "metric": "total_visitors",
                    "dimension": "site-wide",
                    "expected": pv_total,
                    "actual": cv_total,
                    "deviation_pct": visitor_change,
                    "severity": "high" if abs(visitor_change) > 50 else "medium",
                }
            )

    return data


def collect_anomaly(start, end, comp_start, comp_end):
    """Anomaly-focused: compare yesterday to same day last week."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    cur_visitors = get_visitor_stats(start, end)
    prev_visitors = get_visitor_stats(comp_start, comp_end)

    check_metrics = ["total_visitors", "unique_visitors", "total_page_views"]
    cur_v = extract_metrics(cur_visitors, check_metrics)
    prev_v = extract_metrics(prev_visitors, check_metrics)

    for m in check_metrics:
        cv, pv = cur_v.get(m, 0), prev_v.get(m, 0)
        change = safe_change_pct(cv, pv)
        data["summary"][m] = {
            "current": cv,
            "previous": pv,
            "change_pct": change,
        }
        if abs(change) > 30 and (cv >= 5 or pv >= 5):
            data["anomalies"].append(
                {
                    "metric": m,
                    "dimension": "site-wide",
                    "expected": pv,
                    "actual": cv,
                    "deviation_pct": change,
                    "severity": "high" if abs(change) > 50 else "medium",
                }
            )

    cur_chats = get_chat_stats(start, end)
    prev_chats = get_chat_stats(comp_start, comp_end)
    cur_c = extract_metrics(cur_chats, ["total_chats", "missed_chats"])
    prev_c = extract_metrics(prev_chats, ["total_chats", "missed_chats"])

    if prev_c.get("total_chats", 0) >= 2:
        chat_change = safe_change_pct(
            cur_c.get("total_chats", 0), prev_c.get("total_chats", 0)
        )
        if abs(chat_change) > 40:
            data["anomalies"].append(
                {
                    "metric": "total_chats",
                    "dimension": "site-wide",
                    "expected": prev_c.get("total_chats", 0),
                    "actual": cur_c.get("total_chats", 0),
                    "deviation_pct": chat_change,
                    "severity": "high" if abs(chat_change) > 60 else "medium",
                }
            )

    return data


def main():
    parser = argparse.ArgumentParser(description="Zoho SalesIQ source plugin")
    parser.add_argument("--mode", required=True, choices=["weekly", "anomaly"])
    parser.add_argument("--domain", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    env_err = check_env()
    if env_err:
        result = {
            "source": "zoho_salesiq",
            "domain": args.domain,
            "mode": args.mode,
            "period": {},
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "error": env_err,
            "data": {},
        }
        with open(args.output, "w") as f:
            json.dump(result, f, indent=2)
        print(f"ZOHO: {env_err}", file=sys.stderr)
        sys.exit(1)

    start, end, comp_start, comp_end = date_ranges(args.mode)

    if args.mode == "weekly":
        data = collect_weekly(start, end, comp_start, comp_end)
    else:
        data = collect_anomaly(start, end, comp_start, comp_end)

    result = {
        "source": "zoho_salesiq",
        "domain": args.domain,
        "mode": args.mode,
        "period": {
            "start": start,
            "end": end,
            "comparison_start": comp_start,
            "comparison_end": comp_end,
        },
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "data": data,
    }

    with open(args.output, "w") as f:
        json.dump(result, f, indent=2)

    anomaly_count = len(data.get("anomalies", []))
    print(f"ZOHO: {args.mode} collected, {anomaly_count} anomalies")


if __name__ == "__main__":
    main()
