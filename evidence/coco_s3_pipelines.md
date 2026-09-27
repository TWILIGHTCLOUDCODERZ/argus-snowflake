# ARGUS · CoCo Session S3 — Data Pipelines Evidence

## Objects Created (`sql/06_pipelines.sql`)

| Object | Schema | Type | Purpose |
|--------|--------|------|---------|
| `TXN_LIVE_QUEUE` | RAW | Table | 202-row staging queue (12 micro-batches from `live_feed.csv`) |
| `TRANSACTIONS_STREAM` | RAW | Stream (append-only) | Captures new rows inserted into `TRANSACTIONS` |
| `SP_DELIVER_NEXT_BATCH()` | RAW | Procedure | Inserts lowest undelivered batch into TRANSACTIONS, marks delivered |
| `LIVE_ALERTS` | GOVERNED | Table (IDENTITY PK) | Alert store: alert_type, account, bank, metrics, status |
| `SP_RAISE_ALERTS()` | GOVERNED | Procedure | Consumes stream; evaluates Q1 (cross-bank hub) + Q4 (structuring) |
| `TASK_FEED_LIVE` | RAW | Task (serverless, root) | 1-min schedule, calls `SP_DELIVER_NEXT_BATCH` — left **SUSPENDED** |
| `TASK_RAISE_ALERTS` | RAW | Task (serverless, child) | AFTER root, WHEN stream has data, calls `SP_RAISE_ALERTS` |
| `DT_CROSS_BANK_EDGES` | CURATED | Dynamic Table | Inter-bank debit edges with resolved to_account (IBAN join) |
| `DT_HUB_ACCOUNTS` | CURATED | Dynamic Table | Q1: accounts with credits from ≥2 other consortium banks in 7 days |
| `DT_STRUCTURING` | CURATED | Dynamic Table | Q4: ≥6 cash credits 52000–55000 AED within 7 days |
| `SP_RESET_LIVE_DEMO()` | RAW | Procedure | Removes LV% rows, clears queue, truncates alerts, recreates stream |

> **Note:** Child task placed in RAW (not GOVERNED) because Snowflake requires all task graph members in the same schema.

## Verification Results

### Batch Delivery
All 12 batches delivered successfully via `EXECUTE TASK`. Both TASK_FEED_LIVE and TASK_RAISE_ALERTS showed SUCCEEDED in TASK_HISTORY for every run. 202 live rows inserted into TRANSACTIONS.

### LIVE_ALERTS

| alert_id | alert_type | account_id | bank_id | source_banks | inbound_amount |
|----------|-----------|------------|---------|-------------|----------------|
| 1 | CROSS_BANK_HUB | **A0000284** | BANK_B | 2 | 146,886.68 AED |

- A0000284 is RING-006's consolidation account (ground truth confirmed).
- **No false positives** — no alerts for accounts outside the planted rings.

### Alert Timeline
- **Batch 8**: First cross-bank credit arrives (BANK_C → A0000284, 74,499.28 AED). Only 1 source bank — no alert yet.
- **Batch 10**: Second cross-bank credit arrives (BANK_A → A0000284, 72,387.40 AED). Now 2 source banks — **alert raised**.
- Raised_at: `2026-09-27 00:51:35` (immediately after batch 10 task graph completed at 00:51:32).

### DT_HUB_ACCOUNTS (after refresh)

| account_id | bank_id | source_banks | inbound_amount |
|-----------|---------|-------------|----------------|
| A0000046 | BANK_A | 2 | 159,995.53 | ← RING-005 (historical) |
| A0000095 | BANK_A | 2 | 150,060.57 | ← RING-001 (historical) |
| **A0000284** | **BANK_B** | **2** | **146,886.68** | ← **RING-006 (live)** |

### DT_STRUCTURING (after refresh)

| account_id | bank_id | deposits | total_amount |
|-----------|---------|----------|-------------|
| A0000343 | BANK_B | 10 | 531,676.09 | ← RING-003 (historical) |

### DT_CROSS_BANK_EDGES
9 inter-bank debit edges (includes both historical ring edges and RING-006 live edges).

### Reset Verification
`CALL ARGUS.RAW.SP_RESET_LIVE_DEMO()` confirmed:
- 0 live rows in TRANSACTIONS (`txn_id LIKE 'LV%'` removed)
- 202 queue rows back to undelivered (`delivered_at = NULL`)
- 0 rows in LIVE_ALERTS (truncated)
- Stream recreated (offset reset)
- Root task remains SUSPENDED

## Demo Commands

```sql
-- Deliver one batch and check results
EXECUTE TASK ARGUS.RAW.TASK_FEED_LIVE;
-- Wait ~15s, then:
SELECT * FROM TABLE(ARGUS.INFORMATION_SCHEMA.TASK_HISTORY())
  WHERE name IN ('TASK_FEED_LIVE','TASK_RAISE_ALERTS')
  ORDER BY scheduled_time DESC LIMIT 4;

-- Check alerts
SELECT * FROM ARGUS.GOVERNED.LIVE_ALERTS;

-- Refresh and query dynamic tables
ALTER DYNAMIC TABLE ARGUS.CURATED.DT_HUB_ACCOUNTS REFRESH;
SELECT * FROM ARGUS.CURATED.DT_HUB_ACCOUNTS;

-- Reset for replay
CALL ARGUS.RAW.SP_RESET_LIVE_DEMO();
```
