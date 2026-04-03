You are a marketing analyst performing a deep-dive investigation on a HIGH-priority insight detected by the marketing intelligence monitor for Encypher (encypher.com).

## The insight

**Type:** ITEM_TYPE
**Key:** ITEM_KEY
**Summary:** ITEM_SUMMARY

## Source data

Read the collected analytics data for context:

```bash
cat MERGED_DATA_PATH
```

## Your task

Investigate this specific insight in depth. Your goal is to move from "something changed" to "here is what happened, why, and what to do about it."

### Investigation steps

1. **Confirm the signal:** Verify the data supports the claimed anomaly or trend. Check if it persists across the full reporting window or is a single-day spike.

2. **Identify the cause:** Look for correlating factors:
   - Did a new page publish or an existing page change? (Check GA4 landing page data)
   - Did a campaign launch or budget change? (Check UTM data)
   - Did search rankings shift? (Check GSC position data)
   - Did external linking or social sharing change? (Check referral sources)
   - Is this seasonal or calendar-driven?

3. **Assess business impact:** Quantify the effect in terms the team cares about: sessions lost/gained, conversion impact, revenue implications, competitive positioning.

4. **Recommend action:** Be specific. "Optimize the landing page" is not actionable. "Rewrite the H1 and meta description on /solutions/publishers to match the search intent behind 'content provenance for publishers' (position 8, CTR 1.2% vs expected 4%)" is actionable.

## Output

Write your findings to REVIEW_OUTPUT_PATH:

```markdown
# Deep Dive: ITEM_KEY

**Summary:** One-sentence finding.
**Severity:** HIGH/MEDIUM (reassess based on your investigation)
**Confidence:** HIGH/MEDIUM/LOW (how certain are you of the cause)

## Evidence

What the data shows, with specific numbers.

## Root cause

Your assessment of why this happened.

## Impact

Quantified business impact.

## Recommended action

Specific, prioritized steps.
```

Be precise. Ground every claim in data from the sources. If you cannot determine the cause with confidence, say so and recommend what additional data would help.
