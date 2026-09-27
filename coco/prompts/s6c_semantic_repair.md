# CoCo session S6c — SEMANTIC LAYER REPAIR (source of truth + two regressions)

Project: **ARGUS** (team TCC). Sessions S6/S6b extended the semantic views and improved
Cortex Analyst accuracy (custom instructions, synonyms, the named metric
`consortium_inbound_amount`, verified queries) — keep ALL of those improvements.
A review found three problems:

1. **Multi-path error in `ARGUS.GOVERNED.ARGUS_FRAUD_SV`.** This Week 2 query now fails:
   `SELECT * FROM SEMANTIC_VIEW(ARGUS.GOVERNED.ARGUS_FRAUD_SV DIMENSIONS banks.bank_name METRICS transactions.cross_bank_amount)`
   → "Multi-path relationship between BANKS and TRANSACTIONS is not supported".
   Cause: redundant relationships `TXN_TO_BANKS`, `HUB_TO_BANKS`, `STRUCTURING_TO_BANKS`,
   `ALERTS_TO_BANKS` — those tables already reach BANKS through ACCOUNTS. Remove the
   redundant ones so every table has exactly one path to BANKS.
2. **`ARGUS.GOVERNED.ARGUS_REGTWIN_SV` lost its facts and metrics** (e.g. the open-gap
   count) and its logical table names changed. Restore: a `gap_flag` fact
   (`IFF(is_gap,1,0)`), metrics `open_gap_count` (SUM of gap_flag) and `obligation_count`
   (COUNT DISTINCT obligation_id), and dimensions for regulator, title, article_ref,
   clause text, obligation_text, required_scope, severity, rationale. Keep the current
   logical table names unless a rename is needed; if you rename, update everything that
   references them (verified queries, custom instructions, `README_WEEK2.md` examples).
3. **The repo does not describe what is deployed.** `semantic/*.yaml` has no
   dimensions/metrics while the live views were redeployed from DDL that is not saved.

## Do
- Read the LIVE definitions: `SELECT GET_DDL('SEMANTIC_VIEW','ARGUS.GOVERNED.ARGUS_FRAUD_SV')`
  and the same for `ARGUS_REGTWIN_SV`.
- Write the corrected, complete DDL for both views to **`sql/11_semantic_views.sql`** —
  this file becomes the single source of truth. Deploy it.
- Re-export the deployed views to `semantic/argus_fraud_sv.yaml` and
  `semantic/argus_regtwin_sv.yaml` with `cortex agent-studio sv-read --fqn ...` (or
  `SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW`) so the YAML matches what is deployed exactly.
- Add a header comment to both YAML files: "Generated from the deployed view; edit
  sql/11_semantic_views.sql and redeploy, then re-export."

## Verify
- The failing query above now returns 3 banks with values.
- `SELECT * FROM SEMANTIC_VIEW(ARGUS.GOVERNED.ARGUS_REGTWIN_SV DIMENSIONS <regulations>.regulator METRICS <gaps>.open_gap_count)` returns CBUAE/CBB/SAMA/FATF rows.
- As role ARGUS_ANALYST (`USE SECONDARY ROLES NONE; USE ROLE ARGUS_ANALYST;`) both queries
  work; switch back to ACCOUNTADMIN with secondary roles ALL afterwards.
- `.venv/Scripts/python validation/validate_week2.py --backend snowflake` → must be 6/6.
- `.venv/Scripts/python validation/validate_analyst.py` → report Set A / Set B honestly
  (previous independent run: A 5/6, B 11/12). No grader or question changes allowed.

Write `evidence/coco_s6c_semantic_repair.md` (what was wrong, what changed, results).
Rules: change only the two semantic views and the files named above.
