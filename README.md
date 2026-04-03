# agent-monitor

A cron-driven framework for monitoring GitHub repositories using Claude as a triage agent. Each monitor defines what to watch and how to assess materiality. The framework handles state tracking, deduplication, cost-efficient pre-checks, optional deep-dive sub-agent reviews, and Discord notifications.

## How it works

```
cron tick
  |
  v
pre-check.sh (cheap API query: anything new?)
  |
  no --> exit (zero LLM cost)
  yes
  |
  v
Phase 1: Sonnet triage (reads GitHub, writes report + delta.json)
  |
  v
State merge (delta.json -> seen-items.json for dedup)
  |
  v
Phase 2 (optional): parallel sub-agent reviews for HIGH items
  |
  v
Discord webhook notification
```

Each cron tick costs nothing when there is no new activity. The pre-check script queries the GitHub API directly and short-circuits before invoking Claude.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated
- `jq`
- A Discord webhook URL (optional, for notifications)

## Quick start

```bash
# 1. Clone
git clone https://github.com/erik-sv/agent-monitor.git
cd agent-monitor

# 2. Configure
cp .env.example .env
# Edit .env with your Discord webhook URL

# 3. Create a monitor from the example
cp -r monitors/example monitors/my-project
# Edit monitors/my-project/monitor.conf, PROMPT.md, and pre-check.sh

# 4. Run manually
./run.sh my-project --lookback

# 5. Add to crontab
crontab -e
# 15 */4 * * *  /path/to/agent-monitor/cron-wrapper.sh my-project
```

## Creating a monitor

Each monitor lives in `monitors/<name>/` and contains:

| File | Required | Purpose |
|------|----------|---------|
| `monitor.conf` | Yes | Shell variables: `LOOKBACK_HOURS`, `DISCORD_EMBED_COLOR`, `MONITOR_DISPLAY_NAME` |
| `PROMPT.md` | Yes | The triage agent prompt. Uses placeholder variables that get interpolated at runtime. |
| `pre-check.sh` | No | Cheap API gate. Exit 0 = changes found, exit 1 = skip. Prevents unnecessary LLM calls. |
| `REVIEW_PROMPT.md` | No | Per-item deep-dive prompt. Enables Phase 2 parallel sub-agent reviews for HIGH items. |
| `.env` | No | Per-monitor environment overrides (e.g. a different Discord webhook). |

### Prompt variables

These placeholders in `PROMPT.md` and `REVIEW_PROMPT.md` are interpolated at runtime:

| Variable | Value |
|----------|-------|
| `LAST_CHECK_TIME` | ISO 8601 timestamp of the previous run |
| `LAST_CHECK_DATE` | Date portion of the above (YYYY-MM-DD) |
| `DATE` | Today's date |
| `REPORT_OUTPUT_PATH` | Where the agent should write its markdown report |
| `DELTA_OUTPUT_PATH` | Where the agent should write delta.json (state tracking) |
| `DISCORD_OUTPUT_PATH` | Where the agent should write the Discord payload |
| `SEEN_ITEMS_JSON` | Contents of seen-items.json (for dedup in prompt) |

For `REVIEW_PROMPT.md`, additional variables are available:

| Variable | Value |
|----------|-------|
| `ITEM_REPO` | e.g. `owner/repo` |
| `ITEM_NUMBER` | e.g. `123` |
| `ITEM_TYPE` | `pr` or `issue` |
| `ITEM_GH_CMD` | `pr view` or `issue view` |
| `REVIEW_OUTPUT_PATH` | Where to write the review markdown |

## State management

State lives in `state/<monitor-name>/`:

- **`seen-items.json`** tracks every reported item with its `lastReportedUpdate` timestamp. The triage prompt receives this data and skips items that have not changed since last report.
- **`last-check.txt`** records when the monitor last ran. The next run queries only activity after this timestamp.
- **`delta.json`** (transient) holds newly reported items from the current run, then merges into `seen-items.json`.

The pre-check script runs before the LLM and exits early when no items have been updated since `last-check.txt`. This is the primary cost-saving mechanism.

## CLI flags

```
./run.sh <monitor-name> [--lookback] [--reset] [--no-review]
```

| Flag | Effect |
|------|--------|
| `--lookback` | Ignore `last-check.txt` and check the full `LOOKBACK_HOURS` window. Bypasses pre-check. |
| `--reset` | Clear `seen-items.json` and treat everything as new. Bypasses pre-check. |
| `--no-review` | Skip Phase 2 sub-agent reviews even if `REVIEW_PROMPT.md` exists. |

## Configuration

Global settings go in `.env` at the repo root. Per-monitor overrides go in `monitors/<name>/.env`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `DISCORD_WEBHOOK_URL` | (none) | Discord webhook for notifications |
| `DASHBOARD_BASE_URL` | (none) | Base URL for session links in Discord embeds |
| `TRIAGE_MODEL` | `claude-sonnet-4-6` | Model for Phase 1 triage |
| `REVIEW_MODEL` | `claude-sonnet-4-6` | Model for Phase 2 reviews |

## Discord notifications

Two notification modes are supported:

1. **LLM-generated payload:** The triage prompt writes a Discord-ready JSON file directly. Best for monitors where the LLM should control formatting (e.g. a GitHub activity monitor with urgency tiers).

2. **Shell-built embed:** The framework reads `delta.json` and builds a Discord embed from HIGH items, appending review findings and dashboard links. Best for monitors with structured delta output and Phase 2 reviews.

The mode is selected automatically based on which output files the triage agent produces.

## License

Apache 2.0. See [LICENSE](LICENSE).
