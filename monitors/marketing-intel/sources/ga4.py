#!/usr/bin/env python3
"""Google Analytics 4 source plugin for marketing-intel monitor.

Collects traffic, UTM campaign performance, landing page metrics, conversions,
and bounce rates from the GA4 Data API (v1beta).

Required env vars:
    GA4_PROPERTY_ID         — GA4 property ID (e.g. "properties/123456789")
    GA4_CREDENTIALS_PATH    — Path to service account JSON key file

Usage:
    python3 ga4.py --mode weekly --domain encypher.com --output /tmp/ga4.json
    python3 ga4.py --mode anomaly --domain encypher.com --output /tmp/ga4.json
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

REQUIRED_ENV = ["GA4_PROPERTY_ID", "GA4_CREDENTIALS_PATH"]


def check_env():
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        return f"Missing environment variables: {', '.join(missing)}"
    return None


def get_client():
    """Initialize the GA4 Data API client with service account credentials."""
    from google.analytics.data_v1beta import BetaAnalyticsDataClient
    from google.oauth2 import service_account

    creds_path = os.environ["GA4_CREDENTIALS_PATH"]
    credentials = service_account.Credentials.from_service_account_file(
        creds_path,
        scopes=["https://www.googleapis.com/auth/analytics.readonly"],
    )
    return BetaAnalyticsDataClient(credentials=credentials)


def date_ranges(mode):
    """Return (start, end, comp_start, comp_end) date strings for the given mode."""
    today = datetime.now(timezone.utc).date()
    if mode == "weekly":
        end = today - timedelta(days=1)  # yesterday (GA4 data lags ~1 day)
        start = end - timedelta(days=6)  # 7-day window
        comp_end = start - timedelta(days=1)
        comp_start = comp_end - timedelta(days=6)
    else:  # anomaly
        end = today - timedelta(days=1)
        start = end  # single day
        comp_end = end - timedelta(days=7)
        comp_start = comp_end  # same day last week
    return (
        start.isoformat(),
        end.isoformat(),
        comp_start.isoformat(),
        comp_end.isoformat(),
    )


def run_report(client, property_id, dimensions, metrics, start, end):
    """Run a GA4 report and return rows as list of dicts."""
    from google.analytics.data_v1beta.types import (
        DateRange,
        Dimension,
        Metric,
        RunReportRequest,
    )

    request = RunReportRequest(
        property=property_id,
        dimensions=[Dimension(name=d) for d in dimensions],
        metrics=[Metric(name=m) for m in metrics],
        date_ranges=[DateRange(start_date=start, end_date=end)],
        limit=50,
    )
    response = client.run_report(request)

    rows = []
    for row in response.rows:
        entry = {}
        for i, dim in enumerate(dimensions):
            entry[dim] = row.dimension_values[i].value
        for i, met in enumerate(metrics):
            val = row.metric_values[i].value
            entry[met] = float(val) if "." in val else int(val)
        rows.append(entry)
    return rows


def safe_change_pct(current, previous):
    if previous == 0:
        return 100.0 if current > 0 else 0.0
    return round(((current - previous) / previous) * 100, 1)


def collect_weekly(client, property_id, start, end, comp_start, comp_end):
    """Collect full weekly report data."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    # -- Summary metrics (current vs previous period) --
    summary_metrics = [
        "sessions",
        "totalUsers",
        "newUsers",
        "bounceRate",
        "averageSessionDuration",
        "conversions",
        "screenPageViews",
    ]
    current_totals = run_report(client, property_id, [], summary_metrics, start, end)
    prev_totals = run_report(
        client, property_id, [], summary_metrics, comp_start, comp_end
    )

    if current_totals and prev_totals:
        cur = current_totals[0]
        prev = prev_totals[0]
        for metric in summary_metrics:
            c = cur.get(metric, 0)
            p = prev.get(metric, 0)
            data["summary"][metric] = {
                "current": c,
                "previous": p,
                "change_pct": safe_change_pct(c, p),
            }

    # -- Top landing pages --
    pages = run_report(
        client,
        property_id,
        ["landingPagePlusQueryString"],
        ["sessions", "bounceRate", "conversions", "averageSessionDuration"],
        start,
        end,
    )
    data["top_items"].extend(
        [
            {"type": "landing_page", **p}
            for p in sorted(pages, key=lambda x: x.get("sessions", 0), reverse=True)[
                :20
            ]
        ]
    )

    # -- UTM campaign performance --
    campaigns = run_report(
        client,
        property_id,
        ["sessionCampaignName", "sessionSource", "sessionMedium"],
        ["sessions", "totalUsers", "conversions", "bounceRate"],
        start,
        end,
    )
    prev_campaigns = run_report(
        client,
        property_id,
        ["sessionCampaignName", "sessionSource", "sessionMedium"],
        ["sessions", "totalUsers", "conversions", "bounceRate"],
        comp_start,
        comp_end,
    )
    # Index previous period by campaign key
    prev_by_key = {}
    for c in prev_campaigns:
        key = f"{c.get('sessionCampaignName', '')}|{c.get('sessionSource', '')}|{c.get('sessionMedium', '')}"
        prev_by_key[key] = c

    for c in sorted(
        campaigns, key=lambda x: x.get("sessions", 0), reverse=True
    )[:15]:
        key = f"{c.get('sessionCampaignName', '')}|{c.get('sessionSource', '')}|{c.get('sessionMedium', '')}"
        prev = prev_by_key.get(key, {})
        prev_sessions = prev.get("sessions", 0)
        cur_sessions = c.get("sessions", 0)
        if cur_sessions > 0 or prev_sessions > 0:
            change = safe_change_pct(cur_sessions, prev_sessions)
            direction = "rising" if change > 20 else "falling" if change < -20 else None
            if direction or cur_sessions >= 10:
                data["top_items"].append({"type": "utm_campaign", **c})
            if direction:
                data["trends"].append(
                    {
                        "item": f"campaign:{c.get('sessionCampaignName', 'direct')} ({c.get('sessionSource', '')}/{c.get('sessionMedium', '')})",
                        "direction": direction,
                        "metric": "sessions",
                        "current_value": cur_sessions,
                        "previous_value": prev_sessions,
                        "change_pct": change,
                    }
                )

    # -- Traffic source breakdown --
    sources = run_report(
        client,
        property_id,
        ["sessionDefaultChannelGroup"],
        ["sessions", "totalUsers", "conversions"],
        start,
        end,
    )
    data["top_items"].extend(
        [{"type": "channel_group", **s} for s in sources[:10]]
    )

    # -- Anomaly detection: pages with >30% bounce rate increase --
    prev_pages = run_report(
        client,
        property_id,
        ["landingPagePlusQueryString"],
        ["sessions", "bounceRate"],
        comp_start,
        comp_end,
    )
    prev_page_map = {
        p["landingPagePlusQueryString"]: p for p in prev_pages
    }
    for p in pages:
        path = p["landingPagePlusQueryString"]
        prev_p = prev_page_map.get(path)
        if prev_p and p.get("sessions", 0) >= 10:
            bounce_delta = p.get("bounceRate", 0) - prev_p.get("bounceRate", 0)
            if abs(bounce_delta) > 0.15:  # >15 percentage point shift
                data["anomalies"].append(
                    {
                        "metric": "bounceRate",
                        "dimension": f"page:{path}",
                        "expected": prev_p.get("bounceRate", 0),
                        "actual": p.get("bounceRate", 0),
                        "deviation_pct": round(bounce_delta * 100, 1),
                        "severity": "high" if abs(bounce_delta) > 0.3 else "medium",
                    }
                )

    return data


def collect_anomaly(client, property_id, start, end, comp_start, comp_end):
    """Collect anomaly-focused data: compare yesterday to same day last week."""
    data = {"summary": {}, "top_items": [], "trends": [], "anomalies": []}

    metrics = ["sessions", "totalUsers", "bounceRate", "conversions"]
    cur = run_report(client, property_id, [], metrics, start, end)
    prev = run_report(client, property_id, [], metrics, comp_start, comp_end)

    if cur and prev:
        c, p = cur[0], prev[0]
        for m in metrics:
            cv, pv = c.get(m, 0), p.get(m, 0)
            change = safe_change_pct(cv, pv)
            data["summary"][m] = {
                "current": cv,
                "previous": pv,
                "change_pct": change,
            }
            # Flag large deviations
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

    # Check top pages for traffic drops
    pages_cur = run_report(
        client,
        property_id,
        ["landingPagePlusQueryString"],
        ["sessions"],
        start,
        end,
    )
    pages_prev = run_report(
        client,
        property_id,
        ["landingPagePlusQueryString"],
        ["sessions"],
        comp_start,
        comp_end,
    )
    prev_map = {p["landingPagePlusQueryString"]: p.get("sessions", 0) for p in pages_prev}

    for p in pages_cur:
        path = p["landingPagePlusQueryString"]
        cur_s = p.get("sessions", 0)
        prev_s = prev_map.get(path, 0)
        if prev_s >= 10:
            change = safe_change_pct(cur_s, prev_s)
            if abs(change) > 40:
                data["anomalies"].append(
                    {
                        "metric": "sessions",
                        "dimension": f"page:{path}",
                        "expected": prev_s,
                        "actual": cur_s,
                        "deviation_pct": change,
                        "severity": "high" if abs(change) > 60 else "medium",
                    }
                )

    return data


def main():
    parser = argparse.ArgumentParser(description="GA4 source plugin")
    parser.add_argument("--mode", required=True, choices=["weekly", "anomaly"])
    parser.add_argument("--domain", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    env_err = check_env()
    if env_err:
        # Write error output so downstream knows this source is misconfigured
        result = {
            "source": "ga4",
            "domain": args.domain,
            "mode": args.mode,
            "period": {},
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "error": env_err,
            "data": {},
        }
        with open(args.output, "w") as f:
            json.dump(result, f, indent=2)
        print(f"GA4: {env_err}", file=sys.stderr)
        sys.exit(1)

    property_id = os.environ["GA4_PROPERTY_ID"]
    start, end, comp_start, comp_end = date_ranges(args.mode)

    client = get_client()

    if args.mode == "weekly":
        data = collect_weekly(client, property_id, start, end, comp_start, comp_end)
    else:
        data = collect_anomaly(client, property_id, start, end, comp_start, comp_end)

    result = {
        "source": "ga4",
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
    print(f"GA4: {args.mode} collected, {anomaly_count} anomalies, {trend_count} trends")


if __name__ == "__main__":
    main()
