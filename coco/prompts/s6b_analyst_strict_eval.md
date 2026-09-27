# CoCo session S6b — STRICT Cortex Analyst evaluation (fixing S6's scoring)

Project: **ARGUS** (team TCC). Session S6 extended the semantic views
(`semantic/argus_fraud_sv.yaml`, `semantic/argus_regtwin_sv.yaml`, deployed as
`ARGUS.GOVERNED.ARGUS_FRAUD_SV` / `ARGUS_REGTWIN_SV`) and wrote
`validation/validate_analyst.py`, reporting 94%. A review found that score is **not
valid**, for two reasons you must fix:

1. **The test questions were reworded until they passed.** E.g. the ontology question
   "Show me emerging cross-bank fraud..." was replaced by "Show me all hub accounts that
   are potential mule-ring consolidation points", which names the answer's table. A test
   of plain-English understanding must use the business user's wording.
2. **Grading is too lenient.** `grade_q6` passes any number > 0 — three different answers
   (AED 708,898 / 395,126 / 2) all "passed". The correct value is what the verified SQL
   returns (≈ AED 372,968 for RING-001).

First preserve S6's outputs for the record: copy `validation/analyst_eval_report.md` →
`validation/analyst_eval_report_s6_lenient.md` and `validation/analyst_eval_results.json`
→ `validation/analyst_eval_results_s6_lenient.json`.

## Test set (edit `validation/validate_analyst.py`)
A. **Ontology questions, verbatim** — the six `validation_questions` in
   `ontology/argus_ontology.yaml`. The ONLY allowed change is binding a placeholder or
   pointer to a concrete ID: `{account_id}` → RING-001's consolidation account;
   "this typology" / "this ring" → "typology RING-001" / "ring RING-001".
B. **Paraphrases** — two per question, in natural business language. They must NOT
   contain table/column names or internal role words that give away the answer
   (no "hub accounts table", "consolidation role", "DT_", "is_gap").
Keep S6's reworded questions only as a separate, clearly labelled set C
("analyst-friendly wording") — they do not count toward the headline score.

## Strict graders (ground truth: `data/ground_truth/planted_rings.json` + verified SQL)
- **Q1**: result must include BOTH historical hub accounts (RING-001 and RING-005
  consolidation) AND no account outside the planted rings (precision matters).
- **Q2**: must return ≥1 row that is a cross-bank transaction for the account
  (counterparty_bank is another consortium bank). Analyst retrieves evidence; the
  "should we file?" judgement belongs to the Verifier agent (Week 3) — note this in
  the report, don't fake it.
- **Q3**: must include RING-002's national_id hash seen at 3 banks.
- **Q4**: must return the RING-003 account and NO other account.
- **Q5**: must list RING-001's obligations with at least one HIGH gap, and every
  returned gap flag must match `ARGUS.GOVERNED.TYPOLOGY_EXPOSURE`.
- **Q6**: numeric answer within **±1%** of the value produced by running the verified
  Q6 SQL from `semantic/verified_queries.yaml` for RING-001 (compute it live at the
  start of the run; use a session TEMPORARY `TYPOLOGY_EVIDENCE` from ground truth).
  A count or unrelated sum fails.
- Anything returning 0 rows fails unless the correct answer is genuinely empty.

## Improving the score — allowed ONLY through the semantic model
You may improve descriptions, synonyms, verified queries, and add **named metrics**
(e.g. a `value_through_ring_hubs` metric whose description defines "value moving
through a ring's funnel accounts" exactly as the verified Q6 SQL does) and **custom
instructions** for SQL generation (e.g. relative dates refer to the data's latest
transaction date; "flagged" means appears in hub/structuring/shared-signal/alert
objects). Redeploy with `cortex agent-studio sv-deploy` and re-run.
You may NOT edit question wording (beyond ID binding) or loosen any grader.

## Report
Write `validation/analyst_eval_report.md` and `validation/analyst_eval_results.json`:
headline accuracy for Set A (verbatim) and Set B (paraphrases) separately, Set C
listed separately, before/after table for each semantic-model iteration, and every
failure with its generated SQL and reason. State plainly if targets are not met.
Target: Set A ≥ 5/6, Set B ≥ 80%. Honest numbers matter more than hitting the target.
Also write `evidence/coco_s6b_strict_eval.md` summarising what changed and the final
numbers.

Rules: only modify the two semantic views (via YAML + deploy), the files named above,
and `validation/validate_analyst.py`. No other Snowflake objects.
