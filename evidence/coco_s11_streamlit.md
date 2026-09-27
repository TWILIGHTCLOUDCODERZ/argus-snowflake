# ARGUS — CoCo Session S11: Streamlit Investigator App

*Created by TCC · CoCo Session S11*

## What was built

A five-section Streamlit-in-Snowflake investigator app for compliance analysts,
plus governance infrastructure (demo wrapper procedures, RBAC grants), and a
typology ID stability fix.

### Pages

| Page | Function |
|---|---|
| **Overview** | KPIs (typologies by class, open live alerts, control gaps by regulator), live feed panel with "Deliver Next Batch" / "Reset Demo" buttons, batch counter, live alerts table |
| **Typologies** | List with class, banks, value, member count; typology card (markdown); member table by role; ring diagram via `st.graphviz_chart` (source mules → funnels → consolidation, coloured by bank); detection SQL; "Run Rediscovery" button |
| **Finding** | Claims table (type, text, confidence, verified flag); selecting a claim shows cited transactions (PII masked) and cited clause text; verifier status and reason prominent |
| **Filing Review** | Per-bank STR drafts and board memo, grounding check result, "Approve Draft" button (sets `approved_by = CURRENT_USER(), status = 'APPROVED'`) — nothing is sent; delivery deferred to Week 4 |
| **Ask ARGUS** | Chat interface calling the S10 orchestrator; shows answer with citations and expandable handoff trace from `AGENT_RUN_LOG` |

### Governance model

- **Streamlit owner: `ARGUS_ANALYST`** — not ACCOUNTADMIN. Every viewer sees PII masked
  via tag-based masking policies (full_name, national_id, phone, email, dob → `***MASKED***`).
- **Demo wrapper procedures** (`SP_DEMO_NEXT_BATCH`, `SP_DEMO_REDISCOVER`, `SP_DEMO_RESET`)
  execute as OWNER (ACCOUNTADMIN) so the analyst can drive the demo without direct write
  access to RAW or GOVERNED tables. Granted to ARGUS_ANALYST with USAGE.
- S9 procedures (`SP_BUILD_FINDING`, `SP_VERIFY_FINDING`, `SP_DRAFT_FILING`) also granted
  USAGE to ARGUS_ANALYST for the orchestrator path.
- `UPDATE ON FILING` granted for the "Approve Draft" button.
- `INSERT ON AGENT_RUN_LOG` granted for orchestrator handoff logging.
- `CREATE STREAMLIT` and `CREATE STAGE` on `ARGUS.GOVERNED` for deployment.

### Typology ID stability fix

`SP_DISCOVER_TYPOLOGIES` previously assigned IDs via `ROW_NUMBER() OVER (ORDER BY component_id)`,
which could shift all IDs when new components formed from live data. Fixed by:
1. Fingerprinting each typology's sorted member list before deletion.
2. Matching new components against existing fingerprints.
3. Reusing the same `typology_id` when the member set matches; new IDs only for genuinely
   new typologies (`TYP-NNNN` where NNNN = max existing + sequential).
4. Preserving existing `card_md` and `detection_sql` for reused typologies (skipping LLM calls).

### Files

| File | Purpose |
|---|---|
| `app/streamlit_app.py` | Streamlit app (503 lines, 5 sections) |
| `app/snowflake.yml` | Deployment manifest (definition_version 2, container runtime) |
| `app/orchestrator.py` | Multi-agent orchestrator (S10, unchanged, deployed as artifact) |
| `sql/14_demo_wrappers.sql` | Three demo wrapper procedures + grants |
| `sql/10_sp_discover.sql` | Updated with ID stability fix |

### App URL

```
https://BLSAWML-EX83004.snowflakecomputing.app/ARGUS/GOVERNED/ARGUS_INVESTIGATOR
```

Snowsight path: Projects → Streamlit → ARGUS_INVESTIGATOR (database ARGUS, schema GOVERNED).

## Test results

All tests run as `ARGUS_ANALYST` with `USE SECONDARY ROLES NONE`.

### PII masking

| Column | Value returned |
|---|---|
| full_name | `***MASKED***` |
| national_id | `***MASKED***` |
| phone | `***MASKED***` |
| email | `***MASKED***` |
| dob | `NULL` (date type) |

### Demo path

| Step | Result |
|---|---|
| Baseline snapshot | 5 typologies (TYP-0001..0005), 0 live rows, root task suspended |
| Deliver batches 1-9 | 0 alerts |
| Deliver batch 10 | **1 alert** — CROSS_BANK_HUB on A0000284 (BANK_B), 2 source banks, AED 146,886.68 |
| Rediscover | **6 typologies** — TYP-0001..0005 unchanged, TYP-0006 new (FAN_IN_FAN_OUT_MULE, 12 members, AED 461,679.74) |
| Reset demo | "Demo reset complete \| Discovered 5 typologies \| Root task suspended" |
| Post-reset check | 5 typologies, 0 live rows, root task suspended, all findings intact |

### Typology ID stability

| Typology | Baseline members | After live+rediscover | After reset+rediscover |
|---|---|---|---|
| TYP-0001 | A0000005,A0000400,A0000552 | **identical** | **identical** |
| TYP-0002 | A0000019,A0000263,A0000554 | **identical** | **identical** |
| TYP-0003 | (12 accounts) | **identical** | **identical** |
| TYP-0004 | (12 accounts) | **identical** | **identical** |
| TYP-0005 | A0000343 | **identical** | **identical** |

### FINDING.typology_id references

| Finding | Typology | Status | After demo cycle |
|---|---|---|---|
| FND-0007 | TYP-0004 | VERIFIED | intact |
| FND-0008 | TYP-0001 | VERIFIED | intact |
| FND-0009 | TYP-0002 | VERIFIED | intact |
| FND-0010 | TYP-0003 | VERIFIED | intact |
| FND-0011 | TYP-0005 | VERIFIED | intact |
| FND-0012 | ADHOC | REJECTED | intact |

### Procedure access

All three demo wrappers callable by ARGUS_ANALYST (secondary roles none):
- `CALL ARGUS.GOVERNED.SP_DEMO_NEXT_BATCH()` — delivered batches 1-10
- `CALL ARGUS.GOVERNED.SP_DEMO_REDISCOVER()` — discovered 6 typologies
- `CALL ARGUS.GOVERNED.SP_DEMO_RESET()` — full reset + rediscover in one call

### Constraints honoured

- No warehouse size changes
- No scheduled task changes (root task left suspended throughout)
- Drafts only — nothing sent
- `USE SECONDARY ROLES NONE` for all role checks; `USE SECONDARY ROLES ALL` restored after
