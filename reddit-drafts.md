# Reddit Post Drafts

Post Monday April 7, 9-10 AM Eastern. Independent text posts, not cross-posts.
Post your own first comment immediately on each.

---

## 1. r/AI_Agents

**Title:** I open-sourced a cron-driven agent that monitors GitHub repos and triages what matters

I track activity across several GitHub repos for a standards body. Five repos, dozens of PRs a week, most of them irrelevant to my work. The manual version of this, scanning each repo every few hours and reading the ones that look relevant, cost me 30-60 minutes a day in context-switching.

I built a small framework to automate it. A cron job fires every few hours, checks the GitHub API for new activity, and if anything changed, hands the results to Claude (via the Claude Code CLI) with a prompt that defines what "material" means for that monitor. The agent reads the PRs, assesses relevance, writes a report, and sends a Discord notification with only the items that need attention.

The key design choice: three layers of state tracking so you only pay for an LLM call when something actually changed.

1. A shell-level pre-check queries the GitHub API directly. If nothing is new, the run exits before the LLM is invoked. Zero cost.
2. The triage prompt receives a JSON file of previously reported items and skips anything that has not changed since last report.
3. After triage, new items merge into the state file for the next run.

In practice, 80-90% of cron ticks exit at step 1.

For high-priority items, an optional Phase 2 spawns parallel sub-agents that do deep-dive reviews of individual PRs, reading the diff, assessing impact, and recommending action.

The framework is monitor-agnostic. Each monitor is a directory with a config file, a prompt, and an optional pre-check script. The repo ships with three: a generic example, a security advisory watcher, and a release tracker.

It uses Claude Code CLI today, but the architecture is just "cron + CLI agent + state files." There is no reason this could not work with Codex CLI, Gemini CLI, or any other tool that accepts a prompt and can run shell commands. If someone wants to add a adapter for another harness, PRs are welcome.

GitHub: https://github.com/erik-sv/agent-monitor
License: Apache 2.0

---

### First comment (post immediately):

Author here. A few implementation notes:

- The triage agent runs on Sonnet for cost efficiency. Phase 2 review agents also default to Sonnet but can be overridden via env var.
- Each monitor gets its own state directory, log directory, and cron schedule. You can run as many monitors as you want independently.
- Discord is the only notification channel right now. Slack webhook support would be a straightforward addition.
- The `pre-check.sh` pattern is optional but recommended. It is the difference between $2/month and $20/month when you run multiple monitors on short cron intervals.

Happy to answer questions about the architecture or the prompt design.

---

## 2. r/ClaudeAI

**Title:** Open-sourced a Claude Code tool for automated GitHub repo monitoring

I needed a way to track activity across several GitHub repos without manually checking each one every few hours. GitHub notifications are a firehose, and the signal-to-noise ratio for someone tracking specific topics across multiple repos is poor.

I built a framework that runs Claude Code CLI on a cron schedule to triage GitHub activity. Each "monitor" is a directory containing a prompt that defines what matters (security issues, spec changes, releases, whatever you care about), a config file, and an optional pre-check script. The framework handles state tracking, deduplication, and Discord notifications.

The pre-check is the part that makes this practical for daily use. Before invoking Claude, a shell script queries the GitHub API to see if anything has changed since the last run. If not, the run exits immediately. No API call, no cost. In practice, most cron ticks cost nothing.

When the LLM does run, it receives the full history of previously reported items and skips anything that has not changed. For high-priority items, optional Phase 2 sub-agents run parallel deep-dive reviews of individual PRs.

The repo ships with three monitors you can use or adapt: a generic example, a security advisory watcher, and a release tracker.

GitHub: https://github.com/erik-sv/agent-monitor
License: Apache 2.0

The framework is just bash, `claude -p`, and `gh`. If anyone adapts the pattern for Codex CLI or Gemini CLI, I would be interested to see it.

---

### First comment:

For context, this replaced two separate monitoring scripts I was running for different sets of repos. The modular structure means adding a new monitor is just copying a directory and editing the prompt. The state management (seen-items.json, last-check.txt, delta merge) is handled by the framework, not the prompt.

---

## 3. r/ChatGPTCoding

**Title:** Built a framework for AI-powered GitHub monitoring, open-sourced it, looking for ports to other CLI agents

I track several GitHub repos for work and was spending 30+ minutes a day scanning for relevant activity. I built a cron-based framework that uses an LLM CLI tool to triage GitHub activity and surface only what matters.

The architecture is simple: cron fires, a shell script checks the GitHub API for new activity (cheap, no LLM call), and if something changed, it hands the data to an LLM agent with a prompt defining your materiality criteria. The agent reads the relevant PRs and issues, writes a report, and sends a Discord notification.

State tracking across runs prevents duplicate reporting. An optional second phase spawns parallel sub-agents for deep-dive reviews of high-priority items.

I built this on Claude Code CLI (`claude -p`), but the pattern is CLI-agnostic. The core loop is:

```
cron -> pre-check (shell) -> LLM triage (any CLI) -> state merge -> notify
```

If you use Codex CLI, Gemini CLI, or another tool that takes a prompt and can execute shell commands, this framework should work with minimal changes to the agent invocation in `lib/common.sh`. I would be interested to see someone adapt it.

The repo ships with three ready-to-use monitors: a generic example, a security advisory watcher, and a release tracker. Each monitor is a self-contained directory you copy and customize.

GitHub: https://github.com/erik-sv/agent-monitor
License: Apache 2.0

---

### First comment:

The main thing that makes this cost-effective is the pre-check gate. The `pre-check.sh` script queries the GitHub API directly before the LLM runs. If nothing has changed since the last run, it exits. No API credits spent. ~80-90% of cron ticks exit here in my usage.

When the LLM does run, a single Sonnet call typically costs $0.01-0.03. Running a monitor every 4 hours comes to under $2/month.

---

## 4. r/LocalLLaMA

**Title:** Cron + LLM triage: an open-source pattern for automated GitHub monitoring

I wanted to share a pattern I have been running for a few months: using an LLM agent on a cron schedule to monitor GitHub repos and surface only the activity that matters.

The problem: I track several repos for standards work. GitHub notifications do not filter by topic, so I was spending time every day scanning PRs and issues to find the ones relevant to my proposals. Most of what I checked was noise.

The solution is a bash framework with three layers:

1. **Shell pre-check.** Before any LLM call, a script queries the GitHub API for items updated since the last run. If nothing changed, the run exits. No model invocation, no cost.
2. **LLM triage.** When there is new activity, the framework interpolates a prompt template with the current state (timestamps, previously reported items) and runs it through a CLI agent. The agent reads the relevant PRs, assesses materiality against criteria you define, and writes a structured report.
3. **State merge.** After triage, a delta of newly reported items merges into a persistent JSON file. The next run receives this file in the prompt and skips items that have not changed.

An optional Phase 2 spawns parallel sub-agents for per-item deep-dive reviews on high-priority items.

Each monitor is a self-contained directory: a config, a prompt, and an optional pre-check script. The repo includes a security advisory monitor and a release tracker as practical examples.

I built this on Claude Code CLI, but the architecture is model-agnostic. The LLM invocation is a single function call in `lib/common.sh`. Swapping in a different CLI (Codex, Gemini, or a local model with a compatible wrapper) would require changing that one function.

GitHub: https://github.com/erik-sv/agent-monitor
License: Apache 2.0

---

### First comment:

The prompt design is where most of the tuning lives. Each monitor's `PROMPT.md` defines the materiality criteria (what counts as HIGH, MEDIUM, or SKIP), the GitHub API commands to run, and the output format (markdown report + optional Discord embed JSON). The framework handles interpolation and state; the prompt handles judgment.

For anyone running local models: the main constraint is that the agent needs to execute bash commands (gh CLI calls) to fetch PR data. Any CLI wrapper that supports tool use / code execution should work.

---

## 5. r/devops

**Title:** Automated GitHub repo monitoring with state-tracked dedup and Discord alerts

I track activity across several GitHub repos and needed a way to get notified about relevant changes without manually checking each repo or drowning in GitHub's default notification stream.

I built a cron-based monitoring framework. Each "monitor" defines a set of repos, materiality criteria, and a notification format. On each cron tick:

1. A pre-check script queries the GitHub API to see if anything has changed since the last run. If not, the run exits immediately.
2. If there is new activity, an LLM agent (Claude Code CLI, though the architecture is CLI-agnostic) reads the relevant PRs and issues, assesses materiality against your criteria, and writes a report.
3. A delta of newly reported items merges into a persistent state file (`seen-items.json`), so the next run skips items that have not changed.
4. If anything material was found, a Discord webhook fires with a structured embed.

Locking, log rotation, and state management are handled by the framework. Each monitor gets its own state directory, lock file, and cron schedule.

The repo ships with three monitors: a generic example, a security advisory watcher, and a release tracker. Adding a new one is copying a directory and editing the config and prompt.

```
monitors/
  security-advisories/
    monitor.conf        # LOOKBACK_HOURS, DISCORD_EMBED_COLOR, etc.
    PROMPT.md           # What to check, what matters, output format
    pre-check.sh        # Cheap API gate before LLM invocation
  release-tracker/
    ...
```

GitHub: https://github.com/erik-sv/agent-monitor
License: Apache 2.0

---

### First comment:

A few details on the operational side:

- `cron-wrapper.sh` sets PATH and redirects stdout/stderr to a per-monitor log file. Logs are pruned to the last 30 runs automatically.
- Lock files prevent overlapping runs. If a previous run is still alive, the new one exits cleanly.
- `--lookback` forces a full check window regardless of state. `--reset` clears the dedup file. Both bypass the pre-check.
- The LLM is Sonnet by default, overridable via `TRIAGE_MODEL` env var. Cost is $0.01-0.03 per invocation when it runs.
- Discord is the only notification target currently. The webhook payload is either LLM-generated (for flexible formatting) or shell-built from the structured delta (for monitors with Phase 2 sub-agent reviews).
