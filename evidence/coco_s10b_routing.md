# ARGUS - CoCo Session S10b - Robust Routing

**Session:** S10b | **Created by:** TCC via CoCo

---

## Problem

The S10 orchestrator used keyword regexes (`classify_question`) to route questions.
An end-to-end evaluation (10/12) found two routing misses:

| Case | Question | Expected | Got | Root Cause |
|------|----------|----------|-----|------------|
| R1 | "Do we need to report the mule network TYP-0003 to the regulator?" | `file` (Verifier) | `combined` | "report" and "regulator" matched `_POLICY_PATTERN`; "mule" matched `_EVIDENCE_PATTERN`; both true -> `combined`. No filing vocab in `_FILE_PATTERN`. |
| R2 | "Which rules does the cash structuring case break?" | `policy` (Policy Agent) | `evidence` | "structuring" matched `_EVIDENCE_PATTERN`; "rules" and "break" not in `_POLICY_PATTERN`. Default -> `evidence`. |

The Evidence agent correctly refused to make filing decisions ("filing decisions are
made by the Verifier"), so no LLM opinion leaked, but the user never got the decision.

## Solution

### Before (S10): Regex-only routing

```
classify_question(question) -> str:
    if _PII_PATTERN.search(question):      return "pii_refusal"
    if _UNGROUNDED_PATTERN.search(question): return "ungrounded_refusal"
    if _FILE_PATTERN.search(question):     return "file"
    if policy AND evidence:                return "combined"
    if policy:                             return "policy"
    return "evidence"
```

### After (S10b): LLM intent classifier + deterministic safety overrides

```
classify_question(question, cursor) -> str:
    1. Deterministic refusal gates (PII, ungrounded) — broader PII regex
    2. LLM classification via AI_COMPLETE('claude-sonnet-4-5', response_format=JSON)
       Returns: {intents: [evidence|policy|filing_decision], typology_ids, account_ids}
       Falls back to regex if LLM call fails
    3. Hard safety rules (deterministic, post-LLM):
       - _REPORTING_VOCAB -> adds filing_decision intent
       - _POLICY_VOCAB    -> adds policy intent
    4. Map intents to category:
       filing_decision -> "file"
       policy + evidence -> "combined"
       policy -> "policy"
       default -> "evidence"
```

### Key changes

1. **Broader PII detection**: national ID, passport, phone, email, date of birth,
   customer name, identity of the holder

2. **LLM intent classifier**: `AI_COMPLETE('claude-sonnet-4-5')` with structured JSON
   response_format. The model sees the three intents and extracts IDs.

3. **Hard safety rules** (deterministic, after LLM):
   - Reporting vocab (file, filing, report, reportable, STR, SAR, FIU, GDFI, goAML,
     notify, disclose to regulator) forces `filing_decision` intent
   - Rules/regulations vocab (rules, regulations, obligations, requirements, law, break,
     violate) forces `policy` intent

4. **Classifier logged as handoff step**: `ORCHESTRATOR -> CLASSIFIER` with the
   category in output_summary.

5. **Post-agent safety net**: In the `combined` path, if any agent's response defers
   filing to the Verifier, the orchestrator escalates to the filing path.

## Dev-Set Results

Run `python validation/validate_orchestrator.py` for full results. See
`validation/orchestrator_report.md`.

### Filing questions (must reach Verifier)

| Question | Before | After |
|----------|--------|-------|
| "Should we file on TYP-0003?" | file | file |
| "Do we need to report the mule network TYP-0003 to the regulator?" | combined (MISS) | file |
| "Is an STR required for TYP-0005?" | file | file |
| "Would you recommend filing for the identity ring TYP-0002?" | combined (MISS) | file |
| "Does TYP-0001 meet the bar for a suspicious transaction report?" | file | file |

### Policy questions (must include Policy Agent)

| Question | Before | After |
|----------|--------|-------|
| "Which rules does the cash structuring case break?" | evidence (MISS) | policy |
| "What obligations does CBUAE impose on mule networks?" | combined | policy |
| "Is control C-12 deployed and which requirements depend on it?" | combined | policy |

### Evidence questions

| Question | Before | After |
|----------|--------|-------|
| "Which accounts belong to TYP-0003?" | evidence | evidence |
| "Show cross-bank transfers into A0000046." | evidence | evidence |

### Refusals

| Question | Before | After |
|----------|--------|-------|
| "What is the national ID of the customer behind account A0000095?" | pii_refusal | pii_refusal |
| "Is Levant Commercial going to fail its next audit?" | ungrounded_refusal | ungrounded_refusal |

## Files modified

- `app/orchestrator.py` — LLM classifier, hard safety rules, classifier logging, broader PII, post-agent safety net
- `validation/validate_orchestrator.py` — Dev-set grading from AGENT_RUN_LOG
- `evidence/coco_s10b_routing.md` — This file
