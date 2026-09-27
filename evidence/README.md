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
6. **Analyst declines filing decisions — by design.** Asked "should we file?", Cortex
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
