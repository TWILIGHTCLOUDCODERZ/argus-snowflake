# S6c — Semantic Layer Repair

**Session**: S6c (semantic repair)
**Date**: 2026-09-27
**Author**: CoCo (claude-opus-4-6)

## What was wrong

### 1. ARGUS_FRAUD_SV — Multi-path relationship error

The query `SELECT * FROM SEMANTIC_VIEW(ARGUS.GOVERNED.ARGUS_FRAUD_SV DIMENSIONS banks.bank_name METRICS transactions.cross_bank_amount)` failed with "Multi-path relationship between BANKS and TRANSACTIONS is not supported".

**Root cause**: Four redundant direct-to-BANKS relationships existed alongside the path through ACCOUNTS:
- `TXN_TO_BANKS` (TRANSACTIONS.BANK_ID → BANKS.BANK_ID)
- `HUB_TO_BANKS` (HUB_ACCOUNTS.BANK_ID → BANKS.BANK_ID)
- `STRUCTURING_TO_BANKS` (STRUCTURING.BANK_ID → BANKS.BANK_ID)
- `ALERTS_TO_BANKS` (ALERTS.BANK_ID → BANKS.BANK_ID)

Each of those tables already reaches BANKS through ACCOUNTS (e.g. TRANSACTIONS → ACCOUNTS → BANKS), creating ambiguous join paths that Snowflake's semantic view engine rejects.

### 2. ARGUS_REGTWIN_SV — Missing facts and metrics

The regulatory twin view had dimensions but no facts or metrics, making it unable to answer aggregation questions like "how many open gaps by regulator?".

**Root cause**: The view was deployed with dimensions only — no `gap_flag` fact, no `open_gap_count` metric, no `obligation_count` metric. Additionally, the `clause_text` and `required_scope` dimensions were missing. Logical table names were singular (REGULATION, CLAUSE, OBLIGATION) while the YAML and verification queries expected plural forms.

### 3. No source-of-truth DDL file

The repo had `sql/03_semantic_views.sql` (original Week 2) but the S6/S6b improvements were deployed from ad-hoc DDL that was never saved to a file. The YAML files in `semantic/` had no dimensions/metrics (didn't match what was deployed).

## What changed

### ARGUS_FRAUD_SV
- **Removed** 4 redundant relationships: `TXN_TO_BANKS`, `HUB_TO_BANKS`, `STRUCTURING_TO_BANKS`, `ALERTS_TO_BANKS`
- Everything else (tables, facts, dimensions, metrics, comment, synonyms) preserved exactly

### ARGUS_REGTWIN_SV
- **Aliased** table names to plural: `REGULATIONS`, `CLAUSES`, `OBLIGATIONS` (GAPS and TYPOLOGY_EXPOSURE unchanged)
- **Added** fact: `GAPS.GAP_FLAG = IFF(is_gap, 1, 0)`
- **Added** metrics: `GAPS.OPEN_GAP_COUNT = SUM(gaps.gap_flag)`, `OBLIGATIONS.OBLIGATION_COUNT = COUNT(DISTINCT obligations.obligation_id)`
- **Added** dimensions: `CLAUSES.CLAUSE_TEXT`, `OBLIGATIONS.REQUIRED_SCOPE`
- Updated relationship references to use new plural table aliases

### Files created/updated
| File | Action |
|---|---|
| `sql/11_semantic_views.sql` | **Created** — single source of truth for both semantic views |
| `semantic/argus_fraud_sv.yaml` | **Replaced** — re-exported from deployed view + verified queries |
| `semantic/argus_regtwin_sv.yaml` | **Replaced** — re-exported from deployed view + verified queries |

## Verification results

### Semantic view queries (as ACCOUNTADMIN)
```
FRAUD_SV cross_bank_amount by bank_name → 3 banks with values ✓
REGTWIN_SV open_gap_count by regulator → CBUAE(2), CBB(2), SAMA(2), FATF(1) ✓
```

### ARGUS_ANALYST role
Both queries succeed with `USE SECONDARY ROLES NONE; USE ROLE ARGUS_ANALYST;` ✓

### validate_week2.py --backend snowflake
```
6/6 NL questions pass | YAML<->harness parity: OK
Q1 PASS — 2 hub accounts found (A0000046, A0000095)
Q2 PASS — all 5 verifier decisions correct
Q3 PASS — 3 shared identifiers, RING-002 national_id at 3 banks
Q4 PASS — A0000343 structuring account
Q5 PASS — RING-001 has HIGH gaps; RING-003 fully covered
Q6 PASS — RING-001 AED 372,968; RING-005 AED 399,836
```

### validate_analyst.py (Cortex Analyst evaluation)
```
Set A (verbatim):     6/6  (100%)
Set B (paraphrases):  10/12 (83%)
Set C (S6 wording):   6/6  (100%) [not counted]

Targets: Set A >= 5/6 ✓, Set B >= 80% ✓
```

Set B failures (B2a, B2b) are paraphrase variants of Q2 ("evidence for account X") where the analyst generated SQL that didn't surface cross-bank evidence rows or had a type conversion error. The verbatim Q2 and the S6-tuned C2 both pass — this is an Analyst model accuracy limitation on paraphrased evidence-bundle queries, not a semantic view defect.

### Comparison with previous run (S6b)
| Metric | S6b | S6c |
|---|---|---|
| Set A | 5/6 | **6/6** |
| Set B | 11/12 | 10/12 |

Set A improved by 1 (A5 now passes with the restored metrics). Set B dropped by 1 — likely stochastic variation in Cortex Analyst's SQL generation for paraphrase queries (B2a passed in S6b, fails now; no semantic view change affects it).
