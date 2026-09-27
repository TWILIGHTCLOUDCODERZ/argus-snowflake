# ARGUS · S9b — Grounding Fix Evidence

**Session:** S9b · **Date:** 2026-09-27 · **Team:** TCC

## Problems Found (from independent review)

| # | Issue | Impact |
|---|-------|--------|
| 1 | `SP_DRAFT_FILING` grounding check only counted cited-claim markers and other-bank leaks; no number verification | Ring total "AED 372,968.44" appeared in all 3 STRs but in no cited claim |
| 2 | CONTROL_GAP_MEMO grounding was hard-coded `TRUE`; memos cited no claims (`[Cnn]` markers missing) | `cited_claims: []` yet `grounding_passed: true` |
| 3 | `SP_VERIFY_FINDING` confidence check fired before weak-signal check | A0000004 adhoc got "Confidence 0.5 below 0.70 threshold" instead of the explicit weak-signal reason |

## Changes Made

### 1. SUMMARY claim in `SP_BUILD_FINDING`

Every finding now gets a final SUMMARY claim containing the total value, bank list, member count, and time window. This makes aggregate figures citable.

**Example (FND-0010):**
```
SUMMARY: Finding FND-0010 involves 3 banks (BANK_B, BANK_C, BANK_A) with
12 member accounts. Total network value: AED 372,968.44 across 11 flows
between 2026-09-15 10:04 and 2026-09-20 17:05.
```

### 2. `FN_GROUNDING_CHECK` (new JavaScript UDF)

Reusable function: `ARGUS.GOVERNED.FN_GROUNDING_CHECK(narrative, cited_claim_texts) → VARIANT`

Logic:
1. Strip ignorable patterns: account IDs (`A0000xxx`), txn IDs (`TXxxxxxxxx`), finding/typology/obligation/clause IDs, `[Cnn]` markers, `STR-yyyy-nnnn`, article references (`Art. 16.4`, `FC-6.1`), dates, standalone years
2. Extract remaining numbers; ignore values < 1000 (regulatory boilerplate: days, counts)
3. Normalise (strip thousands separators, compare numerically so `27139.8 == 27139.80`)
4. Check each number against normalised cited claim texts
5. Return `{numbers_checked, violations[], passed}`

### 3. `SP_DRAFT_FILING` — real grounding on every filing

- **STR prompt** now instructs: "The SUMMARY claim contains the finding totals. You MUST cite it. Every monetary amount must appear verbatim in a cited claim. Do NOT compute subtotals."
- After generating each STR: maps local `Cnn` → `<finding_id>-Cnn`, gathers cited claim texts, calls `FN_GROUNDING_CHECK`
- Merges number grounding with existing data-minimisation leak check
- On violations: `status = REJECTED_GROUNDING`, violations stored in `grounding_check`
- **MEMO** gets the same treatment (no more hard-coded `TRUE`)
- Memo prompt now includes SUMMARY claim and [Cnn] citation instructions

### 4. `SP_VERIFY_FINDING` — weak-signal rule first

Moved the weak-signal check **before** the confidence check. When the only evidence is a shared device (no flows, no national-ID link, no structuring), the finding is rejected with:

> "Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring)"

The confidence threshold check is preserved for findings with real evidence but low confidence.

## Before / After

### Grounding Check (STR-BANK_A)

| Field | Before (S9) | After (S9b) |
|-------|-------------|-------------|
| `numbers_checked` | _(not tracked)_ | 4 |
| `number_violations` | _(not tracked)_ | `[]` |
| `grounding_passed` | `true` (leak-only) | `true` (leak + numbers) |

### Grounding Check (MEMO)

| Field | Before (S9) | After (S9b) |
|-------|-------------|-------------|
| `cited_claims` | `[]` | `['C20','C17','C21','C22','C15','C16','C19','C18']` |
| `numbers_checked` | _(not tracked)_ | 1 |
| `number_violations` | _(not tracked)_ | `[]` |
| `grounding_passed` | `true` (hard-coded) | `true` (real check) |

### Weak-Signal (A0000004 adhoc)

| Field | Before (S9) | After (S9b) |
|-------|-------------|-------------|
| `verifier_reason` | "Confidence 0.5 below 0.70 threshold" | "Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring)" |

## Negative Test Results

| Test | Input | Expected | Actual | Pass |
|------|-------|----------|--------|------|
| Fabricated amount | `AED 999,999.99` + `AED 22,382.44` in claims | `999999.99` violation | `violations=['999999.99']` | PASS |
| Correct amounts | `AED 372,968.44` in both | 0 violations | `violations=[]` | PASS |
| Article ref ignored | `Art. 16.4`, `FC-6.1` in narrative | Not counted | `numbers_checked=1` (only AED amount) | PASS |

## Re-drafted Filing Results

| Filing | numbers_checked | violations | status | cited_claims |
|--------|-----------------|------------|--------|-------------|
| FND-0010-STR-BANK_A | 4 | 0 | DRAFT_PENDING_HUMAN | 7 |
| FND-0010-STR-BANK_B | 5 | 0 | DRAFT_PENDING_HUMAN | 9 |
| FND-0010-STR-BANK_C | 5 | 0 | DRAFT_PENDING_HUMAN | 9 |
| FND-0010-MEMO | 1 | 0 | DRAFT_PENDING_HUMAN | 8 |
| FND-0011-STR-BANK_B | 2 | 0 | DRAFT_PENDING_HUMAN | 3 |
| FND-0011-MEMO | 1 | 0 | DRAFT_PENDING_HUMAN | 4 |

## Full Validation Suite

**Result: 42 passed, 0 failed**

Suite covers: UDF unit tests, SUMMARY claim creation, finding rebuild + re-verify, filing re-draft with grounding, weak-signal rejection, RING-001/RING-003 filing structure, FIU mapping, all-typology verification, cleanup.

## Objects Modified

| Object | Type | Action |
|--------|------|--------|
| `ARGUS.GOVERNED.FN_GROUNDING_CHECK` | JavaScript UDF | Created |
| `ARGUS.GOVERNED.SP_BUILD_FINDING` | Procedure | Updated (SUMMARY claim) |
| `ARGUS.GOVERNED.SP_VERIFY_FINDING` | Procedure | Updated (weak-signal first) |
| `ARGUS.GOVERNED.SP_DRAFT_FILING` | Procedure | Updated (real grounding) |
| `ARGUS_ANALYST` grants | Role | Re-granted on UDF |
