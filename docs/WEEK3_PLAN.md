# ARGUS — Week 3 Plan: Intelligence Layer

*Created by TCC.* Week 3 turns ARGUS from "detects signals" into "discovers typologies,
builds evidence-backed findings, refuses when evidence is thin, and drafts filings" —
with a multi-agent Orchestrator and a Streamlit investigator app. Every step is a
recorded CoCo session with an independent verification afterwards (same pattern as
Weeks 1–2, see `evidence/README.md`).

## Design correction carried into Week 3

The Week 2 twin maps obligations to **answer-key ring IDs** (`RING-001`, ...). A real
system cannot know those IDs — it *discovers* typologies. Compliance teams map
**typology classes** to obligations ("fan-in/fan-out mule networks → CBUAE Art. 31,
SAMA Art. 8, FATF 16.4, CBB FC-6.1"). So:
- the twin gets `TYPOLOGY_CLASS` + `TYPOLOGY_CLASS_OBLIGATION` (class → obligation);
- `TYPOLOGY_EXPOSURE` joins **discovered** typologies to obligations through their class;
- answer-key IDs never live in governed tables; tests match a discovered typology to a
  planted ring **by member overlap** (Jaccard), then check its obligations and gaps.

## Sessions

| Session | Builds | Acceptance (verified independently) |
|---|---|---|
| **S8** Typology discovery | Graph expansion from seed signals (hubs, structuring, shared identity, alerts) over transfer + identity edges → communities → roles (source mule, funnel, consolidation, layering hop, shared identity) → `TYPOLOGY` + `TYPOLOGY_EVIDENCE` + plain-English **typology cards** + a re-runnable **detection query** per typology; class-based twin mapping; validators updated to overlap matching | Every planted ring discovered; **RING-001/005 source mules ≥ 8/9 each** (Week 2: 0/9); BENIGN-001 **not** escalated; ≤ 1 clean account inside any typology; live RING-006 discovered after a feed replay; Week 2 + Analyst suites still pass |
| **S9** Findings, evidence ledger, Verifier | `FINDING`, `FINDING_CLAIM` (each claim → ≥1 transaction ref **and** ≥1 regulation clause ref, with confidence), `FILING`; `SP_BUILD_FINDING`, `SP_VERIFY_FINDING` (guardrail), `SP_DRAFT_FILING` (regulator-format STR narrative from verified claims only, past filings as style exemplars) | Mule-ring finding verified and filing drafted with citations; a thin-evidence case **refused with a reason**; an unsupported claim **rejected**; no filing without verification |
| **S10** Multi-agent Orchestrator | A **Cortex Agent** orchestrator with tools: Cortex Analyst (both semantic views), Cortex Search (`POLICY_SEARCH`), and custom tools (the S8/S9 procedures); question splitting ("why flagged" → evidence, "should we file" → Verifier); agent evaluation | Answers the ontology questions end-to-end with citations; routes the filing decision to the Verifier; declines ungrounded questions |
| **S11** Streamlit investigator app | Streamlit in Snowflake: live feed control, typology/ring view, finding with clickable citations, filing draft review, "Ask ARGUS" chat to the Orchestrator | Runs in Snowsight as the least-privilege analyst role; PII masked; demo path works start to finish |

## Guardrails for all Week 3 sessions
- No answer-key data in governed tables; test harnesses use session-TEMPORARY tables.
- Graph logic in SQL / Snowflake scripting — no third-party packages, no terms acceptance.
- Live-feed replays must end with `SP_RESET_LIVE_DEMO()` and the root task suspended.
- If anything needs accepting terms or new account-level settings, stop and report.
