# CoCo session S11 — STREAMLIT INVESTIGATOR APP (Streamlit in Snowflake)

Project: **ARGUS** (team TCC). Read `docs/WEEK3_PLAN.md`, `evidence/README.md` and
`app/orchestrator.py` (session S10). Build the investigator app a compliance analyst uses
for the demo: signal → evidence → finding → filing, plus "Ask ARGUS".

## Governance first (Streamlit in Snowflake runs with the OWNER's privileges)
- The app must be **owned by `ARGUS_ANALYST`**, not ACCOUNTADMIN — otherwise every viewer
  would see unmasked PII. Grant ARGUS_ANALYST what it needs to create and run the app
  (CREATE STREAMLIT on `ARGUS.GOVERNED` or an `ARGUS.APP` schema, USAGE on ARGUS_WH and the
  app stage) and create the app while using that role.
- Demo operations the analyst may trigger go through **narrow owner's-rights wrapper
  procedures** (e.g. `ARGUS.GOVERNED.SP_DEMO_NEXT_BATCH()` = deliver next live batch +
  raise alerts; `SP_DEMO_REDISCOVER()` = run discovery; `SP_DEMO_RESET()`), granted to
  ARGUS_ANALYST with USAGE. Never grant broad write access.

## App (`app/streamlit_app.py` + pages; deploy with `snow streamlit deploy` and a
`app/snowflake.yml`; only packages available in Streamlit in Snowflake — no pip installs)
1. **Overview** — KPIs (typologies by class, open live alerts, open control gaps by
   regulator), live-feed panel: "Deliver next batch" / "Reset demo" buttons, batch
   counter, alerts appearing as the RING-006 forms.
2. **Typologies** — list with class, banks, value, window; typology card (markdown);
   members by role; a ring diagram with `st.graphviz_chart` (source mules → funnels →
   consolidation, coloured by bank); its detection query.
3. **Finding** — claims table (type, text, confidence, verified flag); selecting a claim
   shows the cited transactions (PII masked) and the cited clause text; Verifier status
   and reason prominent (VERIFIED / REJECTED).
4. **Filing review** — per-bank STR drafts and the board memo, grounding-check result,
   "Approve draft" (sets approved_by = CURRENT_USER(), status APPROVED) — nothing is sent;
   delivery comes in Week 4 as Gmail drafts.
5. **Ask ARGUS** — chat that calls the S10 orchestrator; show the answer with citations
   and an expandable handoff trace from `AGENT_RUN_LOG`.

## Verify
- `snow streamlit deploy` succeeds; print the app URL (`snow streamlit get-url`).
- Run each page's data functions from a local Python harness with the connector while
  using `USE SECONDARY ROLES NONE; USE ROLE ARGUS_ANALYST;` — all queries succeed and PII
  columns come back masked.
- Exercise the demo path via the wrapper procedures as ARGUS_ANALYST: reset → deliver
  batches until the RING-006 alert appears → rediscover → the new typology shows up →
  build/verify finding → drafts exist. Then reset the demo and rediscover so the baseline
  (5 typologies, 0 live rows, root task suspended) is restored.
- **Typology ID stability**: `FINDING.typology_id` values (FND-0007…FND-0011 → TYP-0001…0005)
  must still point at the same member sets after the live replay, reset and rediscovery.
  Snapshot each typology's sorted member list before the demo path and compare after. If
  `SP_DISCOVER_TYPOLOGIES` renumbers typologies, make ID assignment deterministic (e.g.
  reuse the existing ID when the member set matches, new IDs only for new typologies)
  and fix it in `sql/10_sp_discover.sql`; keep procedures fully schema-qualified.
Write `evidence/coco_s11_streamlit.md` (pages, governance model, URL, test results).

Rules: drafts only, nothing sent. Don't change warehouse size or scheduled tasks. Role
checks start with `USE SECONDARY ROLES NONE;`, restore `USE SECONDARY ROLES ALL;` after.
