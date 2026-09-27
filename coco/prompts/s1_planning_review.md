# CoCo session S1 — PLANNING: explore the data, validate the ontology, frame the workflow

You are working on **ARGUS**, a Risk & Regulatory Intelligence Copilot for GCC banks
(team TCC, Snowflake CoCo Hack — GCC Edition). The Snowflake database `ARGUS` already
holds synthetic data for three banks (schemas RAW, CURATED, GOVERNED). Project files are
in the working directory: `ontology/argus_ontology.yaml`, `BUILD_PLAN.md`, `sql/*.sql`,
`data/ground_truth/planted_rings.json`.

This is a **planning / exploration** session. Do the following:

1. **Explore the warehouse.** List every table, view and semantic view in `ARGUS`.
   Profile the RAW tables with real queries: row counts, transaction date range,
   rows per bank, channel and purpose_code mix, null rates of key columns, number of
   cross-bank transactions (counterparty_bank is a consortium bank different from
   bank_id), and the KYC risk-rating mix.
2. **Validate the ontology against the real schema.** Read `ontology/argus_ontology.yaml`
   and compare each entity and attribute with the actual columns (`DESCRIBE TABLE`).
   Report mismatches, attributes in the ontology that don't exist yet, and objects the
   ontology describes that are not built yet (e.g. finding, finding_claim, filing).
3. **Frame the workflow** signal → evidence → finding → filing, and map each step to
   the Snowflake objects that implement it today (or note that it's missing).
4. Write your results to **`evidence/coco_planning_review.md`** with sections:
   *Data profile* (the actual numbers you queried), *Ontology ↔ schema check* (a table),
   *Gaps & risks*, *Workflow outline*, *Recommended next build steps*.

Rules:
- **Read-only in Snowflake**: only SELECT / SHOW / DESCRIBE. Do not create, alter, drop,
  insert, update or delete anything.
- Do not modify any existing file. The only file you may create is
  `evidence/coco_planning_review.md`.
- Do not read `data/ground_truth/` contents into the review as "findings" — it is the
  answer key for testing, not something the system detects.
