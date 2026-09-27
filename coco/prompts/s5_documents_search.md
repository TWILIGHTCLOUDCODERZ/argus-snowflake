# CoCo session S5 — DOCUMENT AI: parse circulars + filings, extract obligations, Cortex Search

Project: **ARGUS** (team TCC). The regulatory Digital Twin lives in `ARGUS.GOVERNED`
(tables REGULATION, CLAUSE, OBLIGATION, CONTROL, CONTROL_OBLIGATION, TYPOLOGY_OBLIGATION;
views CONTROL_GAP, TYPOLOGY_EXPOSURE — see `sql/05_regulatory_twin.sql`). Right now its
regulation/clause/obligation rows come from a hand-written seed (`data/twin_seed.json`,
also staged at `@ARGUS.RAW.ARGUS_STAGE/twin_seed.json`). Goal: make the twin come from
the **documents themselves**, with measured accuracy and human review for disagreements.

Source documents (synthetic, PDF):
- `policy_corpus/pdf/*.pdf` — 4 circulars: CBUAE, FATF R16, SAMA, CBB
- `filings_corpus/pdf/*.pdf` — 3 past Suspicious Transaction Reports (one per bank)

In production these arrive from Google Drive via MCP; for now upload the local PDFs.

## Build (write ALL SQL to `sql/08_documents.sql`, then run it)
1. **Stage**: `ARGUS.GOVERNED.DOCS_STAGE` with `DIRECTORY = (ENABLE = TRUE)` and
   `ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')`. Upload each PDF uncompressed with bash, one
   file per command (Windows shells expand wildcards), into `circulars/` and `filings/`:
   `.venv/Scripts/snow stage copy policy_corpus/pdf/SAMA_AMLCTF_2023.pdf @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite`
   Then `ALTER STAGE ... REFRESH`.
2. **Parse**: `ARGUS.GOVERNED.DOCUMENTS` (relative_path, doc_type 'circular'|'filing',
   content, parsed_at) using `AI_PARSE_DOCUMENT(TO_FILE('@ARGUS.GOVERNED.DOCS_STAGE', relative_path), {'mode': 'LAYOUT'})`.
3. **Chunk**: `ARGUS.GOVERNED.DOCUMENT_CHUNKS` (relative_path, doc_type, regulator or
   filing institution, chunk_index, chunk) via
   `SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(content, 'markdown', 800, 100)`.
4. **Cortex Search**: service `ARGUS.GOVERNED.POLICY_SEARCH` ON chunk, ATTRIBUTES
   doc_type, regulator, relative_path; `WAREHOUSE = ARGUS_WH`, `TARGET_LAG = '1 day'`.
5. **Extract obligations** from each circular with `AI_COMPLETE` using model
   `claude-sonnet-4-5` and a JSON-schema `response_format` into
   `ARGUS.GOVERNED.EXTRACTED_OBLIGATIONS` (regulation_id as printed in the document,
   regulator, title, effective_date, article_ref, clause_text, obligation_text, category,
   required_scope, source_path). Define `required_scope` for the model precisely:
   `cross_bank` when meeting the requirement needs visibility across institutions
   (the text says single-institution checks are insufficient, or it's about networks,
   chains, identifiers or flows spanning institutions); otherwise `single_bank`.
   Note: `model` is `claude-sonnet-4-5` (`mistral-large2` is retired in this account).
6. **Evaluate against the answer key** (`twin_seed.json` on the stage): per clause, match
   extracted (regulation_id, normalized article_ref) to expected. Store results in
   `ARGUS.GOVERNED.EXTRACTION_EVAL` (regulation_id, article_ref, found, scope_expected,
   scope_extracted, scope_match, status). Report article recall, scope accuracy, and
   metadata accuracy (regulator, effective_date).
7. **Human-in-the-loop load into the twin** (AI proposes, human approves):
   - Where an extracted clause matches the expected article AND scope: update the twin's
     CLAUSE.text / OBLIGATION.obligation_text to the extracted wording and set
     `source = 'cortex_extraction'` on REGULATION, CLAUSE and OBLIGATION. Keep existing IDs.
   - Where scope disagrees, or an extracted article is not in the answer key: do NOT
     change the twin; insert into `ARGUS.GOVERNED.OBLIGATION_REVIEW_QUEUE`
     (regulation_id, article_ref, proposed values, reason, status 'PENDING_REVIEW').
8. **Past filings**: extract (filing_id, institution, regulator, fiu, filed_on, typology,
   status, cross_institution_limitation BOOLEAN) with AI_COMPLETE + JSON schema into
   `ARGUS.GOVERNED.PAST_FILINGS`.

## Verify
- `DOCUMENTS` has 7 rows with non-empty content; chunk count per document.
- Search checks with `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` (top result must be right):
  a) "mule accounts fed from multiple institutions" filtered regulator = SAMA → SAMA Art. 8
  b) "deadline to file a suspicious transaction report" → CBB FC-6.1
  c) "investigator could not see accounts at other institutions" filtered doc_type =
     filing → STR-2026-0588 or STR-2025-1190
- Extraction scorecard from step 6, and the twin after step 7:
  `SELECT source, COUNT(*) FROM ARGUS.GOVERNED.OBLIGATION GROUP BY 1`.
- Correlation still correct: `SELECT typology_id, COUNT_IF(is_gap) gaps FROM
  ARGUS.GOVERNED.TYPOLOGY_EXPOSURE GROUP BY 1` — RING-003 must have 0 gaps;
  RING-001/002/004/005/006 must have >0.

Write objects, the scorecard, search results and the review queue to
`evidence/coco_s5_documents.md`.

Rules: do not drop or recreate CONTROL, CONTROL_OBLIGATION or TYPOLOGY_OBLIGATION. Do not
touch RAW/CURATED objects. Only create `sql/08_documents.sql` and
`evidence/coco_s5_documents.md`.
