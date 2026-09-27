# ARGUS — Recording & Demo Script

*Created by TCC.* Two deliverables: **(A)** short screen recordings of you using CoCo in each
lifecycle phase (judges look for this), and **(B)** the 5-minute demo storyline.

## Before recording

- Open a **new** PowerShell window (so it has the Google variables), then:
  ```powershell
  cd "D:\hackathon\Snowflake hackathon"
  ```
- Start recording: **Win + Alt + R** (Xbox Game Bar) or OBS. Record the terminal full-screen,
  font size ≥ 16.
- Start CoCo: `cortex` → it opens on the `argus` connection.
- After any live-feed demo, reset with:
  `CALL ARGUS.RAW.SP_RESET_LIVE_DEMO();` then `CALL ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES();`

---

## Part A — CoCo lifecycle clips (≈ 2 minutes each)

Type these prompts into CoCo as written. Each is safe to run on the demo account.

### Clip 1 — Planning (explore + frame)
> Explore the ARGUS database read-only. Summarise the three banks' data, the cross-bank
> signals, and which parts of `ontology/argus_ontology.yaml` are implemented. Don't change
> anything.

Show: CoCo running SHOW/SELECT queries and summarising.

### Clip 2 — Development (build something live)
> Create a view ARGUS.CURATED.V_DAILY_CROSS_BANK that sums cross-bank transfer value per
> day and per receiving bank. Grant SELECT to ARGUS_ANALYST, then query it and explain the
> result.

Show: CoCo writing and running the DDL, then validating it.

### Clip 3 — Execution (run the live pipeline)
> Deliver live batches with CALL ARGUS.RAW.SP_DELIVER_NEXT_BATCH() and
> CALL ARGUS.RAW.SP_RAISE_ALERTS() one at a time until ARGUS.GOVERNED.LIVE_ALERTS shows a
> CROSS_BANK_HUB alert. Tell me which batch triggered it. Then reset with
> CALL ARGUS.RAW.SP_RESET_LIVE_DEMO().

Show: the alert appearing at batch 10 — the ring completing its second source bank.

### Clip 4 — Testing (validate)
> Run `.venv/Scripts/python validation/validate_week2.py --backend snowflake` and explain
> what each of the six checks proves.

Show: 6/6 and CoCo's explanation.

### Clip 5 — MCP (cross-tool)
> Using the google-workspace tools, list the files in my Drive folder "ARGUS Policy Corpus"
> and tell me which regulator each circular comes from.

Show: CoCo calling the Drive MCP tools and answering.

### Clip 6 — Ask ARGUS (multi-agent)
```powershell
.venv\Scripts\python app\orchestrator.py "Should we file on TYP-0003?"
```
Show: the Verifier decision, the per-bank STR drafts, and the handoff trace.

---

## Part B — 5-minute demo storyline

| Time | Beat | What to show |
|---|---|---|
| 0:00 | **The problem** | Three GCC banks, each seeing only its own customers. A mule ring spans all three. |
| 0:40 | **Cross-bank without sharing data** | As `ARGUS_BANK_A`: 180 customers, real PII — yet the same 8 cross-bank signals as the consortium. As `ARGUS_ANALYST`: PII `***MASKED***`. |
| 1:20 | **A ring forms live** | Deliver batches; the alert fires at batch 10. |
| 2:00 | **Discovery finds the hidden mules** | The typology card and ring diagram: 9 source mules → 2 funnels → consolidation, across 3 banks. Per-account rules would have caught 0 of the 9. |
| 2:40 | **Which rules it breaks** | Regulatory twin: CBUAE Art. 31, SAMA Art. 8, FATF 16.4 — and control C-12 (cross-institution monitoring) not deployed → HIGH gap. Circulars came from Google Drive via MCP. |
| 3:20 | **Evidence, verified** | Finding claims, each citing transactions and a clause; the Verifier's VERIFIED decision. |
| 3:50 | **Per-bank STR drafts** | Bank A → UAE FIU (goAML), Bank B → GDFI, Bank C → FID — each citing only its own IDs; grounding check passed; awaiting human approval. |
| 4:20 | **It fails safely** | Ask for a customer's national ID → refused. Ask whether a regulator will fine a bank → refused. A weak shared-device case → REJECTED, no filing. |
| 4:45 | **Built with CoCo, honestly** | `evidence/README.md`: every session, transcript, verified numbers, and the integrity log. |

*The Streamlit investigator app (Week 3, session S11) will host beats 1:20–4:20 in one UI.*
