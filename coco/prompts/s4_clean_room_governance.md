# CoCo session S4 — GOVERNANCE + CLEAN ROOM (single-account consortium simulation)

Project: **ARGUS** (team TCC). Database `ARGUS` holds synthetic data for three banks
(BANK_A / BANK_B / BANK_C) in `ARGUS.RAW`. `ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL`
(see `sql/02_clean_room.sql`) aggregates **hashed** identifiers seen at ≥2 banks.
Current user: TWILIGHTCLOUDCODERZ (ACCOUNTADMIN). Read `sql/01_raw_schema.sql` and
`sql/02_clean_room.sql` first.

A real Snowflake Data Clean Room needs one account per bank. We have one account, so
simulate the consortium faithfully with roles and policies. Requirements:

## Build (write ALL DDL to `sql/07_governance_clean_room.sql`, then run it)
1. **Roles**: `ARGUS_BANK_A`, `ARGUS_BANK_B`, `ARGUS_BANK_C` (each bank's own staff)
   and `ARGUS_ANALYST` (consortium compliance analyst). Grant all four to SYSADMIN and
   to user TWILIGHTCLOUDCODERZ. Grant USAGE on warehouse ARGUS_WH, database ARGUS and
   its schemas as needed.
2. **Row access policy** `ARGUS.GOVERNED.RAP_BANK_ISOLATION` on the `bank_id` column of
   RAW.CUSTOMERS, RAW.ACCOUNTS, RAW.TRANSACTIONS, RAW.DEVICE_LOGINS:
   - a bank role sees only its own bank's rows;
   - ACCOUNTADMIN and ARGUS_ANALYST see all rows;
   - owner's-rights objects (secure views owned by ACCOUNTADMIN) must still see all
     rows — use `INVOKER_ROLE()` / `IS_ROLE_IN_SESSION()` correctly so the clean-room
     aggregate works when queried by a bank role.
3. **PII classification + tag-based masking**:
   - Tag `ARGUS.GOVERNED.PII` (allowed values e.g. 'national_id','phone','name','email','dob').
   - Apply it to RAW.CUSTOMERS columns full_name, national_id, phone, email, dob.
   - A masking policy attached **to the tag** shows the real value only to ACCOUNTADMIN
     and to bank roles (row isolation already limits them to their own customers);
     everyone else (including ARGUS_ANALYST) sees `'***MASKED***'` (use a
     type-compatible mask for dob, e.g. NULL).
4. **Clean-room share**: recreate `ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL` as a
   **SECURE VIEW** (same columns/logic as now; it exposes only hashes, bank list and
   counts — never another bank's account IDs). Grant SELECT on it to the three bank roles
   and ARGUS_ANALYST. Bank roles get NO access to other GOVERNED/CURATED objects.
5. **Analyst access**: ARGUS_ANALYST gets SELECT on RAW tables (row policy lets it see
   all banks, masking hides PII), on CURATED and GOVERNED tables/views/dynamic tables
   (including LIVE_ALERTS, DT_*, DOCUMENTS, DOCUMENT_CHUNKS, EXTRACTED_OBLIGATIONS,
   PAST_FILINGS), on both semantic views `ARGUS_FRAUD_SV` and `ARGUS_REGTWIN_SV`, and
   USAGE on the Cortex Search service `ARGUS.GOVERNED.POLICY_SEARCH`. Use FUTURE grants
   in CURATED and GOVERNED so later objects are covered too.

## Verify (run each check with `USE SECONDARY ROLES NONE;` then `USE ROLE <role>;`)
Build a results table:
| role | customers rows visible | banks visible | national_id sample | shared signal rows |
- ARGUS_BANK_A → only BANK_A rows; real PII for its own customers; shared signal rows =
  same count as ACCOUNTADMIN sees (the cross-bank aggregate still works).
- ARGUS_BANK_A → `SELECT` on `ARGUS.GOVERNED.CONTROL_GAP` must FAIL (no access).
- ARGUS_ANALYST → all 3 banks, PII shows `***MASKED***`, semantic view query works:
  `SELECT * FROM SEMANTIC_VIEW(ARGUS.GOVERNED.ARGUS_FRAUD_SV DIMENSIONS banks.bank_name METRICS transactions.cross_bank_amount)`.
- ACCOUNTADMIN → unchanged: 540 customers, real PII.
Switch back to ACCOUNTADMIN at the end (`USE ROLE ACCOUNTADMIN; USE SECONDARY ROLES ALL;`).

Write objects, the verification table and an "Upgrade path to a real Snowflake Data
Clean Room" section (one provider account per bank) to `evidence/coco_s4_governance.md`.

Rules: do not drop tables or change data. Do not change the connection user's default
role or default secondary roles. Only create `sql/07_governance_clean_room.sql` and
`evidence/coco_s4_governance.md`.
