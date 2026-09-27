/* ============================================================================
   ARGUS · 06_pipelines.sql — Stream + Task Graph + Dynamic Tables
   Created by TCC · CoCo Session S3

   Near-real-time fraud detection pipeline. Micro-batches from TXN_LIVE_QUEUE
   are fed into TRANSACTIONS via a serverless task graph; a child task reads
   the append-only stream and raises LIVE_ALERTS using Q1 (cross-bank hub)
   and Q4 (structuring) detection logic. Three dynamic tables materialise
   the same patterns for dashboard consumption.
   ============================================================================ */

USE DATABASE ARGUS;

-- =========================================================================
-- 1. TXN_LIVE_QUEUE — staging table for micro-batches
-- =========================================================================
CREATE OR REPLACE TABLE ARGUS.RAW.TXN_LIVE_QUEUE (
    feed_seq          NUMBER,
    batch_no          NUMBER,
    txn_id            STRING,
    bank_id           STRING,
    account_id        STRING,
    direction         STRING,
    amount            NUMBER(18,2),
    currency          STRING,
    channel           STRING,
    counterparty_iban STRING,
    counterparty_bank STRING,
    purpose_code      STRING,
    delivered_at      TIMESTAMP_NTZ
);

COPY INTO ARGUS.RAW.TXN_LIVE_QUEUE
    (feed_seq, batch_no, txn_id, bank_id, account_id, direction,
     amount, currency, channel, counterparty_iban, counterparty_bank, purpose_code)
FROM @ARGUS.RAW.ARGUS_STAGE/live_feed.csv
FILE_FORMAT = ARGUS.RAW.ARGUS_CSV
ON_ERROR = ABORT_STATEMENT;

-- =========================================================================
-- 2. STREAM — append-only on TRANSACTIONS
-- =========================================================================
CREATE OR REPLACE STREAM ARGUS.RAW.TRANSACTIONS_STREAM
    ON TABLE ARGUS.RAW.TRANSACTIONS
    APPEND_ONLY = TRUE;

-- =========================================================================
-- 3. SP_DELIVER_NEXT_BATCH — inserts lowest undelivered batch
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.RAW.SP_DELIVER_NEXT_BATCH()
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    LET v_batch NUMBER := (SELECT MIN(batch_no) FROM ARGUS.RAW.TXN_LIVE_QUEUE
                           WHERE delivered_at IS NULL);

    IF (:v_batch IS NULL) THEN
        RETURN 'Queue empty — no batches to deliver';
    END IF;

    INSERT INTO ARGUS.RAW.TRANSACTIONS
        (txn_id, bank_id, account_id, direction, amount, currency,
         channel, counterparty_iban, counterparty_bank, purpose_code, ts)
    SELECT txn_id, bank_id, account_id, direction, amount, currency,
           channel, counterparty_iban, counterparty_bank, purpose_code,
           CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    FROM ARGUS.RAW.TXN_LIVE_QUEUE
    WHERE batch_no = :v_batch AND delivered_at IS NULL;

    UPDATE ARGUS.RAW.TXN_LIVE_QUEUE
       SET delivered_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
     WHERE batch_no = :v_batch;

    RETURN 'Delivered batch ' || :v_batch::STRING;
END;

-- =========================================================================
-- 4. LIVE_ALERTS table
-- =========================================================================
CREATE OR REPLACE TABLE ARGUS.GOVERNED.LIVE_ALERTS (
    alert_id          NUMBER IDENTITY,
    alert_type        STRING,
    account_id        STRING,
    bank_id           STRING,
    source_banks      NUMBER,
    inbound_amount    NUMBER(18,2),
    near_ctr_deposits NUMBER,
    first_seen        TIMESTAMP_NTZ,
    last_seen         TIMESTAMP_NTZ,
    raised_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    status            STRING DEFAULT 'OPEN'
);

-- =========================================================================
-- 5a. SP_RAISE_ALERTS — evaluates stream rows against Q1/Q4 patterns
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_RAISE_ALERTS()
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    -- Consume the stream so the offset advances
    CREATE OR REPLACE TEMPORARY TABLE _stream_batch AS
    SELECT * FROM ARGUS.RAW.TRANSACTIONS_STREAM;

    -- CROSS_BANK_HUB: credits from >=2 distinct OTHER consortium banks within 7 days
    INSERT INTO ARGUS.GOVERNED.LIVE_ALERTS
        (alert_type, account_id, bank_id, source_banks,
         inbound_amount, near_ctr_deposits, first_seen, last_seen)
    SELECT 'CROSS_BANK_HUB', h.account_id, h.bank_id, h.source_banks,
           h.inbound_amount, NULL, h.burst_start, h.burst_end
    FROM (
        SELECT t.account_id, t.bank_id,
               COUNT(DISTINCT t.counterparty_bank) AS source_banks,
               SUM(t.amount)                       AS inbound_amount,
               MIN(t.ts)                           AS burst_start,
               MAX(t.ts)                           AS burst_end
        FROM ARGUS.RAW.TRANSACTIONS t
        WHERE t.direction = 'credit'
          AND t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
          AND t.counterparty_bank <> t.bank_id
          AND t.account_id IN (
              SELECT DISTINCT account_id
              FROM _stream_batch
              WHERE direction = 'credit'
          )
        GROUP BY t.account_id, t.bank_id
        HAVING COUNT(DISTINCT t.counterparty_bank) >= 2
           AND DATEDIFF('day', MIN(t.ts), MAX(t.ts)) <= 7
    ) h
    WHERE NOT EXISTS (
        SELECT 1 FROM ARGUS.GOVERNED.LIVE_ALERTS la
        WHERE la.account_id = h.account_id
          AND la.alert_type = 'CROSS_BANK_HUB'
          AND la.status = 'OPEN'
    );

    -- STRUCTURING: >=6 cash credits 52000-55000 AED within 7 days
    INSERT INTO ARGUS.GOVERNED.LIVE_ALERTS
        (alert_type, account_id, bank_id, source_banks,
         inbound_amount, near_ctr_deposits, first_seen, last_seen)
    SELECT 'STRUCTURING', s.account_id, s.bank_id, NULL,
           s.total_amount, s.near_threshold_deposits,
           s.first_deposit, s.last_deposit
    FROM (
        SELECT account_id, bank_id,
               COUNT(*)    AS near_threshold_deposits,
               SUM(amount) AS total_amount,
               MIN(ts)     AS first_deposit,
               MAX(ts)     AS last_deposit
        FROM ARGUS.RAW.TRANSACTIONS
        WHERE channel = 'cash' AND direction = 'credit'
          AND amount BETWEEN 52000 AND 55000
          AND account_id IN (
              SELECT DISTINCT account_id
              FROM _stream_batch
              WHERE direction = 'credit'
          )
        GROUP BY account_id, bank_id
        HAVING COUNT(*) >= 6
           AND DATEDIFF('day', MIN(ts), MAX(ts)) <= 7
    ) s
    WHERE NOT EXISTS (
        SELECT 1 FROM ARGUS.GOVERNED.LIVE_ALERTS la
        WHERE la.account_id = s.account_id
          AND la.alert_type = 'STRUCTURING'
          AND la.status = 'OPEN'
    );

    DROP TABLE IF EXISTS _stream_batch;
    RETURN 'Alert evaluation complete';
END;

-- =========================================================================
-- 5b. TASK GRAPH — serverless
-- =========================================================================
CREATE OR REPLACE TASK ARGUS.RAW.TASK_FEED_LIVE
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = '1 MINUTE'
AS
    CALL ARGUS.RAW.SP_DELIVER_NEXT_BATCH();

-- NOTE: child task placed in RAW (Snowflake requires task graph members in one schema)
CREATE OR REPLACE TASK ARGUS.RAW.TASK_RAISE_ALERTS
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    AFTER ARGUS.RAW.TASK_FEED_LIVE
    WHEN SYSTEM$STREAM_HAS_DATA('ARGUS.RAW.TRANSACTIONS_STREAM')
AS
    CALL ARGUS.GOVERNED.SP_RAISE_ALERTS();

-- Cost safety: root stays SUSPENDED; resume only the child
ALTER TASK ARGUS.RAW.TASK_RAISE_ALERTS RESUME;

-- =========================================================================
-- 6. DYNAMIC TABLES (deterministic SQL, no CURRENT_TIMESTAMP)
-- =========================================================================

-- Inter-bank debit edges, resolving counterparty IBAN → account
CREATE OR REPLACE DYNAMIC TABLE ARGUS.CURATED.DT_CROSS_BANK_EDGES
    WAREHOUSE = ARGUS_WH
    TARGET_LAG = '1 minute'
AS
SELECT t.bank_id      AS from_bank,
       t.account_id   AS from_account,
       t.counterparty_bank AS to_bank,
       a.account_id   AS to_account,
       t.txn_id,
       t.amount,
       t.ts
FROM ARGUS.RAW.TRANSACTIONS t
JOIN ARGUS.RAW.ACCOUNTS a
  ON a.iban = t.counterparty_iban
WHERE t.direction = 'debit'
  AND t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
  AND t.counterparty_bank <> t.bank_id;

-- Q1 logic: accounts receiving cross-bank credits from >=2 other banks within 7 days
CREATE OR REPLACE DYNAMIC TABLE ARGUS.CURATED.DT_HUB_ACCOUNTS
    WAREHOUSE = ARGUS_WH
    TARGET_LAG = '1 minute'
AS
SELECT t.account_id,
       t.bank_id,
       COUNT(DISTINCT t.counterparty_bank) AS source_banks,
       COUNT(*)                            AS inbound_transfers,
       SUM(t.amount)                       AS inbound_amount,
       MIN(t.ts)                           AS burst_start,
       MAX(t.ts)                           AS burst_end
FROM ARGUS.RAW.TRANSACTIONS t
WHERE t.direction = 'credit'
  AND t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
  AND t.counterparty_bank <> t.bank_id
GROUP BY t.account_id, t.bank_id
HAVING COUNT(DISTINCT t.counterparty_bank) >= 2
   AND DATEDIFF('day', MIN(t.ts), MAX(t.ts)) <= 7;

-- Q4 logic: cash deposits just under CTR threshold (structuring / smurfing)
CREATE OR REPLACE DYNAMIC TABLE ARGUS.CURATED.DT_STRUCTURING
    WAREHOUSE = ARGUS_WH
    TARGET_LAG = '1 minute'
AS
SELECT account_id,
       bank_id,
       COUNT(*)    AS near_threshold_deposits,
       SUM(amount) AS total_amount,
       MIN(ts)     AS first_deposit,
       MAX(ts)     AS last_deposit
FROM ARGUS.RAW.TRANSACTIONS
WHERE channel = 'cash' AND direction = 'credit'
  AND amount BETWEEN 52000 AND 55000
GROUP BY account_id, bank_id
HAVING COUNT(*) >= 6
   AND DATEDIFF('day', MIN(ts), MAX(ts)) <= 7;

-- =========================================================================
-- 7. SP_RESET_LIVE_DEMO — clean slate for replay
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.RAW.SP_RESET_LIVE_DEMO()
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    -- Remove delivered live rows from TRANSACTIONS
    DELETE FROM ARGUS.RAW.TRANSACTIONS WHERE txn_id LIKE 'LV%';
    -- Clear delivery markers so batches can be replayed
    UPDATE ARGUS.RAW.TXN_LIVE_QUEUE SET delivered_at = NULL;
    -- Clear all alerts
    TRUNCATE TABLE ARGUS.GOVERNED.LIVE_ALERTS;
    -- Recreate stream so offset resets
    CREATE OR REPLACE STREAM ARGUS.RAW.TRANSACTIONS_STREAM
        ON TABLE ARGUS.RAW.TRANSACTIONS APPEND_ONLY = TRUE;
    RETURN 'Demo reset complete';
END;
