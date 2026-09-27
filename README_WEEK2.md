# ARGUS — Week 2 Deliverables

*Created by TCC · Snowflake CoCo Hack (GCC Edition)*

Week 2 = **Development: semantic layer + regulatory twin**. The semantic views
and verified queries are authored from the ontology and **validated against its
natural-language questions** — 6/6 pass against the planted ground truth.

## What's new

```
sql/03_semantic_views.sql          # argus_fraud_sv (PII-free) + argus_regtwin_sv for Cortex Analyst
sql/05_regulatory_twin.sql         # regulation -> clause -> obligation -> control, control_gap, typology_exposure
semantic/verified_queries.yaml     # one verified query per ontology NL question (Q1–Q6)
policy_corpus/*.md                 # synthetic CBUAE + FATF texts (stand-in for Google Drive MCP docs)
data/twin_seed.json                # twin seed: single source of truth, mirrored by 05_regulatory_twin.sql
validation/validate_week2.py       # offline validator (stdlib sqlite) vs ground truth
validation/week2_validation_report.md  # generated evidence for the Testing phase
```

## Live on Snowflake ✅
Deployed to the trial account (GCP **me-central2 / Dammam, KSA**) via the `argus`
connection — key-pair auth, shared by the Snowflake CLI and CoCo
(`cortex connections list` shows `argus` active).

| Object | State |
|---|---|
| `ARGUS_WH` | X-Small, auto-suspend 60s (protects trial credits) |
| `ARGUS.RAW` | 5 tables loaded — 3 / 540 / 627 / 1,606 / 8,747 rows, **0 load errors** |
| `ARGUS.CURATED` | `account_activity`, `structuring_candidates` |
| `ARGUS.GOVERNED` | clean-room views, twin tables, `control_gap`, `typology_exposure` |
| Semantic views | `ARGUS_FRAUD_SV`, `ARGUS_REGTWIN_SV` — compiled first time, answer `SEMANTIC_VIEW()` queries |

### Run order (full rebuild)
```
00_setup_warehouse.sql
  -> upload data/*.csv + data/twin_seed.json + data/live_feed.csv  to @ARGUS.RAW.ARGUS_STAGE
01_raw_schema.sql            RAW tables + load + curated views
02_clean_room.sql            hashed cross-bank signal
05_regulatory_twin.sql       twin loaded from twin_seed.json on the stage
06_pipelines.sql             live queue, stream, task graph, dynamic tables, alerts
08_documents.sql             PDFs -> DOCUMENTS -> chunks -> Cortex Search -> extraction
09_drive_ingestion.sql       Google Drive lineage + change detection (run via CoCo + MCP)
semantic/*.yaml              deploy with `cortex agent-studio sv-deploy` (needs 05 + 06)
07_governance_clean_room.sql roles, row isolation, PII masking, secure signal (run last)
```
`03_semantic_views.sql` is the original Week 2 DDL, kept for history; the deployed
semantic views are defined by `semantic/argus_fraud_sv.yaml` and
`semantic/argus_regtwin_sv.yaml` (extended in CoCo sessions S6/S6b).

Upload one file at a time (Windows shells expand wildcards before `snow` sees them):
```bash
snow stage copy data/transactions.csv @ARGUS.RAW.ARGUS_STAGE -c argus --overwrite
```

## Validate
Same checks, two backends — the numbers must match:
```bash
python validation/validate_week2.py                                   # offline (sqlite)
.venv/Scripts/python validation/validate_week2.py --backend snowflake  # real warehouse
```
**Both: 6/6 pass, identical figures.** The Snowflake run executes the real SQL from
`semantic/verified_queries.yaml`; Q6's ring-membership stand-in is a session
TEMPORARY table, so no test data persists in `GOVERNED`.

| # | Natural-language question | Result |
|---|---|---|
| Q1 | Show me emerging cross-bank fraud we're exposed to this week | ✅ both mule-ring hubs, 0 false positives |
| Q2 | Why was account X flagged, and should we file? | ✅ ring → ESCALATE · benign → MONITOR · clean → NO BASIS |
| Q3 | Which accounts share a device or national ID across banks? | ✅ RING-002 at 3 banks ranked above benign device |
| Q4 | Cash deposits just under the reporting threshold | ✅ exactly the structuring account (10 deposits, ~AED 532k) |
| Q5 | Which obligations does this typology touch; are controls adequate? | ✅ mule ring → HIGH gaps (CBUAE Art. 31, FATF 16.4); structuring → covered |
| Q6 | Total value through the ring's funnel accounts | ✅ ~AED 373k (RING-001), ~AED 400k (RING-005) |

## Design decisions worth showing judges
- **Governed by construction:** the semantic view exposes no raw PII — only risk ratings and salted hashes. A compliance user *cannot* ask for a national ID.
- **Scope-aware control gaps:** a control only covers an obligation if it's active **and** its scope matches. A single-bank KYC check can't satisfy a cross-bank obligation — that's precisely the blind spot ARGUS exposes.
- **The correlation loop works on data:** Q5 shows the demo climax — a discovered mule ring maps to CBUAE Art. 31 + FATF 16.4, and control C-12 (cross-institution monitoring) is `not_deployed` → HIGH gap. The structuring ring, by contrast, is covered by an active control — ARGUS doesn't cry wolf.
- **Hard negative included:** a household sharing a tablet across two banks is surfaced as a weak signal but held at MONITOR, not escalated.

## Known limitation (by design — motivates Week 3)
Per-account evidence finds **0/9** of RING-001's source mules: they only move
money inside their own bank, so no single-account rule can see them. They must
be reached by **graph expansion from the hub** — that's the Week 3 Typology agent.

## Fixes made this week
- **Device noise:** Week 1 logins drew from a random device pool, which created 165 accidental cross-bank device collisions and made the device signal useless. Devices are now bound to customers → only the ring device and the deliberate benign case cross banks.
- **Clean-room privacy:** counterparty IBANs are now hashed before entering the clean room (they were passing raw).

## Next — Week 3
Typology-discovery engine (graph expansion that recovers the source mules), the
correlation engine writing `typology_evidence` for real (replacing the
ground-truth stand-in), the evidence ledger + Verifier/guardrail agent, and the
Streamlit investigator app.
