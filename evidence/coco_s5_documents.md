# ARGUS · CoCo Session S5 — Document AI Evidence

**Session:** S5 · Document parsing, obligation extraction, Cortex Search  
**Date:** 2026-09-27  
**SQL:** `sql/08_documents.sql`

---

## 1. Document Parsing (AI_PARSE_DOCUMENT)

7 PDFs parsed with `AI_PARSE_DOCUMENT(TO_FILE(...), {'mode': 'LAYOUT'})`:

| Document | Type | Content Length |
|----------|------|---------------|
| circulars/CBB_FC_MODULE_2024.pdf | circular | 1,218 chars |
| circulars/CBUAE_AML_2024.pdf | circular | 1,174 chars |
| circulars/FATF_R16_WIRE.pdf | circular | 733 chars |
| circulars/SAMA_AMLCTF_2023.pdf | circular | 1,409 chars |
| filings/STR-2025-1190_BANK_C.pdf | filing | 1,099 chars |
| filings/STR-2026-0412_BANK_A.pdf | filing | 1,268 chars |
| filings/STR-2026-0588_BANK_B.pdf | filing | 1,252 chars |

## 2. Document Chunking

13 chunks across 7 documents via `SPLIT_TEXT_RECURSIVE_CHARACTER(content, 'markdown', 800, 100)`:

| Document | Chunks |
|----------|--------|
| CBB_FC_MODULE_2024.pdf | 2 |
| CBUAE_AML_2024.pdf | 2 |
| FATF_R16_WIRE.pdf | 1 |
| SAMA_AMLCTF_2023.pdf | 2 |
| STR-2025-1190_BANK_C.pdf | 2 |
| STR-2026-0412_BANK_A.pdf | 2 |
| STR-2026-0588_BANK_B.pdf | 2 |

## 3. Cortex Search Service

`ARGUS.GOVERNED.POLICY_SEARCH` created on `chunk` with attributes `doc_type`, `regulator`, `relative_path`.

### Search Verification

**a) "mule accounts fed from multiple institutions" (filter: regulator = SAMA)**  
Top result: `circulars/SAMA_AMLCTF_2023.pdf` — Article 8 (Money Mule and Pass-Through Accounts). **PASS**

**b) "deadline to file a suspicious transaction report" (filter: doc_type = circular)**  
Top result: `circulars/CBB_FC_MODULE_2024.pdf` — FC-6.1 (Timely Suspicious Transaction Reporting, "within three business days"). **PASS**

**c) "investigator could not see accounts at other institutions" (filter: doc_type = filing)**  
Top 2 results:
1. `filings/STR-2026-0588_BANK_B.pdf` — "we could not see whether the senders or the beneficiary were part of a wider network"
2. `filings/STR-2025-1190_BANK_C.pdf` — "we could not confirm whether the identity was also in use at other institutions"  
**PASS**

## 4. Obligation Extraction (AI_COMPLETE · claude-sonnet-4-5)

11 obligations extracted from 4 circulars (10 match answer key + 1 novel):

| Regulation | Article | Scope | Status |
|-----------|---------|-------|--------|
| REG-CBB-FC-2024 | FC-1.5 | cross_bank | MATCH |
| REG-CBB-FC-2024 | FC-4.2 | cross_bank | MATCH |
| REG-CBB-FC-2024 | FC-6.1 | single_bank | MATCH |
| REG-CBUAE-AML-2024 | Art. 15 | single_bank | MATCH |
| REG-CBUAE-AML-2024 | Art. 22 | cross_bank | MATCH |
| REG-CBUAE-AML-2024 | Art. 31 | cross_bank | MATCH |
| REG-FATF-R16 | Sec. 16.1 | cross_bank | **REVIEW** |
| REG-FATF-R16 | Sec. 16.4 | cross_bank | MATCH |
| REG-SAMA-AML-2023 | Art. 8 | cross_bank | MATCH |
| REG-SAMA-AML-2023 | Art. 12 | single_bank | MATCH |
| REG-SAMA-AML-2023 | Art. 17 | cross_bank | MATCH |

## 5. Extraction Scorecard

```
Article recall:     10/10  (100.0%)
Scope accuracy:     10/10  (100.0%)
Regulator accuracy: 10/10  (100.0%)
Effective date:      9/10  (90.0% — FATF has no date in document, correctly null)
Scope mismatches:     0
Missing articles:     0
Novel extractions:    1    (FATF Sec. 16.1 → review queue)
```

## 6. Twin Update (Human-in-the-Loop)

**Matched (10 articles, scope agrees) → twin updated:**

| Table | Rows Updated | Source |
|-------|-------------|--------|
| REGULATION | 4 | cortex_extraction |
| CLAUSE | 10 | cortex_extraction |
| OBLIGATION | 10 | cortex_extraction |

```sql
SELECT source, COUNT(*) FROM ARGUS.GOVERNED.OBLIGATION GROUP BY 1;
-- cortex_extraction  10
```

**Review Queue (1 item — novel article not in answer key):**

| regulation_id | article_ref | proposed_scope | reason | status |
|--------------|-------------|---------------|--------|--------|
| REG-FATF-R16 | Sec. 16.1 | cross_bank | Extracted article not in answer key | PENDING_REVIEW |

## 7. Past Filings Extraction

3 STRs extracted from filing PDFs:

| Filing ID | Institution | Regulator | FIU | Filed On | Typology | Cross-Inst Limitation |
|-----------|------------|-----------|-----|----------|----------|----------------------|
| STR-2025-1190 | Peninsula Finance NBFC (BANK_C) | CBB | Financial Intelligence Directorate (FID), Bahrain | 2025-11-06 | Suspected synthetic identity | TRUE |
| STR-2026-0412 | Gulf National Bank (BANK_A) | CBUAE | UAE Financial Intelligence Unit | 2026-03-18 | Cash structuring below threshold | FALSE |
| STR-2026-0588 | Levant Commercial (BANK_B) | SAMA | General Directorate of Financial Investigation | 2026-05-27 | Money mule consolidation account | TRUE |

## 8. Typology Exposure (Correlation Check)

```sql
SELECT typology_id, COUNT_IF(is_gap) AS gaps
FROM ARGUS.GOVERNED.TYPOLOGY_EXPOSURE GROUP BY 1 ORDER BY 1;
```

| Typology | Gaps |
|----------|------|
| RING-001 | 3 |
| RING-002 | 3 |
| RING-003 | **0** |
| RING-004 | 2 |
| RING-005 | 3 |
| RING-006 | 3 |

RING-003 has 0 gaps (structuring obligations fully covered by single-bank controls).  
All other rings have >0 gaps (cross-bank obligations unmet due to C-12 not deployed).  
**PASS — correlation intact after twin update.**

## 9. Objects Created

| Object | Type | Schema |
|--------|------|--------|
| DOCS_STAGE | Stage | ARGUS.GOVERNED |
| DOCUMENTS | Table | ARGUS.GOVERNED |
| DOCUMENT_CHUNKS | Table | ARGUS.GOVERNED |
| POLICY_SEARCH | Cortex Search Service | ARGUS.GOVERNED |
| EXTRACTED_OBLIGATIONS | Table | ARGUS.GOVERNED |
| EXTRACTION_EVAL | Table | ARGUS.GOVERNED |
| OBLIGATION_REVIEW_QUEUE | Table | ARGUS.GOVERNED |
| PAST_FILINGS | Table | ARGUS.GOVERNED |
