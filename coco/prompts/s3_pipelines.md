# CoCo session S3 — DATA PIPELINES: stream + task graph + dynamic tables (near real time)

Project: **ARGUS** (team TCC). Snowflake database `ARGUS` (schemas RAW, CURATED,
GOVERNED) is loaded; warehouse `ARGUS_WH` (X-Small, auto-suspend 60s). Read
`sql/01_raw_schema.sql`, `sql/02_clean_room.sql` and `semantic/verified_queries.yaml`
(Q1 = cross-bank hub accounts, Q4 = structuring) first — reuse their detection logic.

`data/live_feed.csv` holds 12 micro-batches of future transactions (columns:
feed_seq, batch_no, txn_id, bank_id, account_id, direction, amount, currency, channel,
counterparty_iban, counterparty_bank, purpose_code — no timestamp). A fraud ring forms
across batches 3–10.

## Build (write ALL DDL to `sql/06_pipelines.sql`, then run it)

1. **Upload + queue.** Upload the file with bash:
   `.venv/Scripts/snow stage copy data/live_feed.csv @ARGUS.RAW.ARGUS_STAGE -c argus --overwrite`
   Create `ARGUS.RAW.TXN_LIVE_QUEUE` (the CSV columns + `delivered_at TIMESTAMP_NTZ`)
   and COPY the file in (reuse file format `ARGUS.RAW.ARGUS_CSV`).
2. **Stream.** `ARGUS.RAW.TRANSACTIONS_STREAM` — append-only stream on `ARGUS.RAW.TRANSACTIONS`.
3. **Delivery procedure.** `ARGUS.RAW.SP_DELIVER_NEXT_BATCH()` inserts the lowest
   undelivered `batch_no` from the queue into `ARGUS.RAW.TRANSACTIONS` with
   `ts = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ`, marks those queue rows delivered, and
   returns the batch number delivered (or a message when the queue is empty).
4. **Alerts table.** `ARGUS.GOVERNED.LIVE_ALERTS` (alert_id IDENTITY, alert_type,
   account_id, bank_id, source_banks, inbound_amount, near_ctr_deposits, first_seen,
   last_seen, raised_at DEFAULT CURRENT_TIMESTAMP, status DEFAULT 'OPEN').
5. **Task graph — serverless** (`USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'`):
   - Root `ARGUS.RAW.TASK_FEED_LIVE`, `SCHEDULE = '1 MINUTE'`, calls the delivery procedure.
   - Child `ARGUS.GOVERNED.TASK_RAISE_ALERTS`, `AFTER ARGUS.RAW.TASK_FEED_LIVE`,
     `WHEN SYSTEM$STREAM_HAS_DATA('ARGUS.RAW.TRANSACTIONS_STREAM')`. Its DML must read
     the stream (so the offset advances). For each account that received a credit in the
     new stream rows, evaluate over `ARGUS.RAW.TRANSACTIONS`:
     * `CROSS_BANK_HUB`: credits from ≥2 distinct OTHER consortium banks
       (BANK_A/B/C, ≠ the account's bank) within a 7-day span (Q1 logic);
     * `STRUCTURING`: ≥6 cash credits between 52,000 and 55,000 AED within a 7-day span (Q4 logic).
     Insert one alert per (account, alert_type) — never duplicate an OPEN alert.
6. **Dynamic tables** (`WAREHOUSE = ARGUS_WH`, `TARGET_LAG = '1 minute'`), deterministic
   SQL only (no CURRENT_TIMESTAMP):
   - `ARGUS.CURATED.DT_CROSS_BANK_EDGES` — inter-bank debit edges (from bank/account →
     to bank/account, resolving to_account by joining the counterparty IBAN to accounts).
   - `ARGUS.CURATED.DT_HUB_ACCOUNTS` — Q1 logic.
   - `ARGUS.CURATED.DT_STRUCTURING` — Q4 logic.
7. **Reset procedure.** `ARGUS.RAW.SP_RESET_LIVE_DEMO()` removes delivered live rows
   (`txn_id LIKE 'LV%'`) from TRANSACTIONS, clears `delivered_at`, truncates
   LIVE_ALERTS, and recreates the stream so the demo can be replayed.

## COST SAFETY (mandatory)
- Leave the ROOT task **SUSPENDED** at the end. Resume only the child (required for it
  to run inside the graph). Drive runs with `EXECUTE TASK ARGUS.RAW.TASK_FEED_LIVE`.
- Do not create any other scheduled objects. Do not change warehouse size.

## Verify (use the ground truth only to CHECK results)
1. `EXECUTE TASK` the root, wait until both tasks show SUCCEEDED in
   `TABLE(ARGUS.INFORMATION_SCHEMA.TASK_HISTORY())`; confirm batch 1 landed.
2. Repeat until all 12 batches are delivered (wait for each graph run to finish).
3. `ALTER DYNAMIC TABLE ... REFRESH` all three, then check:
   - `LIVE_ALERTS` has a `CROSS_BANK_HUB` alert for RING-006's consolidation account
     (see `live_typologies` in `data/ground_truth/planted_rings.json`) and **no** alert
     for any account outside the planted rings;
   - `DT_HUB_ACCOUNTS` now includes RING-006's consolidation account plus the two
     historical hubs.
4. Report the timeline: which batch triggered the RING-006 alert.
5. Finally run `CALL ARGUS.RAW.SP_RESET_LIVE_DEMO()` and confirm the live rows are gone,
   the queue is undelivered again and the root task is SUSPENDED.

Write a short summary of objects, verification results and demo commands to
`evidence/coco_s3_pipelines.md`.

Rules: do not drop or modify existing RAW/CURATED/GOVERNED objects from earlier scripts
(other than inserting/deleting live rows as described). Only create files
`sql/06_pipelines.sql` and `evidence/coco_s3_pipelines.md`.
