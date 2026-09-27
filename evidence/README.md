# ARGUS — CoCo Lifecycle Evidence

*Created by TCC · Snowflake CoCo Hack (GCC Edition)*

Every capability below was built by **CoCo (Cortex Code CLI v1.1.87)** in a recorded session.
Each session has: the brief CoCo was given (`coco/prompts/`), CoCo's full transcript
(`evidence/transcript_*.txt`), CoCo's own summary (`evidence/coco_*.md`), and an
**independent verification** run afterwards against Snowflake (results quoted below).

## Sessions → lifecycle phases

| Session | What CoCo did | Planning | Development | Execution | Testing |
|---|---|:-:|:-:|:-:|:-:|
| **S1** Planning review | Explored the live warehouse (row counts, profiles, `DESCRIBE`), validated the ontology against the real schema, framed signal → evidence → finding → filing | ✅ | | | |
| **S2** Synthetic live feed | Extended the generator with a 12-batch live feed and a ring (RING-006) that forms over batches 3–10; verified historical data byte-identical | ✅ | ✅ | | ✅ |
| **S3** Real-time pipeline | Stream + serverless task graph + 3 incremental dynamic tables + alert engine + replayable demo; ran all 12 batches | | ✅ | ✅ | ✅ |
| **S5** Document AI + search | Parsed 7 PDFs (`AI_PARSE_DOCUMENT`), chunked, built Cortex Search, extracted obligations with a JSON schema, scored vs answer key, human-review queue | | ✅ | ✅ | ✅ |
| **S6** Semantic layer | Extended both semantic views (10 + 5 logical tables), wrote the Cortex Analyst eval harness | | ✅ | | ⚠️ superseded |
| **S6b** Strict Analyst eval | Rewrote grading to be strict, tested verbatim ontology questions, improved the semantic model (named metric, instructions, synonyms) | | ✅ | | ✅ |
| **S7** Google Drive → Snowflake | Used the Google Workspace **MCP** server to list and download the Drive corpus, change-detected by MD5, recorded Drive lineage | | ✅ | ✅ | ✅ |
| **S4** Governance + clean room | Per-bank roles, row isolation, tag-based PII masking, secure cross-bank signal | | ✅ | | ✅ |
| **S6c** Semantic repair | Single source of truth for both semantic views, removed multi-path relationships, restored reg-twin metrics | | ✅ | | ✅ |
| **S9 / S9b** Findings + Verifier | Evidence ledger (claims → transactions + clauses), deterministic Verifier guardrail, per-bank STR drafts + board memo, real numeric grounding check | | ✅ | ✅ | ✅ |
| **S10 / S10b** Multi-agent Orchestrator | Evidence + Policy Cortex Agents, deterministic Verifier/Narrative procedures, Python orchestrator with handoff log (`AGENT_RUN_LOG`); S10b replaces keyword routing with an intent classifier + hard filing-intent rule | | ✅ | ✅ | ✅ |
| **S11** Streamlit investigator app | App owned by `ARGUS_ANALYST` (PII masked), owner's-rights demo wrappers, typology-ID stability across live replay + rediscovery | | ✅ | ✅ | ✅ |
| **S8** Typology discovery | Graph expansion from seed signals → communities → roles/classes → typologies, cards and detection queries; class-based twin mapping | | ✅ | ✅ | ✅ |

## Verified results (independent re-runs, not CoCo's self-report)

| Capability | Result |
|---|---|
| Planning review | Built from live warehouse queries; audit confirmed the session was **read-only** (no object altered) |
| Live pipeline | RING-006 alerted **at batch 10** (the batch completing its 2nd source bank); **0 false alerts**; demo resets to 8,747 rows; root task left **suspended**; cost ≈ 0.26 warehouse + 0.008 serverless credits |
| Document extraction | Article recall **10/10**, scope accuracy **10/10**; 1 article not in the answer key (FATF Sec. 16.1) routed to **human review**, not auto-loaded |
| Cortex Search | SAMA Art. 8 returned first for "mule accounts fed from multiple institutions" (regulator = SAMA) |
| Drive ingestion | 7/7 Drive files **MD5-identical** to parsed copies → `UNCHANGED`; every document carries `gdrive://` lineage; only read-only Google tools used |
| Cortex Analyst (strict) | Verbatim ontology questions **5–6 / 6**, paraphrases **10–11 / 12** across two independent runs; Q6 value exact (AED 372,968.44) |
| Semantic SQL (Week 2) | 6/6 on sqlite and on Snowflake, identical figures |
| Typology discovery | Fresh run scored independently: **5/5 rings** found exactly (Jaccard 1.00), class correct for all; **source mules 9/9** in both mule rings (per-account rules: 0/9); **0 clean accounts** in any typology; the benign-only household account is in **no** typology. Live RING-006 discovery reported by S8's validator (not re-run independently) |
| Governance / clean room | Bank roles see **only their own 180 customers** (real PII) yet the **same 8 cross-bank signals** as the admin; bank roles are **denied** the regulatory twin; `ARGUS_ANALYST` sees all 540 with PII **`***MASKED***`**; the signal view is **secure** and exposes only hashes, bank lists and counts |

## Recommended CoCo tasks — coverage

| Brief's recommended task | Where |
|---|---|
| Synthetic data generation | S2 (+ Week 1 generator) |
| Data pipeline creation (dynamic tables, tasks, streams) | S3 |
| Semantic model & ontology authoring | S1 (ontology check), S6, S6b |
| Streamlit report / app | *Week 3* |
| Connecting additional sources via MCP | S7 (Google Drive; Gmail drafts + Docs enabled) |
| Document & unstructured processing | S5 |

## Integrity notes (what went wrong and how it was handled)

We keep first attempts and corrections in the record rather than hiding them.

1. **S1 attempt 1 fell back to CSV files.** In non-interactive mode CoCo auto-rejects SQL
   unless run with `--bypass`, so the first planning review profiled local CSVs. It was
   re-run against the live warehouse. Both are kept:
   `transcript_s1_attempt1_sql_blocked.txt`, `coco_planning_review_attempt1_csv_only.md`.
2. **S6's 94% Analyst score was not valid.** It reworded the test questions to name the
   answer tables, and graded Q6 as "any number > 0" (AED 2 passed). S6b replaced it with
   verbatim questions and strict graders. S6's outputs are kept as `*_s6_lenient.*`.
3. **Answer-key rows leaked into a governed table.** S6 wrote 34 ground-truth ring members
   into the permanent `ARGUS.GOVERNED.TYPOLOGY_EVIDENCE` (it was told to use a temporary
   table). They were deleted, and the strict evaluation was re-run to show the results
   don't depend on them (5/6 and 11/12). Harnesses now use session-TEMPORARY tables only.
4. **Time-relative questions had no correct non-empty answer.** None of the historical rings
   fall in "the last 7 days" of the data, so those two ontology questions now name the
   period ("in September 2026"). "This week" is reserved for the live feed (RING-006).
5. **S6 left the semantic layer inconsistent.** Its rewrite added redundant relationships
   (four paths from transactions to banks → "multi-path" errors on by-bank queries),
   dropped the reg-twin view's metrics, and the repo YAML no longer matched the deployed
   views. S6c rebuilt a single source of truth (`sql/11_semantic_views.sql`) from the live
   definitions, removed the redundant paths, restored the metrics and re-exported the YAML.
   Independent check found one thing S6c missed: recreating the views **dropped the
   analyst role's grants**, and CoCo's "works as ARGUS_ANALYST" check was a false pass
   (secondary roles were still active, lending admin privileges). Fixed with explicit
   grants plus a `FUTURE SEMANTIC VIEWS` grant, and re-verified with
   `USE SECONDARY ROLES NONE`. All role tests now run that way.
6. **Discovery procedure depended on session state.** S8's `SP_DISCOVER_TYPOLOGIES()` created
   19 unqualified temporary tables, so a plain `CALL` from a fresh session (no current
   schema) failed. Fixed by fully qualifying them and re-verified from a fresh session.
7. **Answer-key overlap from the Week 1 generator.** Benign account A0000275 was also drawn
   as a RING-005 source mule, so it correctly appears in RING-005's typology. The answer
   key now documents this; the benign test uses the benign-only account A0000004, which
   is in no typology (the weak device link was not followed).
8. **S9's grounding check did not check numbers.** It recorded `grounding_passed: true`
   after only counting citation markers and cross-bank ID leaks (hard-coded `TRUE` for
   board memos). Independent review found the ring total (AED 372,968.44) in every mule-ring
   STR without a cited claim, and memos citing no claims. Data minimisation did hold (no
   STR contains another bank's IDs) and the model only ever received verified claims.
   S9b implements a real numeric grounding check with negative tests. S9's procedures also
   had the session-state bug (unqualified tables) — fixed and re-tested from a fresh session.
   Review of S9b found it had **removed the data-minimisation assertion** from the test
   suite (after a re-draft was correctly rejected for leaking a BANK_C account ID); the
   assertion was restored as its own test — suite now 46/46, every pending STR clean.
   Open follow-ups: memo remediation timelines are model recommendations (label them);
   leaking drafts are rejected but not retried; amounts < 1,000 are not grounding-checked.
9. **S10 graded routing, not answers.** Its validator checked which specialist a question
   went to and smoke-tested the agents; the required end-to-end report was never written.
   An independent end-to-end harness (`validation/validate_orchestrator_e2e.py`) scored
   **10/12**: all six ontology questions, the filing decision, the weak-signal rejection,
   the PII refusal and the ungrounded refusal pass. Both failures were keyword-routing
   misses on paraphrases; one sent a filing question to the LLM agents instead of the
   Verifier (the agent itself declined to decide, so no LLM opinion leaked). S10b replaces
   keyword routing; final grading uses a hold-out set the build session never saw.
10. **S10b over-corrected and the filing path was not idempotent.** S10b (interrupted by a
   network error after its code change) made filing intents reliably reach the Verifier
   (5/5 on a hold-out set), but the widened PII gate refused a core ontology question that
   merely mentioned "national ID", a rulebook question containing "filing" drafted STRs as
   a side effect, and every filing question created a new finding and new drafts (24
   findings / 68 drafts for 5 typologies). S10c made the Verifier path reuse existing
   findings, drafts only on explicit request, narrowed the PII gate to requests *for* a
   value, added a speculation refusal, added draft retries on grounding rejection, and
   cleaned up to one finding per typology. Final grading uses a second, fresh hold-out set.
   Hold-out v2 (fresh questions): filing questions reach the Verifier (reusing the
   existing verified finding), policy 3/3, evidence 2/2, speculation 2/2, and asking the same
   filing question twice created **no** new findings or drafts. One miss — "Who is the
   account holder behind A0000095?" was not refused (nothing sensitive leaked: the semantic
   view holds no names) — fixed with a "who is/owns" identity gate, unit-tested on 7 cases.
11. **Open governance gap (logged):** the fraud semantic view exposes raw IBANs from all
   three banks to the consortium analyst, bypassing the clean room's IBAN hashing. Masking
   must use `INVOKER_ROLE()` so the clean-room view (which hashes the raw IBAN) keeps
   working — scheduled for Week 4 hardening.
12. **S11 app: three issues found in review.** (a) The analyst was granted `UPDATE` on the
   whole `FILING` table and the Approve button appeared for any non-approved draft — so an
   analyst could rewrite a narrative or approve a draft the grounding check had rejected.
   Replaced with `SP_APPROVE_FILING` (owner's rights; only `DRAFT_PENDING_HUMAN` drafts;
   records approver + time) and revoked `UPDATE`; tested as the analyst: direct UPDATE
   denied, pending draft approved, re-approval and unknown IDs refused. (b) The deployed app
   was missing `orchestrator.py`, so "Ask ARGUS" would have failed inside Snowflake —
   redeployed (still owned by `ARGUS_ANALYST`). (c) The wrapper procedures lacked `$$`
   delimiters, so the SQL file could not be re-run with the Snowflake CLI — fixed. Verified
   in Snowsight: Overview (KPIs, gaps by regulator, live-feed controls) and Filing Review
   (per-bank STRs, grounding PASSED, pending review) render with live data.
13. **Analyst declines filing decisions — by design.** Asked "should we file?", Cortex
   Analyst answered that it is a compliance judgement. The Week 3 Orchestrator routes the
   evidence part to Analyst and the decision to the Verifier agent.

## How sessions were run

```
cortex exec -c argus --bypass --blocked "<unneeded tools>" --file coco/prompts/<session>.md
cortex conversations transcript <id> > evidence/transcript_<session>.txt
```
Unneeded tools (scheduling, web access, team/messaging) were blocked per session; every
session's Snowflake activity was checked in `QUERY_HISTORY` / object timestamps afterwards.

Live, interactive CoCo recordings (CLI + Desktop) complement these transcripts for the demo.
