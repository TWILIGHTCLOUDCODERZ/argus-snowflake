# CoCo session S2 — SYNTHETIC DATA: add a live transaction feed with a ring that forms over time

Project: **ARGUS** (team TCC). `data_generator/generate_data.py` is a deterministic
(seed 4471), standard-library-only generator that writes historical synthetic data for
3 banks plus a ground-truth file of planted fraud rings. Read it fully first.

## Goal
Extend the generator so it ALSO writes a **live feed** — future transactions that a
Snowflake task will later drip into the warehouse in micro-batches, so ARGUS can detect
a fraud ring *as it forms*.

## Requirements
1. **Historical output must stay byte-identical.** `banks.csv`, `customers.csv`,
   `accounts.csv`, `device_logins.csv`, `transactions.csv` must not change at all.
   So: put all new code AFTER the existing `plant_benign_shared_device("BENIGN-001")`
   call, never append live rows to the existing `txns` / `logins` lists, never touch
   `_txn_seq`, and only draw random numbers after all historical planting is done.
   The `planted_rings.json` file may gain a new key but existing keys must be unchanged.
2. Write **`data/live_feed.csv`** with columns, in order:
   `feed_seq, batch_no, txn_id, bank_id, account_id, direction, amount, currency,
   channel, counterparty_iban, counterparty_bank, purpose_code`
   - No timestamp column: the warehouse stamps the arrival time.
   - `txn_id` uses its own prefix and counter: `LV00000001`, `LV00000002`, …
   - `feed_seq` is 1..N in delivery order; `batch_no` is 1..12.
3. **Clean noise:** ~15 normal transactions per batch drawn from existing accounts,
   using the same purpose/amount/channel distributions as the historical clean
   transactions (counterparty_bank = `EXTERNAL`).
4. **Planted RING-006** — a cross-bank fan-in/fan-out mule ring that forms gradually:
   - 3 source mules per bank (9 total) → 1 funnel per bank → consolidation = the BANK_B
     funnel (a different bank from RING-001/005, whose consolidation is in BANK_A).
   - Source → funnel transfers (same-bank, `p2p`, 18k–34k AED) spread over batches 3–7.
   - Funnel → consolidation cross-bank transfers (60k–95k AED) in batches 8–10.
   - Write BOTH legs of every transfer (debit at sender, credit at receiver), exactly
     like the existing `plant_fan_in_fan_out` does.
   - Use only accounts that are not members of any existing ring or benign control.
5. Record ground truth under a NEW top-level key in `planted_rings.json`:
   `"live_typologies": [{ "typology_id": "RING-006", "name": ..., "structure": ...,
   "banks_involved": [...], "forms_over_batches": [3, 10], "members": [...] }]` with
   member entries shaped like the existing ones (entity_type, entity_id, role, bank_id).
6. Print a line with the live feed row count and batch count.

## Verify before you finish
- Run the generator: `python data_generator/generate_data.py`
- Run `md5sum data/banks.csv data/customers.csv data/accounts.csv data/device_logins.csv data/transactions.csv`
  and compare with `coco/.baseline_md5.txt` — the five historical CSVs MUST match.
- Show the row count per batch_no of `data/live_feed.csv` and the RING-006 member count.

Rules: only edit `data_generator/generate_data.py`; the generator itself writes the data
files. Do not touch Snowflake in this session.
