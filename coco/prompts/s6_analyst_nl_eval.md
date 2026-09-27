# CoCo session S6 — SEMANTIC LAYER + CORTEX ANALYST: answer the ontology questions in plain English

Project: **ARGUS** (team TCC). Semantic views `ARGUS.GOVERNED.ARGUS_FRAUD_SV` and
`ARGUS.GOVERNED.ARGUS_REGTWIN_SV` exist (DDL in `sql/03_semantic_views.sql`). Verified
SQL for six ontology questions is in `semantic/verified_queries.yaml`, and
`validation/validate_week2.py` checks that SQL against `data/ground_truth/planted_rings.json`.
What has NOT been tested: whether **Cortex Analyst** turns the plain-English questions
into correct answers. That is this session's job.

Curated signal objects now exist: `ARGUS.CURATED.DT_HUB_ACCOUNTS`,
`ARGUS.CURATED.DT_STRUCTURING`, `ARGUS.CURATED.DT_CROSS_BANK_EDGES`,
`ARGUS.GOVERNED.LIVE_ALERTS`, `ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL`,
`ARGUS.GOVERNED.TYPOLOGY_EXPOSURE`, `ARGUS.GOVERNED.TYPOLOGY_EVIDENCE`.

## 1. Extend the semantic views (use CoCo's semantic-view tooling)
Read the current definitions (`cortex agent-studio sv-read --fqn ...`), save them as
YAML in `semantic/argus_fraud_sv.yaml` and `semantic/argus_regtwin_sv.yaml`, and extend:
- **Fraud SV**: add logical tables for DT_HUB_ACCOUNTS (hub accounts: source bank count,
  inbound amount, burst window), DT_STRUCTURING, SHARED_BAD_ACTOR_SIGNAL (identifier
  type, bank count, risk weight — hashes only), LIVE_ALERTS and TYPOLOGY_EVIDENCE, with
  relationships to accounts where a key exists. Good descriptions + synonyms
  ("mule hub", "consolidation account", "smurfing", "shared identity", "alert").
- **Reg-twin SV**: add TYPOLOGY_EXPOSURE (typology → obligation → gap, severity, rationale).
- Keep PII out: never add full_name, national_id, phone, email or dob.
- Add the six **verified queries** from `semantic/verified_queries.yaml`, rewritten to
  the semantic model's logical tables, to the right view's YAML.
Deploy with `cortex agent-studio sv-deploy` (or SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML).
Confirm both views still answer a `SEMANTIC_VIEW(...)` query.

## 2. Build an automated plain-English evaluation — `validation/validate_analyst.py`
For each question, call Cortex Analyst via CoCo:
`cortex analyst query "<question>" --view <FQN> -c argus` (returns JSON whose `result`
contains the generated SQL in a ```sql block). Extract the SQL, execute it with the
Snowflake Python connector (`.venv`, `connection_name="argus"`), and grade the result
against the ground truth with the SAME pass criteria as `validate_week2.py`.
- Questions: the six ontology questions (bind concrete IDs from the ground truth,
  e.g. RING-001's consolidation account for Q2, `RING-001` for Q5/Q6) PLUS two
  **paraphrases** per question that don't copy the verified wording
  (e.g. "Which accounts are collecting money from several other banks in a short burst?").
- Q6 needs ring membership, which the Typology agent writes in Week 3. Until then,
  create a session **TEMPORARY** table `ARGUS.GOVERNED.TYPOLOGY_EVIDENCE` from the
  ground truth in the evaluation's own connection before running the generated SQL
  (nothing persists).
- Record per question: phrasing, generated SQL, pass/fail, reason. Write
  `validation/analyst_eval_results.json` and `validation/analyst_eval_report.md`
  (overall accuracy, verified vs paraphrased accuracy, failures with reasons).
- If a question fails, improve the semantic model (descriptions, synonyms, verified
  query), redeploy, and re-run. Record before/after accuracy.

Run the evaluation and report the final numbers. Target: all six verified questions
pass; paraphrases ≥ 80%.

Rules: do not create or change any objects other than the two semantic views; do not
put PII into the semantic model. Create only files under `semantic/` and `validation/`
named above, plus `evidence/coco_s6_analyst.md` (summary + final accuracy table).
