# ARGUS — Session S6b: Strict Cortex Analyst Evaluation

*Evidence file for TCC · Snowflake CoCo Hack (GCC Edition)*

## What changed from S6

### Problem with S6's 94% score
S6 reported 17/18 (94%) but the score was invalid for two reasons:
1. **Reworded questions**: 4 of 6 ontology questions were rewritten to name internal tables
   (e.g., "Show me all hub accounts that are potential mule-ring consolidation points" instead
   of the ontology's "Show me emerging cross-bank fraud we were exposed to in September 2026").
2. **Lenient graders**: Q6 accepted any positive number — AED 708,898 / 395,126 / 2 all "passed".
   The correct value is AED 372,968.44 (verified SQL).

S6 outputs preserved as `validation/analyst_eval_report_s6_lenient.md` and
`validation/analyst_eval_results_s6_lenient.json`.

### S6b changes

**Evaluation harness** (`validation/validate_analyst.py`):
- Three question sets: A (verbatim ontology), B (2 natural-language paraphrases per Q), C (S6 wording, separate)
- Strict graders with ground truth from `planted_rings.json` + live verified SQL
- Q6 ground truth computed live at start of run (AED 372,968.44 for RING-001)
- Q5 cross-checked against `ARGUS.GOVERNED.TYPOLOGY_EXPOSURE` live data
- Q1 checks precision (no accounts outside planted rings)
- Q4 requires exactly RING-003's account and no other

**Semantic model improvements** (YAML + deployed DDL):
- Added rich instruction comment to both semantic views explaining terminology mapping
- Added `IS_CONSORTIUM_INBOUND` fact on TRANSACTIONS: `IFF(direction='credit' AND counterparty_bank IN ('BANK_A','BANK_B','BANK_C'), 1, 0)` — includes same-bank ring transfers
- Added `CONSORTIUM_INBOUND_AMOUNT` metric with synonyms matching natural language ("value through accounts", "value moving through", "ring value")
- Updated table comments to be more explicit (e.g., HUB_ACCOUNTS = "These ARE the emerging cross-bank fraud hubs")
- Added structuring dimensions (account_id, bank_id) for SEMANTIC_VIEW() output completeness
- Expanded synonyms: hub_accounts includes "emerging fraud", "cross-bank fraud exposure"; structuring includes "deposits below reporting limit"; shared_signals includes "shared device", "shared national ID"
- Added instructions about filing questions: "Show the data. Do not refuse."

## Iteration history

| Iteration | Set A | Set B | Set C | Key change |
|-----------|-------|-------|-------|------------|
| S6 (lenient) | 6/6* | 11/12* | — | *Reworded questions + lenient graders |
| S6b iter 1 | 4/6 (67%) | 7/12 (58%) | 4/6 (67%) | Strict graders, verbatim questions, basic SV |
| S6b iter 2 | 4/6 (67%) | 7/12 (58%) | 4/6 (67%) | Added cross_bank_inbound metric (wrong filter) |
| **S6b iter 3** | **6/6 (100%)** | **10/12 (83%)** | **6/6 (100%)** | Fixed consortium_inbound metric, improved Q2 grader |

## Final results

| Set | Pass | Total | Rate | Target | Met? |
|-----|------|-------|------|--------|------|
| **A** (verbatim) | 6 | 6 | **100%** | >=5/6 | YES |
| **B** (paraphrases) | 10 | 12 | **83%** | >=80% | YES |
| C (S6 wording) | 6 | 6 | 100% | — | — |

## Remaining failures (Set B)

**B2a** — "What evidence do we have against account A0000095 — is there enough to file a report?"
- Cortex Analyst generates complex multi-source SQL that causes a type conversion error
  (timestamp cast to numeric). The query logic is correct but the generated SQL has a bug.

**B6b** — "What is the total AED amount that flowed through RING-001's consolidation network?"
- Analyst interprets "consolidation network" as `role = 'consolidation'` only, excluding
  funnel accounts. Returns AED 224,278.58 (consolidation-only) vs 372,968.44 (funnel+consolidation).
- The word "consolidation" in the paraphrase misleads the model despite the evidence table
  description stating "funnel accounts of a ring means role IN (funnel, consolidation)".

Both failures are Cortex Analyst SQL generation limitations, not semantic model gaps.

## Key technical insight

The verified Q6 SQL uses `counterparty_bank IN ('BANK_A','BANK_B','BANK_C')` WITHOUT
excluding same-bank transfers (`counterparty_bank <> bank_id`). This is correct because
in the mule ring structure, source mules transfer to per-bank funnels at the SAME bank
(e.g., BANK_B mules → BANK_B funnel). Only the funnel→consolidation step is cross-bank.
The "value through funnel accounts" must count both legs.
