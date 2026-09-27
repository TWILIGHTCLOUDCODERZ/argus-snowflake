# ARGUS · Findings & Filing Validation Report

**Result: 46 passed, 0 failed**

| # | Test | Status | Detail |
|---|------|--------|--------|
| 1 | Grounding negative: fabricated amount fails | PASS | violations=['999999.99'] |
| 2 | Grounding positive: correct amounts pass | PASS | numbers_checked=1, violations=[] |
| 3 | Grounding: article refs (16.4, FC-6.1) ignored | PASS | numbers_checked=1, violations=[] |
| 4 | RING-001 has SUMMARY claim | PASS | claim: SUMMARY: Finding FND-0010 involves 3 banks (BANK_B, BANK_C, BANK_A) with 12 memb... |
| 5 | RING-003 has SUMMARY claim | PASS | claim: SUMMARY: Finding FND-0011 involves 1 banks (BANK_B) with 1 member accounts. Tota... |
| 6 | RING-001 re-verified | PASS | result: VERIFIED |
| 7 | RING-003 re-verified | PASS | result: VERIFIED |
| 8 | FND-0010-STR-BANK_A number grounding: nums checked > 0 | PASS | numbers_checked=4, violations=[] |
| 9 | FND-0010-STR-BANK_A number grounding: 0 violations | PASS | violations=[] |
| 10 | FND-0010-STR-BANK_B number grounding: nums checked > 0 | PASS | numbers_checked=5, violations=[] |
| 11 | FND-0010-STR-BANK_B number grounding: 0 violations | PASS | violations=[] |
| 12 | FND-0010-STR-BANK_C number grounding: nums checked > 0 | PASS | numbers_checked=5, violations=[] |
| 13 | FND-0010-STR-BANK_C number grounding: 0 violations | PASS | violations=[] |
| 14 | FND-0010-MEMO number grounding: nums checked > 0 | PASS | numbers_checked=1, violations=[] |
| 15 | FND-0010-MEMO number grounding: 0 violations | PASS | violations=[] |
| 16 | FND-0011-STR-BANK_B number grounding: nums checked > 0 | PASS | numbers_checked=2, violations=[] |
| 17 | FND-0011-STR-BANK_B number grounding: 0 violations | PASS | violations=[] |
| 18 | FND-0011-MEMO number grounding: nums checked > 0 | PASS | numbers_checked=1, violations=[] |
| 19 | FND-0011-MEMO number grounding: 0 violations | PASS | violations=[] |
| 20 | RING-001 memo cites claims with [Cnn] | PASS | cited_claims=['C15', 'C18', 'C19', 'C20', 'C17', 'C16', 'C22', 'C21'] |
| 21 | A0000004 adhoc REJECTED with weak-signal reason | PASS | reason: Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring) |
| 22 | SP_DRAFT_FILING refuses REJECTED adhoc | PASS | result: REFUSED: finding FND-0013 is REJECTED — only VERIFIED findings may be filed |
| 23 | RING-001 has VERIFIED finding | PASS | Finding: FND-0010 |
| 24 | RING-001 has 3 STR filings | PASS | Got 3 STRs: ['BANK_A', 'BANK_B', 'BANK_C'] |
| 25 | RING-001 has 1 CONTROL_GAP_MEMO | PASS | Got 1 memos |
| 26 | STR-BANK_A number grounding passed | PASS | Status: DRAFT_PENDING_HUMAN, number_violations: [] |
| 27 | STR-BANK_B number grounding passed | PASS | Status: DRAFT_PENDING_HUMAN, number_violations: [] |
| 28 | STR-BANK_C number grounding passed | PASS | Status: DRAFT_PENDING_HUMAN, number_violations: [] |
| 29 | STR-BANK_A correct FIU | PASS | FIU: UAE Financial Intelligence Unit (goAML) |
| 30 | STR-BANK_B correct FIU | PASS | FIU: General Directorate of Financial Investigation (GDFI) |
| 31 | STR-BANK_C correct FIU | PASS | FIU: Financial Intelligence Directorate (FID), Bahrain |
| 32 | RING-003 has VERIFIED finding | PASS | Finding: FND-0011 |
| 33 | RING-003 has 1 STR filing (single bank) | PASS | Got 1 STRs |
| 34 | RING-003 has 1 CONTROL_GAP_MEMO | PASS | Got 1 memos |
| 35 | BENIGN-001 adhoc finding REJECTED | PASS | Finding: FND-0013, reason: Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring) |
| 36 | BENIGN-001 weak-signal reason explicit | PASS | reason: Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring) |
| 37 | SP_DRAFT_FILING refuses REJECTED finding | PASS | REFUSED: only VERIFIED findings may be filed |
| 38 | TYP-0001 has VERIFIED finding | PASS | Ring match: RING-004 |
| 39 | TYP-0002 has VERIFIED finding | PASS | Ring match: RING-002 |
| 40 | TYP-0003 has VERIFIED finding | PASS | Ring match: RING-001 |
| 41 | TYP-0004 has VERIFIED finding | PASS | Ring match: RING-005 |
| 42 | TYP-0005 has VERIFIED finding | PASS | Ring match: RING-003 |
| 43 | Data minimisation: FND-0010-STR-BANK_A | PASS | status=DRAFT_PENDING_HUMAN; other-bank IDs in text: none |
| 44 | Data minimisation: FND-0010-STR-BANK_B | PASS | status=DRAFT_PENDING_HUMAN; other-bank IDs in text: none |
| 45 | Data minimisation: FND-0010-STR-BANK_C | PASS | status=DRAFT_PENDING_HUMAN; other-bank IDs in text: none |
| 46 | Data minimisation: FND-0011-STR-BANK_B | PASS | status=DRAFT_PENDING_HUMAN; other-bank IDs in text: none |

## Findings Summary

| Finding | Typology | Class | Status | Claims | Filings |
|---------|----------|-------|--------|--------|--------|
| FND-0007 | TYP-0004 | FAN_IN_FAN_OUT_MULE | VERIFIED | 21 | 0 |
| FND-0008 | TYP-0001 | CIRCULAR_LAYERING | VERIFIED | 9 | 0 |
| FND-0009 | TYP-0002 | SHARED_IDENTITY | VERIFIED | 10 | 0 |
| FND-0010 | TYP-0003 | FAN_IN_FAN_OUT_MULE | VERIFIED | 22 | 4 |
| FND-0011 | TYP-0005 | CASH_STRUCTURING | VERIFIED | 6 | 2 |
| FND-0012 | TYP-0003 | FAN_IN_FAN_OUT_MULE | VERIFIED | 22 | 0 |
