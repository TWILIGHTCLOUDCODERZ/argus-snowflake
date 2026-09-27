# CoCo session S7 — GOOGLE DRIVE → SNOWFLAKE document ingestion (via MCP)

Project: **ARGUS** (team TCC). The document pipeline from session S5 (`sql/08_documents.sql`)
parses PDFs from `@ARGUS.GOVERNED.DOCS_STAGE` (`circulars/`, `filings/`) into
`ARGUS.GOVERNED.DOCUMENTS` → `DOCUMENT_CHUNKS` → Cortex Search `POLICY_SEARCH`, and extracts
obligations. Those PDFs were uploaded from local files. In production, circulars and filings
arrive in a Google Drive folder. Make **Google Drive the source**, using the
`google-workspace` MCP server (read-only Drive access for deepanreyvampire@gmail.com).

## Steps
1. With the google-workspace MCP tools, find the Drive folder **`ARGUS Policy Corpus`** and
   list its files (expect 7 PDFs: 4 circulars, 3 STR filings named `STR-*`).
2. Download each file with `get_drive_file_download_url` (in stdio mode it saves the file
   locally and returns the path).
3. **Ingestion log**: create `ARGUS.GOVERNED.DOC_INGEST_LOG` (drive_file_id, file_name,
   doc_type 'circular'|'filing', drive_modified_time, md5, stage_path, action, ingested_at)
   and add nullable columns `drive_file_id` and `source_uri` to `ARGUS.GOVERNED.DOCUMENTS`
   (ALTER TABLE ... ADD COLUMN IF NOT EXISTS).
4. **Change detection**: compute each downloaded file's MD5 and compare with the MD5 of the
   file already on the stage (`LIST @ARGUS.GOVERNED.DOCS_STAGE`), matching by file name.
   - Identical → log action `UNCHANGED`, do not re-upload or re-parse.
   - Different or new → upload to the right stage folder (bash, one file per command:
     `.venv/Scripts/snow stage copy "<local path>" @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite`),
     `ALTER STAGE ... REFRESH`, re-parse just that file into DOCUMENTS/DOCUMENT_CHUNKS with the
     same logic as `sql/08_documents.sql`, log `INGESTED` or `UPDATED`.
5. **Lineage**: for every document, set `DOCUMENTS.drive_file_id` and
   `source_uri = 'gdrive://ARGUS Policy Corpus/<file name>'` (and the Drive file ID) so every
   parsed document and search result can be traced to its Drive original.
6. Write the reusable SQL (table DDL, ALTERs, lineage updates, re-parse template) to
   `sql/09_drive_ingestion.sql`.

## Verify
- `DOC_INGEST_LOG` has one row per Drive file (7) with actions; state how many were
  unchanged vs ingested.
- All 7 `DOCUMENTS` rows have a `drive_file_id`.
- Cortex Search still answers: "mule accounts fed from multiple institutions" filtered
  regulator = SAMA → SAMA Art. 8.

Write the file list (name, Drive ID, MD5, action), verification results and a
"How a new circular flows in" section to `evidence/coco_s7_drive_ingestion.md`.

Rules: Drive is read-only — never create, modify, share or delete Drive files. Do not drop
or recreate existing Snowflake objects. Only create `sql/09_drive_ingestion.sql` and
`evidence/coco_s7_drive_ingestion.md`; delete the downloaded temp copies when done.
