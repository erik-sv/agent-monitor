#!/usr/bin/env python3
"""Google Search Console source plugin for marketing-intel monitor.

Collects search queries, CTR, average position, impressions, and page
performance from the Google Search Console API.

Required env vars:
    GSC_SITE_URL            — Site URL in GSC format (e.g. "sc-domain:encypher.com"
                              or "https://www.encypher.com/")
    GSC_CREDENTIALS_PATH    — Path to service account JSON key file
                              (service account must be added as a user in GSC)

Usage:
    python3 gsc.py --mode weekly --domain encypher.com --output /tmp/gsc.json
    python3 gsc.py --mode anomaly --domain encypher.com --output /tmp/gsc.json
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

REQUIRED_ENV = ["GSC_SITE_URL", "GSC_CREDENTIALS_PATH"]


def check_env():
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        return f"Missing environment variables: {', '.join(missing)}"
    return None


def get_service():
    """Initialize GSC API service with service account credentials."""
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    creds_path = os.environ["GSC_CREDENTIALS_PATH"]
    credentials = service_account.Credentials.from_service_account_file(
        creds_path,
        scopes=["https://www.googleapis.com/auth/webmasters.readonly"],
    )
    return build("searchconsole", "v1", credentials=credentials)


def date_ranges(mode):
    """Return date range tuples. GSC data lags ~3 days."""
    today = datetime.now(timezone.utc).date()
    if mode == "weekly":
        end = today - timedelta(days=3)
        start = end - timedelta(days=6)
        comp_end = start - timedelta(days=1)
        comp_start = comp_end - timedelta(days=6)
    else:  # anomaly: compare recent 2-day window to same window last week
        end = today - timedelta(days=3)
        start = end - timedelta(days=1)
        comp_end = end - timedelta(days=7)
        comp_start = comp_end - timedelta(days=1)
    return (
        start.isoformat(),
        end.isoformat(),
        comp_start.isoformat(),
        comp_end.isoformat(),
    )


def query_gsc(service, site_url, start, end, dimensions, row_limit=100):
    """Run a GSC search analytics query and return rows."""
    request = {
        "startDate": start,
        "endDate": end,
        "dimensions": dimensions,
        "rowLimit": row_limit,
    }
    response = (
        service.searchanalytics().query(siteUrl=site_url, body=request).execute()
    )
    rows = []
    for row in response.get("rows", []):
        entry = {}
        for i, dim in enumerate(dimensions):
            entry[dim] = row["keys"][i]
        entry["clicks"] = row.get("clicks", 0)
        entry["impressions"] = row.get("impressions", 0)
        entry["ctr"] = round(row.get("ctr", 0), 4)
        entry["position"] = round(row.get("position", 0), 1)
        rows.append(entry)
    return rows


def safe_change_pct(current, previous):
    if previous == 0:
        return 100.0 if current > 0 else 0.0
    return round(((current - previous) / previous) * 100, 1)


def detect_query_trends(current_queries, prev_queries):
    """Compare query performance across periods to find trends and anomalies."""
    trends = []
    anomalies = []

    prev_map = {q["query"]: q for q in prev_queries}

    for q in current_queries:
        query_text = q["query"]
        prev_q = prev_map.get(query_text)

        if not prev_q:
            # New query appearing
            if q["clicks"] >= 3 or q["impressions"] >= 50:
                trends.append(
                    {
                        "item": f"query:{query_text}",
                        "direction": "new",
                        "metric": "clicks",
                        "current_value": q["clicks"],
                        "previous_value": 0,
                        "change_pct": 100.0,
                    }
                )
            continue

        # Position changes
        pos_delta = prev_q["position"] - q["position"]  # positive = improved
        if abs(pos_delta) >= 3 and q["impressions"] >= 20:
            direction = "rising" if pos_delta > 0 else "falling"
            trends.append(
                {
                    "item": f"query:{query_text}",
                    "direction": direction,
                    "metric": "position",
                    "current_value": q["position"],
                    "previous_value": prev_q["position"],
                    "change_pct": round(pos_delta, 1),
                }
            )

        # CTR anomalies
        if q["impressions"] >= 30 and prev_q["impressions"] >= 30:
            ctr_delta = q["ctr"] - prev_q["ctr"]
            if abs(ctr_delta) > 0.02:  # >2 percentage point CTR shift
                anomalies.append(
                    {
                        "metric": "ctr",
                        "dimension": f"query:{query_text}",
                        "expected": prev_q["ctr"],
                        "actual": q["ctr"],
                        "deviation_pct": round(ctr_delta * 100, 1),
                        "severity": "high" if abs(ctr_delta) > 0.05 else "medium",
                    }
                )

        # Click volume anomalies
        if prev_q["clicks"] >= 5:
            click_change = safe_change_pct(q["clicks"], prev_q["clicks"])
            if abs(click_change) > 40:
                anomalies.append(
                    {
                        "metric": "clicks",
                        "dimension": f"query:{query_text}",
                        "expected": prev_q["clicks"],
                        "actual": q["clicks"],
                        "deviation_pct": click_change,
                        "severity": "high" if abs(click_change) > 60 else "medium",
                    }
                )

    # Queries that disappeared
    current_query_set = {q["query"] for q in current_queries}
    for q in prev_queries:
        if q["query"] not in current_query_set and q["clicks"] >= 5:
            trends.append(
                {
                    "item": f"query:{q['query']}",
                    "direction": "gone",
                    "metric": "clicks",
                    "current_value": 0,
                    "previous_value": q["clicks"],
                    "change_pct": -100.0,
                }
            )

    return trends, anomalies


def collect_weekly(service, site_url, start, end, comp_start, comp_end):
    """Collect full weekly GSC report."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    # -- Summary: site-wide totals --
    cur_totals = query_gsc(service, site_url, start, end, [], row_limit=1)
    prev_totals = query_gsc(service, site_url, comp_start, comp_end, [], row_limit=1)

    # GSC returns a single row with no dimensions for site-wide totals
    if cur_totals and prev_totals:
        c, p = cur_totals[0], prev_totals[0]
        for m in ["clicks", "impressions", "ctr", "position"]:
            data["summary"][m] = {
                "current": c.get(m, 0),
                "previous": p.get(m, 0),
                "change_pct": safe_change_pct(c.get(m, 0), p.get(m, 0)),
            }

    # -- Top queries --
    queries_cur = query_gsc(
        service, site_url, start, end, ["query"], row_limit=50
    )
    queries_prev = query_gsc(
        service, site_url, comp_start, comp_end, ["query"], row_limit=50
    )
    data["top_items"].extend(
        [{"type": "search_query", **q} for q in queries_cur[:25]]
    )

    # -- Top pages --
    pages_cur = query_gsc(
        service, site_url, start, end, ["page"], row_limit=30
    )
    pages_prev = query_gsc(
        service, site_url, comp_start, comp_end, ["page"], row_limit=30
    )
    data["top_items"].extend(
        [{"type": "search_page", **p} for p in pages_cur[:15]]
    )

    # -- Trends and anomalies from query comparison --
    trends, anomalies = detect_query_trends(queries_cur, queries_prev)
    data["trends"].extend(trends)
    data["anomalies"].extend(anomalies)

    # -- Page-level anomalies --
    prev_page_map = {p["page"]: p for p in pages_prev}
    for p in pages_cur:
        prev_p = prev_page_map.get(p["page"])
        if prev_p and prev_p["clicks"] >= 5:
            click_change = safe_change_pct(p["clicks"], prev_p["clicks"])
            if abs(click_change) > 40:
                data["anomalies"].append(
                    {
                        "metric": "clicks",
                        "dimension": f"page:{p['page']}",
                        "expected": prev_p["clicks"],
                        "actual": p["clicks"],
                        "deviation_pct": click_change,
                        "severity": "high" if abs(click_change) > 60 else "medium",
                    }
                )

    # -- Device breakdown --
    devices = query_gsc(
        service, site_url, start, end, ["device"], row_limit=5
    )
    data["top_items"].extend(
        [{"type": "device", **d} for d in devices]
    )

    # -- Country breakdown (top 10) --
    countries = query_gsc(
        service, site_url, start, end, ["country"], row_limit=10
    )
    data["top_items"].extend(
        [{"type": "country", **c} for c in countries]
    )

    return data


def collect_anomaly(service, site_url, start, end, comp_start, comp_end):
    """Anomaly-focused: compare recent window to same window last week."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    # Site-wide comparison
    cur_totals = query_gsc(service, site_url, start, end, [], row_limit=1)
    prev_totals = query_gsc(service, site_url, comp_start, comp_end, [], row_limit=1)

    if cur_totals and prev_totals:
        c, p = cur_totals[0], prev_totals[0]
        for m in ["clicks", "impressions", "ctr", "position"]:
            cv, pv = c.get(m, 0), p.get(m, 0)
            change = safe_change_pct(cv, pv)
            data["summary"][m] = {
                "current": cv,
                "previous": pv,
                "change_pct": change,
            }
            if m in ("clicks", "impressions") and abs(change) > 30 and (cv >= 5 or pv >= 5):
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

    # Query-level anomaly detection
    queries_cur = query_gsc(
        service, site_url, start, end, ["query"], row_limit=50
    )
    queries_prev = query_gsc(
        service, site_url, comp_start, comp_end, ["query"], row_limit=50
    )
    trends, anomalies = detect_query_trends(queries_cur, queries_prev)
    data["trends"].extend(trends)
    data["anomalies"].extend(anomalies)

    return data


def main():
    parser = argparse.ArgumentParser(description="GSC source plugin")
    parser.add_argument("--mode", required=True, choices=["weekly", "anomaly"])
    parser.add_argument("--domain", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    env_err = check_env()
    if env_err:
        result = {
            "source": "gsc",
            "domain": args.domain,
            "mode": args.mode,
            "period": {},
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "error": env_err,
            "data": {},
        }
        with open(args.output, "w") as f:
            json.dump(result, f, indent=2)
        print(f"GSC: {env_err}", file=sys.stderr)
        sys.exit(1)

    site_url = os.environ["GSC_SITE_URL"]
    start, end, comp_start, comp_end = date_ranges(args.mode)

    service = get_service()

    if args.mode == "weekly":
        data = collect_weekly(service, site_url, start, end, comp_start, comp_end)
    else:
        data = collect_anomaly(service, site_url, start, end, comp_start, comp_end)

    result = {
        "source": "gsc",
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
    trend_count = len(data.get("trends", []))
    print(f"GSC: {args.mode} collected, {anomaly_count} anomalies, {trend_count} trends")


if __name__ == "__main__":
    main()
