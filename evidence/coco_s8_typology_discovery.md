# ARGUS — CoCo Session S8: Typology Discovery Engine

*Created by TCC · CoCo Session S8*

## Objects Created / Modified

| Object | Type | Schema | Description |
|--------|------|--------|-------------|
| `TYPOLOGY` | Table | GOVERNED | Discovered typologies (TYP-0001...) with class, members, value, confidence, detection SQL, AI-generated card |
| `TYPOLOGY_EVIDENCE` | Table | GOVERNED | Per-account membership: typology_id, entity_id, role, bank_id (was empty; now filled) |
| `TYPOLOGY_CLASS` | Table | GOVERNED | 4 typology classes from twin_seed.json |
| `TYPOLOGY_CLASS_OBLIGATION` | Table | GOVERNED | Class → obligation mapping (replaces old RING-keyed `typology_obligation`) |
| `TYPOLOGY_EXPOSURE` | View | GOVERNED | Redefined: TYPOLOGY → class → obligation → CONTROL_GAP |
| `SP_DISCOVER_TYPOLOGIES()` | Procedure | GOVERNED | The graph expansion + community detection engine |
| `typology_obligation` | Table | GOVERNED | Truncated (answer-key IDs removed from governed data) |

## Algorithm

1. **Transfer edges**: all debit transactions where `counterparty_bank ∈ {BANK_A, BANK_B, BANK_C}`, including intra-bank (source mule → funnel within same bank) and inter-bank (funnel → consolidation). Amount ≥ 10,000 AED. Counterparty IBAN resolved to account_id via `RAW.ACCOUNTS.iban`. EXTERNAL counterparties excluded.

2. **Seeds**: hub accounts (DT_HUB_ACCOUNTS), structuring (DT_STRUCTURING), shared national_id at ≥2 banks, cross-bank edge participants (DT_CROSS_BANK_EDGES), open LIVE_ALERTS.

3. **BFS expansion** (2 hops): from each seed, follow transfer edges in both directions. Edges must fall within ±7 days of the seed's activity window.

4. **Identity expansion**: national_id links auto-join across banks. Device links join ONLY if the account also has a transfer edge to a community member (prevents household false positives).

5. **Connected components**: iterative label propagation in Snowflake Scripting (`WHILE` loop). Each node's label ← MIN of neighbor labels. Converges when no updates.

6. **Role assignment**:
   - `consolidation`: receives cross-bank credits from ≥2 other banks
   - `funnel`: receives same-bank AND sends cross-bank
   - `source_mule`: sends same-bank to funnel/consolidation only
   - `layering_hop`: member of a 3-node cross-bank cycle
   - `structuring`: in DT_STRUCTURING
   - `shared_identity`: linked by cross-bank national_id

7. **Classification**: FAN_IN_FAN_OUT_MULE, CIRCULAR_LAYERING, SHARED_IDENTITY, CASH_STRUCTURING.

8. **Outputs**: TYPOLOGY + TYPOLOGY_EVIDENCE. Detection SQL per typology. Plain-English card via `SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-5', ...)`.

## Discovery Scorecard

| Ring | Matched | Jaccard | Class | Recall | Precision |
|------|---------|---------|-------|--------|-----------|
| RING-001 | TYP-0003 | 1.00 | ✅ FAN_IN_FAN_OUT_MULE | 12/12 (100%) | 100% |
| RING-002 | TYP-0002 | 1.00 | ✅ SHARED_IDENTITY | 3/3 (100%) | 100% |
| RING-003 | TYP-0005 | 1.00 | ✅ CASH_STRUCTURING | 1/1 (100%) | 100% |
| RING-004 | TYP-0001 | 1.00 | ✅ CIRCULAR_LAYERING | 3/3 (100%) | 100% |
| RING-005 | TYP-0004 | 1.00 | ✅ FAN_IN_FAN_OUT_MULE | 12/12 (100%) | 100% |

**Source-mule recall**: RING-001 → 9/9 ✅ | RING-005 → 9/9 ✅ (target ≥ 8/9)

**BENIGN-001**: A0000004 NOT in any typology ✅

**Clean accounts in typologies**: 0 (target ≤ 1) ✅

## Example Typology Cards

### TYP-0003 — Cross-bank fan-in/fan-out mule network

A structured money mule network involving 12 accounts across three banks (BANK_A, BANK_B, BANK_C) moved AED 372,968.44 between September 15-20, 2026. Nine source mule accounts fed funds through two funnel accounts (A0000366 at BANK_B and A0000535 at BANK_C) into a single consolidation account (A0000095 at BANK_A). The rapid five-day operation and multi-bank layering structure indicate coordinated activity designed to obscure fund origins. This pattern is significant as it demonstrates organized use of money mules to aggregate illicit proceeds while exploiting multiple banking relationships to evade detection.

### TYP-0001 — Circular cross-bank layering

A circular layering scheme was detected involving three accounts moving funds in a loop across multiple banks (BANK_C, BANK_A, and BANK_B). All three accounts (A0000005, A0000400, and A0000552) functioned as layering hops, with funds cycling between them to obscure the origin of AED 373,081.23. The activity occurred over a 45-hour window between September 13, 2026 (16:00) and September 15, 2026 (13:00). This pattern matters because circular movements across multiple institutions are a classic money laundering technique designed to create complex audit trails and distance illicit funds from their criminal source.

## Live Feed Test

After delivering 12 batches via `SP_DELIVER_NEXT_BATCH()` and raising alerts:
- Discovery found **6 typologies** (5 baseline + RING-006)
- RING-006 matched with Jaccard 1.00, 9/9 source mules found ✅
- Demo reset to 5 typologies ✅

## Validator Results

- `validate_discovery.py` — **OVERALL PASS** (5/5 rings, 9/9 mules × 2, BENIGN excluded, 0 clean, RING-006 live)
- `validate_week2.py --backend snowflake` — **6/6 pass** (unchanged from Week 2)
- `validate_analyst.py` — **Set A: 6/6 (100%) | Set B: 10/12 (83%)** — both targets met (A ≥ 5/6, B ≥ 80%)
