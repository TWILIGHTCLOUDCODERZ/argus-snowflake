# ARGUS S10c — Idempotent Filing Path & Precise Routing Gates

## Problem Statement

Session S10b introduced an LLM intent classifier and reporting-vocabulary safety net.
An independent evaluation found four problems:

1. **Duplicates on every filing question** — each call created new findings + filings
2. **Over-broad PII gate** — ontology questions about hashed identifiers were refused
3. **Safety net over-triggers** — general policy questions containing "filing" ran the Verifier
4. **Speculation not refused** — future regulator actions were not caught

## Before / After Counts

| Table | Before | After | Change |
|-------|--------|-------|--------|
| FINDING | 24 (12 for TYP-0003 alone, 3 ADHOC) | 5 (1 per typology, all VERIFIED) | -19 |
| FINDING_CLAIM | 381 | 68 | -313 |
| FILING | 68 (63 DRAFT + 5 REJECTED_GROUNDING) | 6 (all DRAFT_PENDING_HUMAN) | -62 |

### Surviving Findings

| Finding | Typology | Status |
|---------|----------|--------|
| FND-0007 | TYP-0004 | VERIFIED |
| FND-0008 | TYP-0001 | VERIFIED |
| FND-0009 | TYP-0002 | VERIFIED |
| FND-0010 | TYP-0003 | VERIFIED |
| FND-0011 | TYP-0005 | VERIFIED |

### Surviving Filings

| Filing | Finding | Type | Bank | Status |
|--------|---------|------|------|--------|
| FND-0010-STR-BANK_A | FND-0010 | STR | BANK_A | DRAFT_PENDING_HUMAN |
| FND-0010-STR-BANK_B | FND-0010 | STR | BANK_B | DRAFT_PENDING_HUMAN |
| FND-0010-STR-BANK_C | FND-0010 | STR | BANK_C | DRAFT_PENDING_HUMAN |
| FND-0010-MEMO | FND-0010 | CONTROL_GAP_MEMO | — | DRAFT_PENDING_HUMAN |
| FND-0011-STR-BANK_B | FND-0011 | STR | BANK_B | DRAFT_PENDING_HUMAN |
| FND-0011-MEMO | FND-0011 | CONTROL_GAP_MEMO | — | DRAFT_PENDING_HUMAN |

## Changes Made

### 1. Idempotent Verifier Path (`app/orchestrator.py`)

- Added `find_existing_finding(cursor, typology_id)` — returns the best existing
  VERIFIED/REJECTED finding (prefers findings with existing filings, then newest).
- Filing path checks for existing findings before calling SP_BUILD_FINDING.
- When an existing finding is found, logs `VERIFIER:REUSE_FINDING` handoff step.
- Account-based queries resolve the account's typology before the idempotency check.

### 2. Drafting Only on Request (`app/orchestrator.py`)

- Filing path only calls SP_DRAFT_FILING when user explicitly asks to draft/prepare
  (detected via `_DRAFT_REQUEST` regex) AND no filings exist for the finding.
- Existing filings are always reported in the answer.
- Combined path escalation never auto-drafts.

### 3. Narrower PII Gate (`app/orchestrator.py`)

- Replaced broad `_PII_PATTERN` with two precise patterns:
  - `_PII_LOOKUP_PATTERN`: "what is the national ID of...", "show me the name of..."
  - `_PII_OF_PATTERN`: "national ID of the customer...", "name behind account..."
- Ontology questions like "which accounts share a national ID" are no longer refused.

### 4. Narrow Safety Net (`app/orchestrator.py`)

- `_REPORTING_VOCAB` now only forces `filing_decision` intent when the question also
  contains a `_CASE_REFERENCE` (TYP-NNNN, FND-NNNN, ANNNNNNN, or "this case/ring/network").
- General policy questions with "filing" (e.g., filing deadlines) route to Policy.

### 5. Speculative Intent (`app/orchestrator.py`)

- Added `speculative` intent to the LLM classifier prompt and schema.
- Strengthened `_UNGROUNDED_PATTERN` to catch: "will the regulator", "next year",
  "what fine", "going to be penalized", "future audit/fine/sanction".
- If the LLM returns `speculative` intent, routes to `ungrounded_refusal`.

### 6. Retry on Grounding Rejection (`sql/12_findings.sql`)

- SP_DRAFT_FILING now retries up to 3 times when narrative fails the grounding check.
- On retry, appends violation details to the prompt asking the LLM to fix them.
- Applies to both STR drafts and CONTROL_GAP_MEMO.
- Grounding details now include `attempts` count.

## Validation Results

### validate_orchestrator.py — 17/17 pass

New S10c cases:
- **I1** (idempotency): Same filing question twice — PASS (0 new findings, 0 new filings)
- **PII2** (PII false positive): Ontology question about shared national IDs — PASS (routed to EVIDENCE_AGENT)
- **SN1** (safety net): Filing deadlines in CBUAE rulebook — PASS (routed to POLICY_AGENT, no findings)
- **SP1** (speculation): "Will the regulator fine us next year?" — PASS (refused as ungrounded)

All existing S10b cases continue to pass.

### validate_orchestrator_e2e.py — 12/12 pass

All 12 cases pass including F1 (VERIFIED + filing drafts listed) which now reuses
the existing FND-0010 finding with its existing filings.

### validate_findings.py — 46/46 pass

All findings, grounding, and data minimisation tests pass.
