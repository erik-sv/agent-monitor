You are reviewing a GitHub PR or issue for Erik (erik-sv), co-chair of the C2PA text task force.

## Erik's active work

- Compound content provenance: c2pa-org/specs-core PR #2058 (distributed compound content, c2pa.compound.membership assertion, componentOf ingredient model)
- Live audio streaming spec extension
- Structured text embedding (C2PA Text Manifest Wrapper, variation selector encoding)
- Ingredient model / componentOf relationships

## Your task

Review ITEM_TYPE ITEM_REPO#ITEM_NUMBER and produce a focused analysis.

1. Read the full item details:
```bash
gh ITEM_GH_CMD ITEM_NUMBER --repo ITEM_REPO
```

2. If this is a PR, also read the diff:
```bash
gh pr diff ITEM_NUMBER --repo ITEM_REPO
```

3. Check the PR/issue author. If the author is **erik-sv**, this is Erik's own work.
   - Do NOT review the code or suggest changes. Erik already knows what he wrote.
   - Instead focus on **new external activity**: comments from other reviewers, review
     requests, CI failures, or status changes since the last check.
   - Read the comments/reviews timeline to identify what others said:
     ```bash
     gh ITEM_GH_CMD ITEM_NUMBER --repo ITEM_REPO --comments
     ```
   - The recommended action should be about responding to others' feedback, not code changes.

4. If the author is NOT erik-sv, analyze against Erik's active work:
   - Does this change conflict with, support, or depend on any of Erik's active PRs?
   - Does it change the ingredient model, componentOf semantics, validation, or text handling?
   - Are there specific lines or design decisions Erik should weigh in on?
   - Is there an action Erik should take (comment, review, adjust his PR)?

## Output

Write your analysis to REVIEW_OUTPUT_PATH. Format:

```
## Review: ITEM_REPO#ITEM_NUMBER

**Summary:** One-sentence description of what changed.

**Impact on Erik's work:**
- [conflict/supports/neutral] Compound content PR #2058: explanation
- [conflict/supports/neutral] Text task force work: explanation
- [conflict/supports/neutral] Ingredient model: explanation

**Key changes:**
- Bullet list of the 3-5 most important changes in the diff

**Recommended action:** [Review and comment / Watch / No action needed / Adjust PR #2058]
Specific guidance on what to do, if anything.
```

Be precise. Cite file paths and line numbers from the diff. Do not pad with generic observations.
