# ARGUS — CoCo Planning Review

**Session:** S1 — Planning & Exploration
**Date:** 2026-09-27
**Database:** `ARGUS` on connection `argus`

---

## 1. Data Profile

### 1.1 Inventory

| Schema | Object | Type | Rows |
|--------|--------|------|------|
| RAW | BANKS | table | 3 |
| RAW | CUSTOMERS | table | 540 |
| RAW | ACCOUNTS | table | 627 |
| RAW | DEVICE_LOGINS | table | 1,606 |
| RAW | TRANSACTIONS | table | 8,747 |
| CURATED | ACCOUNT_ACTIVITY | view | — |
| CURATED | STRUCTURING_CANDIDATES | view | — |
| GOVERNED | REGULATION | table | 2 |
| GOVERNED | CLAUSE | table | 4 |
| GOVERNED | OBLIGATION | table | 4 |
| GOVERNED | CONTROL | table | 3 |
| GOVERNED | CONTROL_DATA_LINEAGE | table | 3 |
| GOVERNED | CONTROL_OBLIGATION | table | 4 |
| GOVERNED | TYPOLOGY_OBLIGATION | table | 7 |
| GOVERNED | TYPOLOGY_EVIDENCE | table | **0** (empty) |
| GOVERNED | BANK_IDENTIFIER_EXPOSURE | view | — |
| GOVERNED | SHARED_BAD_ACTOR_SIGNAL | view | — |
| GOVERNED | CROSS_BANK_FLOW_EDGES | view | — |
| GOVERNED | CONTROL_GAP | view | — |
| GOVERNED | TYPOLOGY_EXPOSURE | view | — |
| GOVERNED | ARGUS_FRAUD_SV | semantic view | — |
| GOVERNED | ARGUS_REGTWIN_SV | semantic view | — |

**Schemas:** RAW, CURATED, GOVERNED, PUBLIC (empty), INFORMATION_SCHEMA.

### 1.2 RAW Tables — Key Numbers

**TRANSACTIONS** (8,747 rows)

| Metric | Value |
|--------|-------|
| Date range | 2026-09-01 06:01 → 2026-09-30 22:58 (full September) |
| Rows per bank | BANK_A: 2,822 · BANK_B: 2,983 · BANK_C: 2,942 |
| Total value | A: 15.2M · B: 16.3M · C: 14.9M (AED) |
| Direction split | credit: 5,220 (59.7%) · debit: 3,527 (40.3%) |
| Avg amount | credit: 6,832 · debit: 3,017 |
| Max amount | 125,379.20 |
| Channel mix | card 39.7% · transfer 34.6% · wallet 20.5% · cash 5.1% |
| Purpose code mix | retail 39.7% · p2p 21.1% · salary 19.6% · remittance 14.5% · other 5.1% |
| Null counterparty_iban | 10 of 8,747 (0.1%) |
| All other columns | 0 nulls |

**Cross-bank transactions** (counterparty_bank ∈ {BANK_A, BANK_B, BANK_C} and ≠ bank_id):

| Metric | Value |
|--------|-------|
| Total cross-bank txns | **14** |
| By counterparty_bank | BANK_A: 18 total (incl same-bank), BANK_B: 16, BANK_C: 16 |
| Counterparty = EXTERNAL | 8,697 (99.4% of all txns) |

> **Note:** Only 14 genuinely cross-bank transactions vs 8,697 external — the planted rings are deliberately sparse, which is realistic (mule flows are needles in a haystack). But detection code must handle a very low signal-to-noise ratio.

**CUSTOMERS** (540 rows)

| Metric | Value |
|--------|-------|
| Per bank | 180 each (perfectly balanced) |
| KYC risk rating | low 68.9% · medium 25.9% · high 5.2% (28 customers) |
| Null rates | 0 across all columns (national_id_hash, phone_hash, email, nationality, kyc_risk_rating) |
| Cross-bank national_id_hash | **1 identity** appears at all 3 banks (the planted ring participant) |

**ACCOUNTS** (627 rows)

| Metric | Value |
|--------|-------|
| Per bank/type | ~60-80 per (bank, type) — balanced |
| Types | current, savings, wallet |
| 627 accounts / 540 customers | ~1.16 accounts per customer |

**DEVICE_LOGINS** (1,606 rows)

| Metric | Value |
|--------|-------|
| Distinct devices | 718 |
| Cross-bank devices | **2** (same device_hash seen at >1 bank) |

**BANKS** (3 rows): BANK_A, BANK_B, BANK_C.

### 1.3 Governed Layer — Key Numbers

**Shared Bad Actor Signal** (8 rows from the view)

| identifier_type | bank_count | linked_accounts | risk_weight |
|-----------------|------------|-----------------|-------------|
| national_id | 3 | 3 | 2.0 |
| device | 3 | 3 | 1.8 |
| device | 2 | 2 | 0.9 |
| counterparty_iban | 2 | 2 | 0.8 (×5 rows) |

**Control Gap** (4 obligations assessed)

| Obligation | Required Scope | Gap? | Severity |
|------------|---------------|------|----------|
| OB-01: Cash structuring detection | single_bank | NO | NONE |
| OB-02: Cross-institution identity/device reuse | cross_bank | **YES** | HIGH |
| OB-03: Cross-institution layering/circular flows | cross_bank | **YES** | HIGH |
| OB-04: Fan-in/fan-out mule networks | cross_bank | **YES** | HIGH |

Control C-12 (Cross-institution network monitoring) exists but has `status = not_deployed`, so all three cross-bank obligations are flagged as gaps.

**Structuring Candidates** (CURATED view): 1 account, 10 near-threshold cash deposits, 531K AED total.

---

## 2. Ontology ↔ Schema Check

### 2.1 Structured Entities (ontology section 1 → RAW)

| Ontology Entity | Table Exists? | Ontology Attributes | Actual Columns | Mismatches |
|-----------------|--------------|---------------------|----------------|------------|
| **bank** | ✅ RAW.BANKS | bank_id, bank_name, country, regulator | BANK_ID, BANK_NAME, COUNTRY, REGULATOR | None — exact match |
| **customer** | ✅ RAW.CUSTOMERS | customer_id, bank_id, full_name, national_id, national_id_hash, phone, phone_hash, email, nationality, dob, kyc_risk_rating, onboarded_at | All 12 present | None — exact match |
| **account** | ✅ RAW.ACCOUNTS | account_id, bank_id, customer_id, iban, account_type, currency, status, opened_at | All 8 present | None — exact match |
| **device_login** | ✅ RAW.DEVICE_LOGINS | login_id, bank_id, account_id, device_hash, ip_hash, ts | All 6 present | None — exact match |
| **transaction** | ✅ RAW.TRANSACTIONS | txn_id, bank_id, account_id, direction, amount, currency, channel, counterparty_iban, counterparty_bank, purpose_code, ts | All 11 present | None — exact match |

### 2.2 Clean Room (ontology section 2 → GOVERNED views)

| Ontology Object | Built? | Notes |
|-----------------|--------|-------|
| shared_bad_actor_signal | ✅ View in GOVERNED | Attributes match: identifier_hash, identifier_type, contributing_bank_count, risk_weight. Extra columns in view: `banks` (ARRAY), `linked_accounts` — not in ontology but useful |
| bank_identifier_exposure | ✅ View in GOVERNED | Not in ontology but is the underlying view that feeds shared_bad_actor_signal |

### 2.3 Regulatory Twin (ontology section 3 → GOVERNED tables)

| Ontology Entity | Table Exists? | Ontology Attributes | Actual Columns | Mismatches |
|-----------------|--------------|---------------------|----------------|------------|
| **regulation** | ✅ | regulation_id, regulator, title, effective_date, source_uri | All 5 match | None |
| **clause** | ✅ | clause_id, regulation_id, article_ref, text | All 4 match | None |
| **obligation** | ✅ | obligation_id, clause_id, obligation_text, category | 5 cols: adds **REQUIRED_SCOPE** | ⚠️ `required_scope` exists in table but NOT in ontology; `category` exists in both |
| **control** | ✅ | control_id, name, description, coverage_scope, owner | 6 cols: adds **STATUS** | ⚠️ `status` exists in table but NOT in ontology |
| **control_data_lineage** | ✅ | control_id, data_object, semantic_view | All 3 match | None |
| **control_gap** | ✅ (view) | gap_id, control_id, obligation_id, typology_id, severity, rationale | View cols: obligation_id, obligation_text, required_scope, article_ref, regulator, is_gap, severity, mapped_controls, rationale | ⚠️ Ontology describes a table with gap_id/control_id/typology_id; actual is a computed view with different shape |

**Extra tables not in ontology:**
- `CONTROL_OBLIGATION` (junction: control_id, obligation_id) — not in ontology
- `TYPOLOGY_OBLIGATION` (junction: typology_id, obligation_id) — not in ontology

### 2.4 Correlation + Output (ontology section 4)

| Ontology Entity | Built? | Notes |
|-----------------|--------|-------|
| **typology** | ❌ **No table** | `TYPOLOGY_OBLIGATION` and `TYPOLOGY_EVIDENCE` reference typology_ids (RING-001..005) but there is no `TYPOLOGY` master table with name/description/structure/first_seen/banks_involved |
| **typology_evidence** | ⚠️ Table exists but **empty** (0 rows) | Extra column `bank_id` in table, not in ontology |
| **finding** | ❌ **Not built** | Ontology: finding_id, typology_id, confidence, status, created_at |
| **finding_claim** | ❌ **Not built** | Ontology: claim_id, finding_id, claim_text, structured_ref, clause_ref, confidence |
| **filing** | ❌ **Not built** | Ontology: filing_id, finding_id, filing_type, destination, rendered_uri, status |

---

## 3. Gaps & Risks

### 3.1 Critical Gaps (must build)

| # | Gap | Impact |
|---|-----|--------|
| G1 | **TYPOLOGY table missing** | No master record for discovered fraud patterns. TYPOLOGY_OBLIGATION references RING-001..005 but the typology itself (name, description, structure, banks_involved) is not stored. |
| G2 | **FINDING table missing** | Cannot record investigation outcomes. The entire evidence→finding→filing chain is blocked. |
| G3 | **FINDING_CLAIM table missing** | Cannot decompose findings into atomic, evidence-backed claims — the core guardrail mechanism. |
| G4 | **FILING table missing** | Cannot track regulatory filings/memos. |
| G5 | **TYPOLOGY_EVIDENCE is empty** | The link between typologies and their constituent entities/transactions has no data. |
| G6 | **Control C-12 is `not_deployed`** | The only cross-bank control exists in metadata but is not operationalized — the three HIGH-severity control gaps cannot be resolved without deploying consortium monitoring. |

### 3.2 Schema vs Ontology Drift

| # | Issue |
|---|-------|
| D1 | `obligation.required_scope` and `control.status` exist in Snowflake but not in ontology YAML |
| D2 | `control_obligation` and `typology_obligation` junction tables exist in Snowflake but not in ontology |
| D3 | `control_gap` is a computed view, not a table — ontology describes it as a table with `gap_id` PK |
| D4 | `typology_evidence` has an extra `bank_id` column not in ontology |
| D5 | `shared_bad_actor_signal` view has extra columns `banks`, `linked_accounts` vs ontology |

### 3.3 Data Quality Observations

| # | Observation | Risk |
|---|-------------|------|
| Q1 | Only 14 cross-bank transactions (0.16% of all txns) — very sparse signal | Detection logic must handle extreme class imbalance; test recall carefully |
| Q2 | 1 cross-bank national_id, 2 cross-bank devices — the planted rings are minimal | Good for precision testing, but need to verify the typology discovery engine doesn't miss them |
| Q3 | Structuring candidates: only 1 account flagged | Threshold (6+ near-threshold cash deposits) may be too aggressive, or data generation was conservative |
| Q4 | No primary keys or NOT NULL constraints on any table | All columns are nullable VARCHAR (except amount=NUMBER, dates=DATE/TIMESTAMP). Fine for synthetic data but would need constraints in production |

### 3.4 Risk Items

| # | Risk | Mitigation |
|---|------|------------|
| R1 | Missing TYPOLOGY/FINDING/FILING tables block the demo's core narrative | Build these in the next session — they're straightforward DDL + seed data |
| R2 | Empty TYPOLOGY_EVIDENCE means the graph/typology agent has nothing to query | Populate from the planted rings in `data/ground_truth/planted_rings.json` |
| R3 | Semantic views exist but need verification | Validate ARGUS_FRAUD_SV and ARGUS_REGTWIN_SV with the ontology's validation questions |
| R4 | No Cortex Search index yet for regulatory documents | Required for the Policy agent RAG over regulation/policy docs |

---

## 4. Workflow Outline

### Signal → Evidence → Finding → Filing

```
STEP 1: SIGNAL DETECTION
├── Consortium signals ──► GOVERNED.SHARED_BAD_ACTOR_SIGNAL (view) ✅ EXISTS
│   └── fed by GOVERNED.BANK_IDENTIFIER_EXPOSURE (view) ✅ EXISTS
├── Cross-bank flows ────► GOVERNED.CROSS_BANK_FLOW_EDGES (view) ✅ EXISTS
├── Structuring ─────────► CURATED.STRUCTURING_CANDIDATES (view) ✅ EXISTS
└── Account activity ────► CURATED.ACCOUNT_ACTIVITY (view) ✅ EXISTS

STEP 2: EVIDENCE CORRELATION
├── Typology discovery ──► GOVERNED.TYPOLOGY (table) ❌ MISSING
├── Typology evidence ───► GOVERNED.TYPOLOGY_EVIDENCE (table) ⚠️ EMPTY
├── Obligation mapping ──► GOVERNED.TYPOLOGY_OBLIGATION (table) ✅ EXISTS (7 rows)
└── Control gap calc ────► GOVERNED.CONTROL_GAP (view) ✅ EXISTS

STEP 3: FINDING (investigation record)
├── Finding ─────────────► GOVERNED.FINDING (table) ❌ MISSING
└── Finding claims ──────► GOVERNED.FINDING_CLAIM (table) ❌ MISSING
    (each claim → ≥1 txn row + ≥1 regulation clause)

STEP 4: FILING (action output)
└── Filing ──────────────► GOVERNED.FILING (table) ❌ MISSING
    (STR | control_gap_memo | board_memo → gmail | google_docs | slack | jira)
```

### Agent ↔ Object Mapping

| Agent | Snowflake Objects Used | Status |
|-------|----------------------|--------|
| **Retriever** | ARGUS_FRAUD_SV, ARGUS_REGTWIN_SV (semantic views) | ✅ Exist, need validation |
| **Graph/Typology** | SHARED_BAD_ACTOR_SIGNAL, CROSS_BANK_FLOW_EDGES, TYPOLOGY, TYPOLOGY_EVIDENCE | ⚠️ Views exist; tables missing/empty |
| **Policy** | Cortex Search over regulation docs | ❌ Not built (no Cortex Search index) |
| **Twin** | REGULATION, CLAUSE, OBLIGATION, CONTROL, CONTROL_GAP, TYPOLOGY_EXPOSURE | ✅ All exist |
| **Narrative** | FINDING, FINDING_CLAIM | ❌ Tables missing |
| **Verifier** | FINDING_CLAIM (checks structured_ref + clause_ref) | ❌ Table missing |
| **Action** | FILING + MCP connectors (Jira, Gmail, Slack, Google Docs) | ❌ Table missing; MCP not wired |

---

## 5. Recommended Next Build Steps

### Priority 1 — Complete the Schema (unblocks everything)

1. **Create `GOVERNED.TYPOLOGY` table** — typology_id, name, description, structure (JSON), first_seen (timestamp), banks_involved (ARRAY), detection_query (VARCHAR).
2. **Populate `GOVERNED.TYPOLOGY_EVIDENCE`** — link RING-001..005 to their constituent accounts/transactions/devices. Derive from the planted ring definitions (the system should discover these, but seed data is needed for testing).
3. **Create `GOVERNED.FINDING` table** — finding_id, typology_id, confidence, status, created_at.
4. **Create `GOVERNED.FINDING_CLAIM` table** — claim_id, finding_id, claim_text, structured_ref (txn_id/account_id), clause_ref (clause_id), confidence.
5. **Create `GOVERNED.FILING` table** — filing_id, finding_id, filing_type, destination, rendered_uri, status, created_at.

### Priority 2 — Sync the Ontology

6. **Update `ontology/argus_ontology.yaml`** to add:
   - `obligation.required_scope` attribute
   - `control.status` attribute
   - `control_obligation` junction entity
   - `typology_obligation` junction entity
   - `typology_evidence.bank_id` attribute
   - Mark `control_gap` as a computed view, not a table

### Priority 3 — Validate Semantic Views

7. **Run the 6 validation questions** from the ontology against ARGUS_FRAUD_SV and ARGUS_REGTWIN_SV via Cortex Analyst. Fix any gaps.

### Priority 4 — Build the Intelligence Layer

8. **Typology discovery engine** — community detection over the cross-bank graph (SHARED_BAD_ACTOR_SIGNAL + CROSS_BANK_FLOW_EDGES). Should discover RING-001..005 without looking at ground truth.
9. **Cortex Search index** over regulatory documents for the Policy agent.
10. **Evidence ledger population** — when a typology is discovered, auto-populate TYPOLOGY_EVIDENCE and TYPOLOGY_OBLIGATION.

### Priority 5 — Action Loop

11. **Wire MCP connectors** — Jira, Gmail, Google Docs, Slack.
12. **Build the FILING workflow** — narrative agent drafts → verifier checks → action agent files.
13. **Streamlit investigator app** scaffolding.

---

*Generated by CoCo session S1 — read-only exploration, no Snowflake objects modified.*
