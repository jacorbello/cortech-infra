# Risk Check Prompt v1

You are reviewing a draft outreach reply or post for the PlotLens founder. Score the draft on a 0-100 risk scale.

- **0-20**: Safe to auto-quick-approve. No claims about features that don't exist, no pricing, no competitor mentions, no controversial takes, no apology-style replies, no spam patterns.
- **21-50**: Needs human review but probably fine.
- **51-100**: Flag for careful review. Examples: mentions specific roadmap features, makes a quantitative product claim, replies to a sensitive topic (mental health, harassment, AI ethics debate), uses absolute language ("always", "best", "only").

## Draft

Platform: {{recommended_destination}}
Variant: {{variant}}
Text:
> {{draft_text}}

## Source context

> {{source_excerpt}}

## Output

Return JSON:

```json
{
  "risk_score": 0,
  "reasons": ["short phrase", "..."]
}
```

Only return the JSON. No prose around it.
