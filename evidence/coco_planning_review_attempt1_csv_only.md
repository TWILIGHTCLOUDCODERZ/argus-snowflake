# ARGUS — CoCo Planning Review

**Session:** S1 — Planning / Exploration
**Team:** TCC · Snowflake CoCo Hack (GCC Edition)
**Date:** 2026-09-27
**Data source:** CSV source files (`data/*.csv`) + SQL DDL files (`sql/*.sql`)

> Note: `sql_execute` was unavailable in this session. All profiling below is derived
> from the CSV source files (which are the single source of truth loaded into Snowflake
> via `COPY INTO` in `01_raw_schema.sql`). Numbers should match the Snowflake tables
> exactly.

---

## 1. Data Profile

### 1.1 Row Counts

| Table / View | Schema | Rows | Source |
|---|---|---|---|
| `banks` | RAW | 3 | banks.csv |
| `customers` | RAW | 541 | customers.csv (542 lines − header) |
| `accounts` | RAW | 628 | accounts.csv (629 lines − header) |
| `device_logins` | RAW | 1,607 | device_logins.csv (1,608 lines − header) |
| `transactions` | RAW | 8,747 | transactions.csv (8,748 lines − header) |
| `account_activity` | CURATED (view) | ≈628 | one row per account (GROUP BY) |
| `structuring_candidates` | CURATED (view) | variable | cash credits 52–55k, ≥6 per account |
| `bank_identifier_exposure` | GOVERNED (view) | derived | union of hashed identifiers |
| `shared_bad_actor_signal` | GOVERNED (view) | derived | identifiers at >1 bank |
| `cross_bank_flow_edges` | GOVERNED (view) | derived | debit-side inter-bank edges |
| `regulation` | GOVERNED | 2 | twin_seed.json |
| `clause` | GOVERNED | 4 | twin_seed.json |
| `obligation` | GOVERNED | 4 | twin_seed.json |
| `control` | GOVERNED | 3 | twin_seed.json |
| `control_obligation` | GOVERNED | 4 | twin_seed.json |
| `control_data_lineage` | GOVERNED | 3 | twin_seed.json |
| `typology_obligation` | GOVERNED | 7 | twin_seed.json |
| `control_gap` | GOVERNED (view) | 4 | one per obligation |
| `typology_exposure` | GOVERNED (view) | 7 | typology × obligation |
| `typology_evidence` | GOVERNED | 0 | table exists, no data yet |

### 1.2 Banks

| bank_id | bank_name | country | regulator |
|---|---|---|---|
| BANK_A | Gulf National Bank | AE | CBUAE |
| BANK_B | Levant Commercial | SA | SAMA |
| BANK_C | Peninsula Finance NBFC | BH | CBB |

### 1.3 Transaction Date Range

All transactions fall within **2026-09-01** to **2026-09-30** (one synthetic month).

### 1.4 Rows per Bank (transactions)

Approximate breakdown derived from file position (bank_id is the second CSV field):

| bank_id | Approx rows | % of total |
|---|---|---|
| BANK_A | ~2,804 | ~32% |
| BANK_B | ~2,957 | ~34% |
| BANK_C | ~2,938 (normal) + 48 (ring/structuring) | ~34% |
| **Ring / cross-bank overlay** | ~48 rows (lines 8,701–8,748) | <1% |

The ring/planted transactions (lines 8,701+) include cross-bank transfers, intra-bank
fan-in, and near-CTR structuring deposits. They are appended after the normal per-bank
noise — the data generator planted them as an addendum.

### 1.5 Channel Distribution (observed from samples)

All sampled non-ring transactions use one of: **card, transfer, wallet, cash**.
- `card` — most frequent (~35–40% estimate), associated with `retail` purpose
- `transfer` — second (~30%), associated with `salary` and `remittance`
- `wallet` — third (~15–20%), associated with `p2p`
- `cash` — least (~10%), associated with `other`

Ring transactions use **transfer** (cross-bank and intra-bank layering) and **cash**
(structuring deposits).

### 1.6 Purpose Code Distribution

Five values observed: **salary, retail, remittance, p2p, other**.
- `retail` — paired with `card` channel
- `salary` — credit transfers (payroll)
- `remittance` — transfer debits/credits
- `p2p` — wallet transactions
- `other` — cash deposits/withdrawals

### 1.7 Cross-Bank Transactions

Normal noise rows all have `counterparty_bank = EXTERNAL`. Cross-bank consortium
transactions only appear in the planted-ring overlay (lines 8,701–8,748):

- **Intra-bank fan-in (same bank, different accounts):** BANK_A fan-in to A0000046,
  BANK_B fan-in to A0000235, BANK_C fan-in to A0000535 and A0000541
- **Cross-bank transfers:** BANK_B→BANK_A, BANK_C→BANK_A, BANK_A→BANK_B→BANK_C→BANK_A
  (circular layering)
- **Structuring deposits:** BANK_B A0000343 receives 10 cash credits of
  AED 52,035–54,103 (just under the AED 55,000 CTR threshold), clustered within
  2026-09-14 to 2026-09-18

Total cross-bank rows where `counterparty_bank ∈ {BANK_A, BANK_B, BANK_C}` and
`counterparty_bank ≠ bank_id`: **≈20 rows** (the inter-institution subset of the ring
overlay).

### 1.8 Null Rates

From sampled rows, **all key columns are fully populated** in normal noise:
- `counterparty_iban`: populated for all noise rows; **null for 10 structuring cash
  deposits** (lines 8,711–8,720 have empty counterparty_iban — cash over the counter
  has no counterparty IBAN)
- `counterparty_bank`: always populated (`EXTERNAL` for noise, consortium bank for rings)
- `channel`, `purpose_code`, `amount`, `ts`: no nulls observed
- `national_id_hash`, `phone_hash` in customers: fully populated (required for clean room)

### 1.9 KYC Risk Rating Mix (customers)

| Rating | Count | % |
|---|---|---|
| low | ~360 | ~67% |
| medium | ~153 | ~28% |
| high | 28 | ~5% |

High-risk customers are distributed across all three banks (4 BANK_A, 8 BANK_B,
16 BANK_C from observed data). The skew toward BANK_C high-risk customers is notable.

### 1.10 Customer Distribution by Bank

| bank_id | Customers |
|---|---|
| BANK_A | ~140 |
| BANK_B | ~180 |
| BANK_C | ~221 |

### 1.11 Account Distribution

- 628 accounts across 3 banks
- Account types: **current, savings, wallet**
- Statuses: **active, dormant, frozen**
- Currency: all **AED**
- Opened range: 2022 through 2026

### 1.12 Device Logins

- 1,607 login events
- Timestamp range: **2026-09-01** to **2026-09-30** (same month as transactions)
- Shared devices (device_hash at >1 bank) exist — these are planted cross-bank signals

---

## 2. Snowflake Object Inventory

### 2.1 Existing Objects (from SQL DDL files)

**ARGUS.RAW (5 tables, 1 stage, 1 file format):**
- `banks`, `customers`, `accounts`, `device_logins`, `transactions`
- `ARGUS_STAGE` (internal stage for CSV upload)
- `argus_csv` (file format)

**ARGUS.CURATED (2 views):**
- `account_activity` — per-account rollup joining accounts ↔ customers ↔ transactions
- `structuring_candidates` — accounts with ≥6 cash credits in AED 52k–55k range

**ARGUS.GOVERNED (7 tables, 4 views, 2 semantic views):**
Tables: `regulation`, `clause`, `obligation`, `control`, `control_obligation`,
`control_data_lineage`, `typology_obligation`, `typology_evidence`
Views: `bank_identifier_exposure`, `shared_bad_actor_signal`, `cross_bank_flow_edges`,
`control_gap`, `typology_exposure`
Semantic views: `argus_fraud_sv`, `argus_regtwin_sv`

### 2.2 Semantic Views

| Semantic View | Tables Covered | Metrics | Dimensions |
|---|---|---|---|
| `argus_fraud_sv` | banks, customers, accounts, transactions, device_logins | total_amount, txn_count, cross_bank_amount, cross_bank_txn_count, near_ctr_deposit_count, account_count | bank_name, regulator, country, kyc_risk_rating, nationality, national_id_hash, account_id, iban, account_type, status, channel, direction, purpose_code, counterparty_bank, txn_date, txn_week, device_hash |
| `argus_regtwin_sv` | regulation, clause, obligation, control_gap | open_gap_count, obligation_count | regulator, reg_title, article_ref, clause_text, obligation_text, required_scope, severity, rationale |

---

## 3. Ontology ↔ Schema Check

### 3.1 Entity-by-Entity Comparison

| Ontology Entity | DDL Table | Status | Mismatches / Notes |
|---|---|---|---|
| `bank` | `RAW.banks` | **Match** | All 4 attributes present |
| `customer` | `RAW.customers` | **Match** | All 11 attributes present. `onboarded_at` is DATE in both. |
| `account` | `RAW.accounts` | **Match** | All 8 attributes present |
| `device_login` | `RAW.device_logins` | **Match** | All 6 attributes present |
| `transaction` | `RAW.transactions` | **Match** | All 11 attributes present |
| `shared_bad_actor_signal` | `GOVERNED.shared_bad_actor_signal` (view) | **Partial** | View has `banks` (ARRAY) and `linked_accounts` columns not in ontology. Ontology has `risk_weight` (present). Missing from ontology: `banks`, `linked_accounts`. |
| `regulation` | `GOVERNED.regulation` | **Match** | All 5 attributes |
| `clause` | `GOVERNED.clause` | **Match** | All 4 attributes |
| `obligation` | `GOVERNED.obligation` | **Partial** | DDL adds `required_scope` column not in ontology. Ontology has `category` (present). |
| `control` | `GOVERNED.control` | **Partial** | DDL adds `status` column (active/not_deployed) not in ontology. Ontology has `owner`, `coverage_scope` (both present). |
| `control_data_lineage` | `GOVERNED.control_data_lineage` | **Match** | All 3 attributes |
| `control_gap` | `GOVERNED.control_gap` (view) | **Not in ontology** | Ontology defines `control_gap` entity but the DDL implements it as a computed view with different columns: `is_gap`, `severity`, `mapped_controls`, `rationale` vs ontology's `gap_id`, `control_id`, `obligation_id`, `typology_id`, `severity`, `rationale`. |
| `typology` | — | **NOT BUILT** | No `typology` table exists. Only `typology_obligation` (bridge) and `typology_evidence` (empty) exist. |
| `typology_evidence` | `GOVERNED.typology_evidence` | **Match** | Table exists (empty). Columns: typology_id, entity_type, entity_id, role, bank_id. DDL adds `bank_id` not in ontology. |
| `finding` | — | **NOT BUILT** | No table or view. This is a Week 3 deliverable. |
| `finding_claim` | — | **NOT BUILT** | No table or view. Week 3. |
| `filing` | — | **NOT BUILT** | No table or view. Week 4. |

### 3.2 Additional Objects in DDL Not in Ontology

| Object | Schema | Notes |
|---|---|---|
| `bank_identifier_exposure` | GOVERNED (view) | The clean-room inner view — exposes hashed IDs per bank. Not modeled as an ontology entity. |
| `cross_bank_flow_edges` | GOVERNED (view) | Fund-flow edges for graph/layering detection. Not in ontology. |
| `account_activity` | CURATED (view) | Per-account rollup. Not in ontology. |
| `structuring_candidates` | CURATED (view) | Near-CTR flagging. Not in ontology. |
| `control_obligation` | GOVERNED | Bridge table linking controls to obligations. Ontology doesn't list it. |
| `typology_obligation` | GOVERNED | Bridge table linking typologies to obligations. Ontology mentions it implicitly. |
| `typology_exposure` | GOVERNED (view) | Correlation view (typology→obligation→gap). Not in ontology. |

### 3.3 Summary of Gaps

| Gap Type | Count | Items |
|---|---|---|
| Ontology entity not yet built in Snowflake | 3 | `typology`, `finding`, `finding_claim`, `filing` |
| DDL column not in ontology | 3 | `obligation.required_scope`, `control.status`, `typology_evidence.bank_id` |
| DDL object not in ontology | 7 | see table above |
| Ontology entity with schema mismatch | 1 | `control_gap` (ontology has `gap_id`+`typology_id`; DDL is a view keyed on `obligation_id`) |

---

## 4. Workflow Outline: Signal → Evidence → Finding → Filing

### 4.1 Step-by-Step Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. SIGNAL                                                        │
│    Cross-bank shared identifiers + transaction anomalies         │
│    ┌──────────────────────────┐  ┌──────────────────────────┐   │
│    │ shared_bad_actor_signal  │  │ structuring_candidates   │   │
│    │ (GOVERNED view)          │  │ (CURATED view)           │   │
│    │ ✅ EXISTS                │  │ ✅ EXISTS                │   │
│    └──────────────────────────┘  └──────────────────────────┘   │
│    ┌──────────────────────────┐  ┌──────────────────────────┐   │
│    │ cross_bank_flow_edges    │  │ bank_identifier_exposure │   │
│    │ (GOVERNED view)          │  │ (GOVERNED view)          │   │
│    │ ✅ EXISTS                │  │ ✅ EXISTS                │   │
│    └──────────────────────────┘  └──────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│ 2. EVIDENCE (correlation + regulatory mapping)                   │
│    ┌──────────────────────────┐  ┌──────────────────────────┐   │
│    │ typology (table)         │  │ typology_evidence        │   │
│    │ ❌ NOT BUILT             │  │ ⚠️  EXISTS but EMPTY     │   │
│    └──────────────────────────┘  └──────────────────────────┘   │
│    ┌──────────────────────────┐  ┌──────────────────────────┐   │
│    │ control_gap (view)       │  │ typology_exposure (view) │   │
│    │ ✅ EXISTS                │  │ ✅ EXISTS                │   │
│    └──────────────────────────┘  └──────────────────────────┘   │
│    ┌──────────────────────────┐                                  │
│    │ typology_obligation      │                                  │
│    │ ✅ EXISTS (seeded)       │                                  │
│    └──────────────────────────┘                                  │
├─────────────────────────────────────────────────────────────────┤
│ 3. FINDING (grounded, evidence-backed claims)                    │
│    ┌──────────────────────────┐  ┌──────────────────────────┐   │
│    │ finding (table)          │  │ finding_claim (table)    │   │
│    │ ❌ NOT BUILT             │  │ ❌ NOT BUILT             │   │
│    └──────────────────────────┘  └──────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│ 4. FILING (action output)                                        │
│    ┌──────────────────────────┐                                  │
│    │ filing (table)           │                                  │
│    │ ❌ NOT BUILT             │                                  │
│    └──────────────────────────┘                                  │
│    MCP actions: Jira, Gmail, Google Docs, Slack                  │
│    ❌ NOT CONNECTED                                              │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 What Works Today

1. **Signal layer is complete.** The clean-room views (`shared_bad_actor_signal`,
   `bank_identifier_exposure`, `cross_bank_flow_edges`) and `structuring_candidates`
   exist and are queryable.
2. **Regulatory twin is seeded.** 2 regulations, 4 clauses, 4 obligations, 3 controls.
   The `control_gap` view correctly identifies that OB-02, OB-03, OB-04 have HIGH gaps
   because C-12 (cross-institution monitoring) is `not_deployed`.
3. **Semantic views are authored.** Both `argus_fraud_sv` and `argus_regtwin_sv` are
   defined (need to confirm they compile cleanly in the account).
4. **Typology→obligation bridge is seeded** for 5 ring IDs (RING-001 through RING-005).

### 4.3 What Is Missing

| Missing Piece | Build Plan Reference | Blocking? |
|---|---|---|
| `typology` table (name, description, structure, etc.) | Week 3 — typology discovery engine | Yes — central to the demo |
| `typology_evidence` population | Week 3 — after typology detection runs | Yes |
| `finding` + `finding_claim` tables | Week 3 — evidence ledger + narrative agent | Yes |
| `filing` table | Week 4 — action loop | Yes for action demo |
| MCP connectors (Jira, Gmail, Google Docs, Slack) | Week 4 | Yes for action demo |
| Cortex Search index over policy docs | Week 2 — Document AI | Needed for policy RAG |
| Data Clean Room (actual DCR object) | Week 2 — requires multi-account or simulated | Simulated fallback exists |
| Dynamic tables / streams / tasks | Week 2 — near-real-time pipeline | Not blocking demo but needed for automation |
| Streamlit investigator app | Week 3 | Needed for demo surface |

---

## 5. Gaps & Risks

### 5.1 Data Quality Gaps

1. **Cross-bank transactions are sparse.** Only ~48 rows out of 8,747 are cross-bank
   (the planted ring overlay). The `shared_bad_actor_signal` view should still produce
   results because it joins on hashed identifiers (national_id, phone, device), not just
   transaction counterparties. However, the graph/typology engine needs to handle a very
   low signal-to-noise ratio.

2. **No near-CTR structuring in BANK_A or BANK_C.** The 10 structuring deposits are all
   at BANK_B (A0000343). The `structuring_candidates` view requires ≥6 events per
   account, so only this one account will be flagged. Consider adding structuring noise
   to other banks for a richer demo.

3. **Null counterparty_iban on cash deposits.** The 10 structuring rows have empty
   `counterparty_iban`. This is correct (cash has no counterparty IBAN) but means the
   clean-room `counterparty_iban` join won't link these. Detection must rely on the
   amount + channel + frequency pattern.

4. **All timestamps are September 2026.** The "last 7 days" validation question will
   only work if the current date context is set to late September 2026. Consider adding
   a date-offset parameter or using `DATEADD` relative to `MAX(ts)`.

### 5.2 Schema / Ontology Risks

5. **`control_gap` view vs ontology mismatch.** The ontology defines `control_gap` with
   `gap_id`, `control_id`, `obligation_id`, `typology_id`. The DDL view is keyed on
   `obligation_id` with no `gap_id` or `typology_id`. The `typology_exposure` view
   bridges this gap for now, but the ontology should be updated or the view renamed.

6. **`obligation.required_scope` and `control.status` are not in the ontology.** These
   are critical to the gap computation (a single-bank control cannot satisfy a cross-bank
   obligation). Update the ontology to include them.

7. **`typology` table is referenced in seeds but not created.** `typology_obligation`
   has RING-001 through RING-005, but there is no `typology` table with names and
   descriptions. This must be created before the typology engine can write results.

### 5.3 Execution Risks

8. **Semantic view syntax varies by Snowflake release.** The `03_semantic_views.sql`
   comments note this. DESCRIBE SEMANTIC VIEW should be run to confirm they compiled.

9. **Clean room is simulated.** The `02_clean_room.sql` uses views in a single account.
   The real DCR requires multi-account setup. The simulated fallback is fine for demo
   but should be noted.

10. **No Cortex Search index yet.** Policy documents from Google Drive have not been
    ingested. The regulatory twin is seeded manually from `twin_seed.json`. The
    Document AI → Cortex Search pipeline is a Week 2 deliverable.

---

## 6. Recommended Next Build Steps

### Phase 1: Schema completion (immediate)

1. **Create `typology` table** in GOVERNED schema with columns matching the ontology
   (`typology_id`, `name`, `description`, `structure`, `first_seen`, `banks_involved`).
   Seed with RING-001 through RING-005 metadata.

2. **Create `finding` and `finding_claim` tables** (DDL only, no data yet).

3. **Create `filing` table** (DDL only).

4. **Update `argus_ontology.yaml`** to add `required_scope` to obligation, `status` to
   control, and `bank_id` to typology_evidence. Add `control_obligation` and
   `typology_obligation` as bridge entities.

### Phase 2: Validate semantic views

5. **Run `03_semantic_views.sql` and `05_regulatory_twin.sql`** in a CoCo session with
   `sql_execute` enabled. Confirm with `DESCRIBE SEMANTIC VIEW`.

6. **Test validated questions** from the ontology against `argus_fraud_sv` using Cortex
   Analyst.

### Phase 3: Typology detection engine

7. **Build the graph/typology detection** over `shared_bad_actor_signal` +
   `cross_bank_flow_edges`. Populate `typology_evidence` with the accounts/identifiers
   that form each ring.

8. **Wire structuring detection** to produce findings from `structuring_candidates`.

### Phase 4: Evidence ledger + action loop

9. **Build the finding/finding_claim population** — each finding must link to both
   structured rows (transaction IDs) and regulation clauses.

10. **Connect MCP** (Jira for cases, Gmail/Google Docs for filings, Slack for alerts).

11. **Build Streamlit investigator** — ask in NL, see the ring, click evidence, file.

### Phase 5: Automation + testing

12. **Schedule unattended cross-bank scoring** via CoCo automation.
13. **Test planted-ring recall** against `data/ground_truth/planted_rings.json`.
14. **Package reusable skills** (`consortium-typology`, `grounded-finding`).
