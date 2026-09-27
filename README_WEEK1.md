# ARGUS — Week 1 Deliverables

*Created by TCC · Snowflake CoCo Hack (GCC Edition)*

Week 1 = **Planning + Data foundation**. This delivers the ontology, a
privacy-safe synthetic dataset for 3 banks with **planted cross-bank fraud
rings**, ground truth for later accuracy testing, and the Snowflake load +
clean-room SQL.

## What's here

```
ontology/argus_ontology.yaml        # the shared spine (fraud <-> regulation)
data_generator/generate_data.py     # deterministic generator (stdlib only)
data/*.csv                          # generated: banks, customers, accounts, device_logins, transactions
data/ground_truth/planted_rings.json# every planted ring (for Week 4 recall testing)
sql/01_raw_schema.sql               # RAW+CURATED schema, COPY INTO loaders, curated views
sql/02_clean_room.sql               # privacy-preserving cross-bank shared-signal (the moat)
```

## Regenerate the data
```bash
python data_generator/generate_data.py
```
Deterministic (seed 4471) — same output every run, so demos are reproducible.

## Dataset at a glance
- **3 banks:** BANK_A (CBUAE/AE), BANK_B (SAMA/SA), BANK_C (CBB/BH)
- **540 customers · 627 accounts · ~8,750 transactions · ~1,600 logins**
- Clean activity is all bank-to-external; cross-bank flows exist only inside the rings, hidden among ~8.7k normal transactions
- Each customer owns 1–2 personal devices, so a device seen at 2+ banks is a real signal (not random collisions)
- Raw `national_id`/`phone` stay private; `*_hash` columns are what the clean room shares

## Planted rings (ground truth)
| Ring | Typology | Banks | What to detect |
|---|---|---|---|
| RING-001 | Fan-in/fan-out mule ring | A,B,C | 9 source mules → 3 funnels → 1 consolidation, 6-day burst |
| RING-002 | Shared/synthetic identity | A,B,C | one `national_id_hash` + one `device_hash` across 3 banks |
| RING-003 | Cash structuring | C | 8–11 cash deposits just under the 55,000 AED CTR threshold |
| RING-004 | Circular layering | A,B,C | A→B→C→A loop, value returns to origin |
| RING-005 | Fan-in/fan-out mule ring | A,B,C | second mule ring for variety |
| BENIGN-001 | *Hard negative:* household shares one tablet | A,B | must **not** be escalated — tests false positives |

## Load into Snowflake
Uses the `argus` connection (key-pair auth) shared by the Snowflake CLI and CoCo.
The full, current run order (including Week 2 objects) is in `README_WEEK2.md`.

```bash
snow sql -c argus -f sql/00_setup_warehouse.sql
snow stage copy data/transactions.csv @ARGUS.RAW.ARGUS_STAGE -c argus --overwrite   # one file per command
snow sql -c argus -f sql/01_raw_schema.sql
snow sql -c argus -f sql/02_clean_room.sql
snow sql -c argus -q "SELECT * FROM ARGUS.GOVERNED.shared_bad_actor_signal ORDER BY risk_weight DESC"
```
Upload the five CSVs one at a time — Windows shells expand `*.csv` before `snow` sees it.

## How this maps to hackathon requirements
- **CoCo — Planning phase:** ontology + solution design authored with CoCo.
- **Synthetic data generation:** referentially consistent, privacy-safe, no production data.
- **Snowflake backbone:** all data + the clean-room signal live in Snowflake.
- **Sets up the moat:** `shared_bad_actor_signal` is the cross-bank signal no single bank can compute.

## Next — Week 2
Pipelines (dynamic tables/streams/tasks), CoCo-inferred **semantic views + verified
queries** validated against the questions in `argus_ontology.yaml`, the real Data
Clean Room object, and the reg→control **Twin** tables from policy docs pulled via
the **Google Drive MCP** connector.
