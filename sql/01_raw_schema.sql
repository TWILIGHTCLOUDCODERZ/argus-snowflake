/* ============================================================================
   ARGUS · Snowflake CoCo Hack (GCC Edition) · Created by TCC
   01_raw_schema.sql  —  RAW + CURATED schema + load the Week 1 synthetic data.

   Run through CoCo (CLI or Desktop). In each bank's real deployment, national_id
   and phone stay in a PRIVATE schema; only the *_hash columns are exposed to the
   Data Clean Room (see 02_clean_room.sql).
   ============================================================================ */

CREATE DATABASE IF NOT EXISTS ARGUS;
CREATE SCHEMA   IF NOT EXISTS ARGUS.RAW;
CREATE SCHEMA   IF NOT EXISTS ARGUS.CURATED;
CREATE SCHEMA   IF NOT EXISTS ARGUS.GOVERNED;

USE SCHEMA ARGUS.RAW;

-- ---------------------------------------------------------------------------
-- Tables (columns match data_generator output exactly)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE banks (
    bank_id STRING, bank_name STRING, country STRING, regulator STRING
);

CREATE OR REPLACE TABLE customers (
    customer_id STRING, bank_id STRING, full_name STRING,
    national_id STRING,            -- PRIVATE
    national_id_hash STRING,       -- shared via clean room
    phone STRING,                  -- PRIVATE
    phone_hash STRING,             -- shared via clean room
    email STRING, nationality STRING, dob DATE,
    kyc_risk_rating STRING, onboarded_at DATE
);

CREATE OR REPLACE TABLE accounts (
    account_id STRING, bank_id STRING, customer_id STRING, iban STRING,
    account_type STRING, currency STRING, status STRING, opened_at DATE
);

CREATE OR REPLACE TABLE device_logins (
    login_id STRING, bank_id STRING, account_id STRING,
    device_hash STRING, ip_hash STRING, ts TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE transactions (
    txn_id STRING, bank_id STRING, account_id STRING, direction STRING,
    amount NUMBER(18,2), currency STRING, channel STRING,
    counterparty_iban STRING, counterparty_bank STRING, purpose_code STRING,
    ts TIMESTAMP_NTZ
);

-- ---------------------------------------------------------------------------
-- Load from the stage created in 00_setup_warehouse.sql. Upload first:
--   snow stage copy data/*.csv @ARGUS.RAW.ARGUS_STAGE -c argus
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT argus_csv
    TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY='"' SKIP_HEADER=1 NULL_IF=('','NULL')
    EMPTY_FIELD_AS_NULL=TRUE;

COPY INTO banks         FROM @ARGUS_STAGE/banks.csv         FILE_FORMAT=argus_csv ON_ERROR=ABORT_STATEMENT;
COPY INTO customers     FROM @ARGUS_STAGE/customers.csv     FILE_FORMAT=argus_csv ON_ERROR=ABORT_STATEMENT;
COPY INTO accounts      FROM @ARGUS_STAGE/accounts.csv      FILE_FORMAT=argus_csv ON_ERROR=ABORT_STATEMENT;
COPY INTO device_logins FROM @ARGUS_STAGE/device_logins.csv FILE_FORMAT=argus_csv ON_ERROR=ABORT_STATEMENT;
COPY INTO transactions  FROM @ARGUS_STAGE/transactions.csv  FILE_FORMAT=argus_csv ON_ERROR=ABORT_STATEMENT;

-- ---------------------------------------------------------------------------
-- CURATED: account activity rollup (feeds semantic views in Week 2)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ARGUS.CURATED.account_activity AS
SELECT a.account_id, a.bank_id, a.iban, a.account_type, a.status, a.customer_id,
       c.kyc_risk_rating, c.national_id_hash, c.phone_hash,
       COUNT(t.txn_id)                                           AS txn_count,
       SUM(IFF(t.direction='credit', t.amount, 0))               AS total_credit,
       SUM(IFF(t.direction='debit',  t.amount, 0))               AS total_debit,
       SUM(IFF(t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C') , 1, 0)) AS cross_bank_txns,
       MIN(t.ts) AS first_txn_ts, MAX(t.ts) AS last_txn_ts
FROM ARGUS.RAW.accounts a
JOIN ARGUS.RAW.customers c ON c.customer_id = a.customer_id
LEFT JOIN ARGUS.RAW.transactions t ON t.account_id = a.account_id
GROUP BY 1,2,3,4,5,6,7,8,9;

-- Structuring candidates: many cash credits just under the CTR threshold
CREATE OR REPLACE VIEW ARGUS.CURATED.structuring_candidates AS
SELECT account_id, bank_id, COUNT(*) AS near_threshold_deposits,
       MIN(ts) AS window_start, MAX(ts) AS window_end, SUM(amount) AS total_amount
FROM ARGUS.RAW.transactions
WHERE channel='cash' AND direction='credit' AND amount BETWEEN 52000 AND 55000
GROUP BY 1,2
HAVING COUNT(*) >= 6;
