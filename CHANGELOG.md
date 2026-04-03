# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] - 2026-04-03

### Added
- Modular monitor framework with shared triage, review, and notification pipeline
- GitHub Activity monitor (`gh-activity`): tracks notifications, PRs, issues involving configured user
- C2PA Repository monitor (`c2pa`): tracks specs-core, c2pa-rs, c2pa-text repos for standards work
- Marketing Intelligence monitor (`marketing-intel`): cross-source analytics aggregation
  - Pluggable source framework with standardized JSON schema
  - Google Analytics 4 source plugin (traffic, UTM, landing pages, bounce rates)
  - Google Search Console source plugin (queries, CTR, position, impressions)
  - Zoho SalesIQ source plugin (visitors, chats, page engagement)
  - Weekly full report with cross-source correlation analysis
  - Daily anomaly detection mode (`--anomaly` flag)
  - Sub-agent deep-dive reviews for HIGH-priority insights
- Shared library (`lib/common.sh`): lock management, state tracking, triage spawning, Discord delivery
- Cron wrapper for scheduled execution with log capture
- Deduplication via `seen-items.json` state persistence
- Discord webhook notification with embed formatting
- AgentDesk dashboard link injection for review sessions
- Per-monitor `.env` overrides and configurable lookback windows
