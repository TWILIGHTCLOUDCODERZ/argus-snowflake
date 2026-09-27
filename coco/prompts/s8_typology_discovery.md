# CoCo session S8 — TYPOLOGY DISCOVERY ENGINE (graph expansion → typologies → cards)

Project: **ARGUS** (team TCC). Read `docs/WEEK3_PLAN.md` first. Signals already exist in
Snowflake: `ARGUS.CURATED.DT_HUB_ACCOUNTS`, `DT_STRUCTURING`, `DT_CROSS_BANK_EDGES`,
`ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL`, `BANK_IDENTIFIER_EXPOSURE` (hashes only),
`LIVE_ALERTS`. Transactions: `ARGUS.RAW.TRANSACTIONS`; accounts: `ARGUS.RAW.ACCOUNTS`.
`ARGUS.GOVERNED.TYPOLOGY_EVIDENCE` is empty and must now be filled BY THE ENGINE.

**Known limitation to fix:** per-account rules catch hub accounts but 0/9 of a mule ring's
source mules (they only move money inside their own bank). Discovery must reach them by
expanding the graph outward from the seeds.

## Build (all SQL in `sql/10_typology_discovery.sql`; Snowflake Scripting / SQL only —
no third-party packages; if anything requires accepting terms, stop and report)

1. **Graph edges**
   - *Transfer edges*: debit transactions whose `counterparty_bank` is a consortium bank
     (BANK_A/B/C — intra- OR inter-bank). Resolve `counterparty_iban` → receiving
     `account_id` via `RAW.ACCOUNTS.iban`. Never resolve IBANs when counterparty_bank is
     `EXTERNAL` (external IBANs can collide with internal numbering).
   - *Identity edges*: accounts sharing a `national_id` or `device` hash
     (`BANK_IDENTIFIER_EXPOSURE`), across banks.
2. **Seeds**: hub accounts, structuring accounts, accounts linked by a shared national-ID
   hash at ≥2 banks, open `LIVE_ALERTS`.
3. **Expansion** (procedure `ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES()`): from each seed,
   follow transfer edges up to 2 hops in either direction, keeping only edges that fall
   within 7 days of the seed's activity window and are ≥ 10,000 AED. Identity rules:
   a shared **national-ID** link joins the community; a **device-only** link is weak and
   joins only if the account is also connected by a transfer edge or another signal
   (a household sharing a tablet must NOT become a typology).
4. **Communities**: connected components over the kept edges (iterative label
   propagation in Snowflake Scripting). Each component = one discovered typology.
5. **Roles + class** from structure: `consolidation` (inbound from ≥2 other banks),
   `funnel` (inbound from same-bank accounts, outbound cross-bank), `source_mule`
   (outbound into a funnel only), `layering_hop` (member of a cross-bank cycle),
   `shared_identity`, `structuring`. Class ∈ `FAN_IN_FAN_OUT_MULE`, `SHARED_IDENTITY`,
   `CASH_STRUCTURING`, `CIRCULAR_LAYERING` (see `typology_classes` in `data/twin_seed.json`).
6. **Outputs** (the procedure replaces previous DISCOVERED rows on each run):
   - `ARGUS.GOVERNED.TYPOLOGY` (typology_id like `TYP-0001`, typology_class, name,
     banks_involved, member_count, first_seen, last_seen, total_value, confidence,
     detection_sql, card_md, status 'DISCOVERED', discovered_at).
   - `ARGUS.GOVERNED.TYPOLOGY_EVIDENCE` (typology_id, entity_type, entity_id, role, bank_id).
   - **Typology card**: `AI_COMPLETE('claude-sonnet-4-5', ...)` writes a short
     plain-English card (what happened, who is involved by role, value, time window, why
     it matters) from the computed facts ONLY — pass the facts as JSON, forbid invention.
   - **Detection query**: a stored, re-runnable SQL (`detection_sql`) that re-detects
     this typology's pattern; execute each one and confirm it returns the members.
7. **Class-based twin mapping** (design correction, see WEEK3_PLAN): upload
   `data/twin_seed.json` again (`.venv/Scripts/snow stage copy data/twin_seed.json
   @ARGUS.RAW.ARGUS_STAGE -c argus --overwrite`), create `ARGUS.GOVERNED.TYPOLOGY_CLASS`
   and `TYPOLOGY_CLASS_OBLIGATION` from its `typology_classes` / `typology_class_obligation`,
   and redefine `ARGUS.GOVERNED.TYPOLOGY_EXPOSURE` as discovered TYPOLOGY → class →
   obligation → CONTROL_GAP (same output columns as today). Empty the old RING-keyed
   `TYPOLOGY_OBLIGATION` table (answer-key IDs must not live in governed data). Update
   `sql/05_regulatory_twin.sql` so a rebuild creates the class tables instead.
8. **Validators**: update `validation/validate_week2.py` (Snowflake backend) and
   `validation/validate_analyst.py` so Q5/Q6 first resolve the planted ring to the
   discovered typology with the highest member overlap (Jaccard) and then query that
   `typology_id`. Remove the TEMPORARY `TYPOLOGY_EVIDENCE` stand-ins when the real table
   has rows (they would hide the engine's output). The sqlite backend stays as is.

## Evaluate against the answer key (`data/ground_truth/planted_rings.json`, read-only)
Write `validation/validate_discovery.py` + `validation/discovery_report.md`:
- per planted ring: matched typology, class correct?, member recall and precision,
  **source-mule recall for RING-001 and RING-005** (target ≥ 8/9 each);
- BENIGN-001 must not be in any typology;
- clean accounts inside typologies (target ≤ 1 overall);
- **live test**: `CALL ARGUS.RAW.SP_DELIVER_NEXT_BATCH()` 12 times, `CALL
  ARGUS.RAW.SP_RAISE_ALERTS()`, refresh the dynamic tables, run discovery, check RING-006
  (`live_typologies`) is found with its source mules; then `CALL
  ARGUS.RAW.SP_RESET_LIVE_DEMO()` and re-run discovery to restore the baseline.
Then run `validate_week2.py --backend snowflake` (must stay 6/6) and
`validate_analyst.py` (report the numbers honestly).

Write `evidence/coco_s8_typology_discovery.md`: objects, algorithm, the discovery
scorecard, two example typology cards, and the live-feed result.

Grants: new tables/views in GOVERNED are covered by future grants; if you CREATE OR
REPLACE any existing object, re-grant SELECT to ARGUS_ANALYST. Any role-based check
must first run `USE SECONDARY ROLES NONE;` (otherwise admin privileges leak in and the
check is a false pass); restore `USE SECONDARY ROLES ALL;` afterwards.

Rules: never write answer-key data into governed tables. Do not drop RAW/CURATED
objects or change warehouse size. Leave `ARGUS.RAW.TASK_FEED_LIVE` suspended.
