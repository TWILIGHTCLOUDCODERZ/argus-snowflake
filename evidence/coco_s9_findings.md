# ARGUS · CoCo Session S9 — Findings, Evidence Ledger, Verifier & Filing Drafts

**Session:** S9 | **Date:** 2026-09-27 | **Created by:** TCC via CoCo

---

## Objects Created

### Tables (ARGUS.GOVERNED)

| Table | Purpose |
|-------|---------|
| `FINDING` | Findings derived from discovered typologies. Status: DRAFT → VERIFIED/REJECTED |
| `FINDING_CLAIM` | Evidence claims per finding: FLOW, ROLE, IDENTITY, STRUCTURING, REGULATORY, CONTROL_GAP |
| `FILING` | STR drafts and control-gap memos. Status: DRAFT_PENDING_HUMAN (never auto-filed) |

### Stored Procedures (ARGUS.GOVERNED)

| Procedure | Purpose |
|-----------|---------|
| `SP_BUILD_FINDING(typology_id)` | Deterministic claim builder from typology data — no LLM |
| `SP_BUILD_FINDING_ADHOC(account_ids ARRAY)` | Ad-hoc finding builder for arbitrary accounts; delegates to SP_BUILD_FINDING if accounts match a known typology |
| `SP_VERIFY_FINDING(finding_id)` | Verification guardrail: re-checks all refs against live data |
| `SP_DRAFT_FILING(finding_id)` | Produces per-bank STRs + control-gap memo via AI_COMPLETE; grounding check |

### SQL File

`sql/12_findings.sql` — complete DDL and procedure source.

---

## Guardrail Rules (SP_VERIFY_FINDING)

1. **Confidence threshold**: Finding confidence < 0.70 → REJECTED
2. **Structured ref verification**: Every txn_id must exist in TRANSACTIONS; every account_id in ACCOUNTS; every obligation_id in OBLIGATION; identity refs must resolve to ACCOUNTS or DEVICE_LOGINS
3. **Clause ref verification**: Every clause_id must exist in CLAUSE
4. **Weak-signal rule**: If a finding has NO flow claims, NO national-ID identity claims, and NO structuring claims → REJECTED "insufficient evidence — weak signal only"
5. **All-or-nothing**: Finding is VERIFIED only if every claim passes all checks; otherwise REJECTED naming the failing claim(s)

## Filing Rules (SP_DRAFT_FILING)

1. **Refuses** unless finding status = VERIFIED
2. **One STR per involved bank**, addressed to that bank's FIU:
   - CBUAE → UAE FIU (goAML)
   - SAMA → GDFI
   - CBB → Financial Intelligence Directorate
3. **Data minimisation**: Each STR cites only its own bank's txn/account IDs; cross-bank signals described anonymously
4. **Grounding check**: After LLM generation, verifies no other bank's account IDs leaked into narrative
5. **One CONTROL_GAP_MEMO** for the board summarising regulatory obligations with gaps
6. All filings are DRAFT_PENDING_HUMAN — never auto-filed

---

## Test Results

### Validation Harness: `validation/validate_findings.py`

**Result: 19 passed, 0 failed**

| # | Test | Result | Detail |
|---|------|--------|--------|
| 1 | RING-001 → VERIFIED finding | PASS | FND-0003 (TYP-0003) |
| 2 | RING-001 → 3 STR filings | PASS | BANK_A, BANK_B, BANK_C |
| 3 | RING-001 → 1 CONTROL_GAP_MEMO | PASS | |
| 4 | STR-BANK_A grounding passed | PASS | DRAFT_PENDING_HUMAN |
| 5 | STR-BANK_B grounding passed | PASS | DRAFT_PENDING_HUMAN |
| 6 | STR-BANK_C grounding passed | PASS | DRAFT_PENDING_HUMAN |
| 7 | STR-BANK_A correct FIU | PASS | UAE FIU (goAML) |
| 8 | STR-BANK_B correct FIU | PASS | GDFI |
| 9 | STR-BANK_C correct FIU | PASS | FID, Bahrain |
| 10 | RING-003 → VERIFIED finding | PASS | FND-0005 (TYP-0005) |
| 11 | RING-003 → 1 STR (single bank) | PASS | BANK_B only |
| 12 | RING-003 → 1 CONTROL_GAP_MEMO | PASS | |
| 13 | BENIGN-001 adhoc → REJECTED | PASS | Confidence 0.50 < 0.70 |
| 14 | SP_DRAFT_FILING refuses REJECTED | PASS | |
| 15-19 | All 5 typologies have VERIFIED findings | PASS | TYP-0001 through TYP-0005 |

### Manual Tests (run during session)

| Test | Result | Detail |
|------|--------|--------|
| Tamper test: fabricated txn_id | REJECTED | `FND-TAMPER-C99: FAIL: 1 of 1 txn_ids not found` |
| SP_DRAFT_FILING on DRAFT finding | REFUSED | `REFUSED: finding FND-TEST-DRAFT is DRAFT — only VERIFIED findings may be filed` |

---

## Findings Summary

| Finding | Typology | Class | Ring Match | Status | Claims | Filings |
|---------|----------|-------|------------|--------|--------|---------|
| FND-0003 | TYP-0003 | FAN_IN_FAN_OUT_MULE | RING-001 | VERIFIED | 21 | 4 (3 STR + 1 memo) |
| FND-0005 | TYP-0005 | CASH_STRUCTURING | RING-003 | VERIFIED | 5 | 2 (1 STR + 1 memo) |
| FND-0006 | ADHOC | ADHOC | BENIGN-001 | REJECTED | 0 | 0 |
| FND-0007 | TYP-0004 | FAN_IN_FAN_OUT_MULE | RING-005 | VERIFIED | 21 | 0 |
| FND-0008 | TYP-0001 | CIRCULAR_LAYERING | RING-004 | VERIFIED | 9 | 0 |
| FND-0009 | TYP-0002 | SHARED_IDENTITY | RING-002 | VERIFIED | 10 | 0 |

---

## Sample STR Draft (BANK_A — FND-0003)

> ## Narrative
>
> Gulf National Bank has identified a cross-bank fan-in/fan-out mule network involving accounts held at our institution, with a total network value of AED 372,968.44.
>
> Our monitoring detected three accounts at Gulf National Bank—A0000036, A0000094, and A0000076—that acted as source mules by transferring funds to a consolidation account A0000095 also held at our institution [C14]. Specifically, A0000076 sent 1 transfer totalling AED 31,013.96 to A0000095 on 2026-09-17 [C05]; A0000036 sent 1 transfer totalling AED 22,382.44 to A0000095 on 2026-09-15 [C02]; and A0000094 sent 1 transfer totalling AED 20,821.61 to A0000095 on 2026-09-17 [C04].
>
> Cross-institution analysis revealed that A0000095 served as the central consolidation point for this network [C12], receiving funds from a total of nine source mule accounts across multiple consortium institutions [C14]. The consolidated funds were subsequently distributed to two funnel accounts held at other consortium institutions [C13].
>
> This activity raises concerns under CBUAE Article 31 [C16] and SAMA Article 8 [C17]. Our monitoring systems were unable to detect the full scope as the network only became visible through cross-institution analysis [C19][C20][C21].
>
> ## Supporting Evidence
> - [C02] A0000036 transfer to A0000095 (TX00008692)
> - [C04] A0000094 transfer to A0000095 (TX00008688)
> - [C05] A0000076 transfer to A0000095 (TX00008690)
> - [C12–C14] Role assignments
> - [C15–C17] Regulatory obligations
> - [C19–C21] Control gap analysis

---

## Sample Board Control Gap Memorandum (FND-0003)

> **TO:** ARGUS Consortium Board of Directors
> **RE:** Control Gaps in Finding FND-0003 (Cross-Bank Mule Network)
>
> A cross-bank mule network (AED 372,968.44) exploits the absence of Control C-12 (cross-institution network monitoring), creating **three material gaps**:
>
> 1. **OB-03 (FATF 16.4)**: Layering detection requires cross-institution visibility — C-12 not deployed
> 2. **OB-04 (CBUAE Art. 31)**: Money mule monitoring requires cross-bank pattern detection — C-12 not deployed
> 3. **OB-05 (SAMA Art. 8)**: SAMA explicitly requires cross-institution capability — C-12 not deployed
>
> **Recommended Actions**: Deploy C-12 immediately; conduct retrospective analysis; file enhanced STRs; implement automated cross-bank detection rules.

---

## Design Principle

**Claims are facts computed by SQL; the LLM only writes prose from verified claims.** Nothing is filed automatically — every filing is a draft awaiting a human.
