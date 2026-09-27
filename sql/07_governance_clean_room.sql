/* ============================================================================
   ARGUS · 07_governance_clean_room.sql — Role-based governance + clean-room
   simulation for a single-account consortium.
   Created by TCC · CoCo Session S4

   Simulates three banks (BANK_A/B/C) as custom roles in one Snowflake account.
   Row access policy isolates each bank to its own data; tag-based masking hides
   PII from the consortium analyst; a SECURE VIEW lets the cross-bank aggregate
   (shared_bad_actor_signal) work even when queried by a bank role.

   Key trick: INVOKER_ROLE() inside a SECURE VIEW returns the view OWNER's role
   (ACCOUNTADMIN), so the RAP allows all rows for the aggregate. Direct table
   access by a bank role returns only that bank's rows.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;

-- =========================================================================
-- 1. ROLES
-- =========================================================================
CREATE ROLE IF NOT EXISTS ARGUS_BANK_A COMMENT = 'ARGUS consortium — Bank A staff';
CREATE ROLE IF NOT EXISTS ARGUS_BANK_B COMMENT = 'ARGUS consortium — Bank B staff';
CREATE ROLE IF NOT EXISTS ARGUS_BANK_C COMMENT = 'ARGUS consortium — Bank C staff';
CREATE ROLE IF NOT EXISTS ARGUS_ANALYST COMMENT = 'ARGUS consortium compliance analyst';

-- Grant to SYSADMIN (role hierarchy) and to the current user
GRANT ROLE ARGUS_BANK_A  TO ROLE SYSADMIN;
GRANT ROLE ARGUS_BANK_B  TO ROLE SYSADMIN;
GRANT ROLE ARGUS_BANK_C  TO ROLE SYSADMIN;
GRANT ROLE ARGUS_ANALYST TO ROLE SYSADMIN;

GRANT ROLE ARGUS_BANK_A  TO USER TWILIGHTCLOUDCODERZ;
GRANT ROLE ARGUS_BANK_B  TO USER TWILIGHTCLOUDCODERZ;
GRANT ROLE ARGUS_BANK_C  TO USER TWILIGHTCLOUDCODERZ;
GRANT ROLE ARGUS_ANALYST TO USER TWILIGHTCLOUDCODERZ;

-- =========================================================================
-- 2. WAREHOUSE / DATABASE / SCHEMA USAGE
-- =========================================================================
GRANT USAGE ON WAREHOUSE ARGUS_WH TO ROLE ARGUS_BANK_A;
GRANT USAGE ON WAREHOUSE ARGUS_WH TO ROLE ARGUS_BANK_B;
GRANT USAGE ON WAREHOUSE ARGUS_WH TO ROLE ARGUS_BANK_C;
GRANT USAGE ON WAREHOUSE ARGUS_WH TO ROLE ARGUS_ANALYST;

GRANT USAGE ON DATABASE ARGUS TO ROLE ARGUS_BANK_A;
GRANT USAGE ON DATABASE ARGUS TO ROLE ARGUS_BANK_B;
GRANT USAGE ON DATABASE ARGUS TO ROLE ARGUS_BANK_C;
GRANT USAGE ON DATABASE ARGUS TO ROLE ARGUS_ANALYST;

-- Bank roles: RAW (their own data) + GOVERNED (shared signal only)
GRANT USAGE ON SCHEMA ARGUS.RAW      TO ROLE ARGUS_BANK_A;
GRANT USAGE ON SCHEMA ARGUS.RAW      TO ROLE ARGUS_BANK_B;
GRANT USAGE ON SCHEMA ARGUS.RAW      TO ROLE ARGUS_BANK_C;
GRANT USAGE ON SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_BANK_A;
GRANT USAGE ON SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_BANK_B;
GRANT USAGE ON SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_BANK_C;

-- Analyst: all three schemas
GRANT USAGE ON SCHEMA ARGUS.RAW      TO ROLE ARGUS_ANALYST;
GRANT USAGE ON SCHEMA ARGUS.CURATED  TO ROLE ARGUS_ANALYST;
GRANT USAGE ON SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_ANALYST;

-- =========================================================================
-- 3. ROW ACCESS POLICY — bank isolation on the bank_id column
-- =========================================================================
USE SCHEMA ARGUS.GOVERNED;

CREATE OR REPLACE ROW ACCESS POLICY RAP_BANK_ISOLATION
AS (bank_id STRING) RETURNS BOOLEAN ->
  CASE
    -- Owner's-rights context (secure views owned by ACCOUNTADMIN):
    -- INVOKER_ROLE() returns the view owner, letting the cross-bank
    -- aggregate see all rows even when a bank role invokes the query.
    WHEN INVOKER_ROLE() IN ('ACCOUNTADMIN') THEN TRUE
    -- Consortium analyst sees all banks (PII masked separately)
    WHEN IS_ROLE_IN_SESSION('ARGUS_ANALYST') THEN TRUE
    -- Each bank sees only its own rows
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_A') AND bank_id = 'BANK_A' THEN TRUE
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_B') AND bank_id = 'BANK_B' THEN TRUE
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_C') AND bank_id = 'BANK_C' THEN TRUE
    ELSE FALSE
  END;

ALTER TABLE ARGUS.RAW.CUSTOMERS     ADD ROW ACCESS POLICY ARGUS.GOVERNED.RAP_BANK_ISOLATION ON (bank_id);
ALTER TABLE ARGUS.RAW.ACCOUNTS      ADD ROW ACCESS POLICY ARGUS.GOVERNED.RAP_BANK_ISOLATION ON (bank_id);
ALTER TABLE ARGUS.RAW.TRANSACTIONS  ADD ROW ACCESS POLICY ARGUS.GOVERNED.RAP_BANK_ISOLATION ON (bank_id);
ALTER TABLE ARGUS.RAW.DEVICE_LOGINS ADD ROW ACCESS POLICY ARGUS.GOVERNED.RAP_BANK_ISOLATION ON (bank_id);

-- =========================================================================
-- 4. PII CLASSIFICATION TAG + TAG-BASED MASKING
-- =========================================================================
CREATE OR REPLACE TAG ARGUS.GOVERNED.PII
    ALLOWED_VALUES 'national_id', 'phone', 'name', 'email', 'dob'
    COMMENT = 'Personally Identifiable Information classification';

-- STRING masking: real value for ACCOUNTADMIN + bank roles; masked for everyone else
CREATE OR REPLACE MASKING POLICY ARGUS.GOVERNED.MASK_PII_STRING
AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_A')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_B')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_C')  THEN val
    ELSE '***MASKED***'
  END;

-- DATE masking: NULL for non-privileged roles (type-compatible)
CREATE OR REPLACE MASKING POLICY ARGUS.GOVERNED.MASK_PII_DATE
AS (val DATE) RETURNS DATE ->
  CASE
    WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_A')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_B')  THEN val
    WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_C')  THEN val
    ELSE NULL
  END;

-- Attach masking policies to the tag (one per data type)
ALTER TAG ARGUS.GOVERNED.PII SET MASKING POLICY ARGUS.GOVERNED.MASK_PII_STRING FORCE;
ALTER TAG ARGUS.GOVERNED.PII SET MASKING POLICY ARGUS.GOVERNED.MASK_PII_DATE   FORCE;

-- Classify PII columns
ALTER TABLE ARGUS.RAW.CUSTOMERS ALTER COLUMN full_name   SET TAG ARGUS.GOVERNED.PII = 'name';
ALTER TABLE ARGUS.RAW.CUSTOMERS ALTER COLUMN national_id SET TAG ARGUS.GOVERNED.PII = 'national_id';
ALTER TABLE ARGUS.RAW.CUSTOMERS ALTER COLUMN phone       SET TAG ARGUS.GOVERNED.PII = 'phone';
ALTER TABLE ARGUS.RAW.CUSTOMERS ALTER COLUMN email       SET TAG ARGUS.GOVERNED.PII = 'email';
ALTER TABLE ARGUS.RAW.CUSTOMERS ALTER COLUMN dob         SET TAG ARGUS.GOVERNED.PII = 'dob';

-- =========================================================================
-- 5. SHARED_BAD_ACTOR_SIGNAL — recreate as SECURE VIEW
-- =========================================================================
CREATE OR REPLACE SECURE VIEW ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL AS
SELECT identifier_hash, identifier_type,
       COUNT(DISTINCT bank_id)              AS contributing_bank_count,
       ARRAY_AGG(DISTINCT bank_id)          AS banks,
       COUNT(DISTINCT account_id)           AS linked_accounts,
       CASE identifier_type
            WHEN 'national_id' THEN 1.0 WHEN 'device' THEN 0.9
            WHEN 'counterparty_iban' THEN 0.8 ELSE 0.6 END
       * (COUNT(DISTINCT bank_id) - 1)      AS risk_weight
FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE
WHERE identifier_hash IS NOT NULL AND identifier_hash <> ''
GROUP BY identifier_hash, identifier_type
HAVING COUNT(DISTINCT bank_id) > 1;

-- =========================================================================
-- 6. BANK ROLE GRANTS — RAW tables + shared signal only
-- =========================================================================
-- Banks can query their own data in RAW (RAP restricts to their bank)
GRANT SELECT ON TABLE ARGUS.RAW.BANKS          TO ROLE ARGUS_BANK_A;
GRANT SELECT ON TABLE ARGUS.RAW.CUSTOMERS      TO ROLE ARGUS_BANK_A;
GRANT SELECT ON TABLE ARGUS.RAW.ACCOUNTS       TO ROLE ARGUS_BANK_A;
GRANT SELECT ON TABLE ARGUS.RAW.TRANSACTIONS   TO ROLE ARGUS_BANK_A;
GRANT SELECT ON TABLE ARGUS.RAW.DEVICE_LOGINS  TO ROLE ARGUS_BANK_A;

GRANT SELECT ON TABLE ARGUS.RAW.BANKS          TO ROLE ARGUS_BANK_B;
GRANT SELECT ON TABLE ARGUS.RAW.CUSTOMERS      TO ROLE ARGUS_BANK_B;
GRANT SELECT ON TABLE ARGUS.RAW.ACCOUNTS       TO ROLE ARGUS_BANK_B;
GRANT SELECT ON TABLE ARGUS.RAW.TRANSACTIONS   TO ROLE ARGUS_BANK_B;
GRANT SELECT ON TABLE ARGUS.RAW.DEVICE_LOGINS  TO ROLE ARGUS_BANK_B;

GRANT SELECT ON TABLE ARGUS.RAW.BANKS          TO ROLE ARGUS_BANK_C;
GRANT SELECT ON TABLE ARGUS.RAW.CUSTOMERS      TO ROLE ARGUS_BANK_C;
GRANT SELECT ON TABLE ARGUS.RAW.ACCOUNTS       TO ROLE ARGUS_BANK_C;
GRANT SELECT ON TABLE ARGUS.RAW.TRANSACTIONS   TO ROLE ARGUS_BANK_C;
GRANT SELECT ON TABLE ARGUS.RAW.DEVICE_LOGINS  TO ROLE ARGUS_BANK_C;

-- Clean-room shared signal — the ONLY governed object bank roles can see
GRANT SELECT ON VIEW ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL TO ROLE ARGUS_BANK_A;
GRANT SELECT ON VIEW ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL TO ROLE ARGUS_BANK_B;
GRANT SELECT ON VIEW ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL TO ROLE ARGUS_BANK_C;

-- =========================================================================
-- 7. ANALYST GRANTS — full read across RAW/CURATED/GOVERNED, PII masked
-- =========================================================================
-- RAW tables (row policy lets analyst see all banks; masking hides PII)
GRANT SELECT ON ALL TABLES IN SCHEMA ARGUS.RAW TO ROLE ARGUS_ANALYST;

-- CURATED: views + dynamic tables (current objects)
GRANT SELECT ON ALL TABLES IN SCHEMA ARGUS.CURATED TO ROLE ARGUS_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ARGUS.CURATED TO ROLE ARGUS_ANALYST;

-- GOVERNED: tables + views (current objects)
GRANT SELECT ON ALL TABLES IN SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_ANALYST;

-- Semantic views (separate object type, not covered by ALL VIEWS)
GRANT SELECT ON SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_FRAUD_SV    TO ROLE ARGUS_ANALYST;
GRANT SELECT ON SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_REGTWIN_SV  TO ROLE ARGUS_ANALYST;

-- Cortex Search service
GRANT USAGE ON CORTEX SEARCH SERVICE ARGUS.GOVERNED.POLICY_SEARCH TO ROLE ARGUS_ANALYST;

-- FUTURE grants so later objects are covered automatically
GRANT SELECT ON FUTURE TABLES IN SCHEMA ARGUS.CURATED  TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA ARGUS.CURATED  TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA ARGUS.GOVERNED  TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA ARGUS.GOVERNED  TO ROLE ARGUS_ANALYST;

-- ---------------------------------------------------------------------------
-- Added after review: semantic views and dynamic tables are separate object types,
-- not covered by the TABLE/VIEW future grants above. Without these, recreating a
-- semantic view silently removed the analyst's access.
-- ---------------------------------------------------------------------------
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_ANALYST;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA ARGUS.CURATED TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA ARGUS.CURATED TO ROLE ARGUS_ANALYST;
