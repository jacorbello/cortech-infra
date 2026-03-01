# INVESTIGATIONS.md - Quick Reference

> **Full process documentation:** `~/clawd/projects/investigations/INVESTIGATION_PROCESS.md`

## Branding

All investigation work is labeled **Cortech Investigations**.

## What This Is

Attorney-requested OSINT investigations. We gather evidence, maintain chain of custody, and produce court-admissible reports.

## Key Principles

- **Legal compliance** — Only legal, ethical collection methods
- **Chain of custody** — Every piece of evidence documented with timestamps and hashes
- **Source attribution** — Every claim backed by cited sources
- **Confidence ratings** — HIGH / MEDIUM / LOW / UNVERIFIED

## Case Storage

MinIO bucket: `homelab/investigations/`

```
investigations/
└── [case-slug]/
    ├── case-metadata.json      # Case info and status
    ├── evidence-register.json  # Chain of custody log
    ├── INVESTIGATIVE_REPORT.md # Primary deliverable
    ├── RESEARCH_PLAN.md        # Methodology
    └── evidence/               # Raw evidence files
```

## Case ID Format (Internal)

`INV-YYYY-NNN` (e.g., INV-2026-001)

Sequential internal case numbers for tracking. These are Cortech's internal reference — attorneys may have their own case numbers which we track separately in case metadata.

## Case Lifecycle

`Intake → Active → Review → Delivered → Complete`

## CLI Tools

```bash
inv new                         # Create new case
inv status [case-id]            # Check status
inv evidence add [case-id] <file>  # Log evidence
inv archive <url> [case-id]     # Archive URL
inv search <query>              # Search across cases
```

## Evidence Handling

1. **Capture** — Screenshot with URL/timestamp visible
2. **Hash** — `sha256sum file > file.sha256`
3. **Log** — Add to evidence-register.json
4. **Upload** — `/tmp/mc cp file homelab/investigations/[case]/evidence/`

## Report Structure

1. Executive Summary (key findings table)
2. Scope and Methodology
3. Subject Profile(s)
4. Evidence Analysis
5. Findings and Conclusions
6. Recommended Actions
7. Source Citations

## Infrastructure

| Service | Purpose | Access |
|---------|---------|--------|
| MinIO | Case file storage | 192.168.1.118 |
| Qdrant | Semantic search | 192.168.1.91:30333 |
| theHarvester | Automated OSINT (40+ sources) | 192.168.1.91:30502 |
| ArchiveBox | Web archiving | 192.168.1.91:30800 |
| n8n | Workflow automation | https://n8n.corbello.io |
| Typst | PDF report generation | local CLI |

## Quick Commands

```bash
# OSINT scan
curl -X POST http://192.168.1.91:30502/search -d '{"domain":"example.com"}'

# Archive URL with case tag
archivebox-submit -c INV-2026-001 https://example.com

# Generate PDF report
typst compile report.typ INV-2026-001_Subject_Report_v1_2026-01-28.pdf

# Create timeline visualization
mmdc -i timeline.mmd -o timeline.png
```

## When Starting an Investigation

1. Read the full process doc: `~/clawd/projects/investigations/INVESTIGATION_PROCESS.md`
2. Use `inv new` to create case structure
3. Follow the 5-phase OSINT methodology
4. Maintain evidence register throughout
5. Generate report using templates

---

*For detailed templates, workflows, and methodology: see full process document.*
