# Marketing Intelligence Monitor

Cross-source analytics monitor for encypher.com. Aggregates data from Google Analytics 4, Google Search Console, and Zoho SalesIQ, then uses LLM triage to surface actionable marketing insights.

## How it works

1. **Source collection** (`sources/_runner.sh`): Runs each enabled source plugin to pull analytics data into standardized JSON.
2. **LLM triage** (`PROMPT.md` or `ANOMALY_PROMPT.md`): Claude analyzes the merged data, cross-correlates signals across sources, and writes a report.
3. **Sub-agent review** (`REVIEW_PROMPT.md`): For HIGH-priority insights, a sub-agent performs a deep-dive investigation.
4. **Discord notification**: Actionable findings are delivered to the #marketing-intel channel.

Two run modes:
- **Weekly** (Monday 9am): Full cross-source report with trend analysis and strategic recommendations.
- **Anomaly** (Tue-Sat 8:30am): Lightweight check comparing yesterday to the same day last week. Only alerts on significant deviations.

## Setup

### 1. Create the .env file

```bash
cp .env.template .env
```

Fill in the API credentials for each source you want to enable.

### 2. Google Analytics 4

1. Create a service account in Google Cloud Console.
2. Enable the Google Analytics Data API (v1beta).
3. Grant the service account "Viewer" access on your GA4 property.
4. Download the JSON key file and set `GA4_CREDENTIALS_PATH` to its path.
5. Set `GA4_PROPERTY_ID` to your property ID (format: `properties/XXXXXXXXX`).

### 3. Google Search Console

1. Use the same service account or create a new one.
2. Enable the Search Console API in Google Cloud Console.
3. Add the service account email as a user in [Search Console](https://search.google.com/search-console/users) with "Full" permission.
4. Set `GSC_SITE_URL` to your site URL (format: `sc-domain:encypher.com` for domain property).
5. Set `GSC_CREDENTIALS_PATH` to the service account JSON key file.

### 4. Zoho SalesIQ

1. Register a Server-based Application in the [Zoho API Console](https://api-console.zoho.com/).
2. Generate an access token with scopes: `SalesIQ.visitors.READ`, `SalesIQ.analytics.READ`.
3. Set `ZOHO_SALESIQ_APP_ID` to your portal ID.
4. Set `ZOHO_SALESIQ_ACCESS_TOKEN` to the access token.
5. (Optional) Set `ZOHO_SALESIQ_REFRESH_TOKEN`, `ZOHO_SALESIQ_CLIENT_ID`, and `ZOHO_SALESIQ_CLIENT_SECRET` for automatic token refresh.

### 5. Discord webhook

Create a webhook in your #marketing-intel Discord channel and set `DISCORD_WEBHOOK_URL`.

### 6. Enable/disable sources

Edit `sources.conf` to toggle sources:

```
ga4=1
gsc=1
zoho_salesiq=0   # disabled
```

### 7. Install Python dependencies

The source plugins use these packages:

```bash
pip install google-analytics-data google-auth google-api-python-client
```

Zoho SalesIQ uses only stdlib (`urllib`), no extra dependencies.

### 8. Cron

Add to crontab (or use the entries documented in `cron-wrapper.sh`):

```cron
# Weekly full report: Monday 9am
0  9 * * 1    /home/developer/code/agent-monitor/cron-wrapper.sh marketing-intel

# Daily anomaly check: Tue-Sat 8:30am
30 8 * * 2-6  /home/developer/code/agent-monitor/cron-wrapper.sh marketing-intel --anomaly
```

## Manual runs

```bash
# Weekly report
./run.sh marketing-intel

# Anomaly check
./run.sh marketing-intel --anomaly

# Force lookback (ignore last-check timestamp)
./run.sh marketing-intel --lookback

# Reset state (clear seen items)
./run.sh marketing-intel --reset

# Skip sub-agent reviews
./run.sh marketing-intel --no-review
```

## Adding a new source

1. Create `sources/<name>.py` implementing this interface:

```bash
python3 <name>.py --mode <weekly|anomaly> --domain <domain> --output <path>
```

The script must write a JSON file to `<path>` conforming to `sources/_schema.json`:

```json
{
  "source": "<name>",
  "domain": "encypher.com",
  "mode": "weekly",
  "period": {"start": "2026-03-24", "end": "2026-03-30", ...},
  "collected_at": "2026-03-31T09:00:00Z",
  "data": {
    "summary": {},
    "top_items": [],
    "trends": [],
    "anomalies": []
  }
}
```

2. Add `<name>=1` to `sources.conf`.
3. Add any required env vars to `.env`.

The `_runner.sh` script auto-discovers and executes all enabled sources. No changes to prompts or framework code needed.

## Directory structure

```
monitors/marketing-intel/
  README.md               # This file
  monitor.conf            # Display name, lookback hours, embed color
  .env.template           # API key template (copy to .env)
  .env                    # Actual API keys (gitignored)
  sources.conf            # Enable/disable sources
  sources/
    _schema.json          # Standardized output schema
    _runner.sh            # Source orchestrator
    ga4.py                # Google Analytics 4 plugin
    gsc.py                # Google Search Console plugin
    zoho_salesiq.py       # Zoho SalesIQ plugin
  PROMPT.md               # Weekly triage prompt
  ANOMALY_PROMPT.md       # Daily anomaly prompt
  REVIEW_PROMPT.md        # Deep-dive review prompt
  pre-check.sh            # Runs sources, gates on data freshness
```
