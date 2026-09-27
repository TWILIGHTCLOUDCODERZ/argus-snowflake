/* ============================================================================
   ARGUS · 09_drive_ingestion.sql — Google Drive → Snowflake document pipeline.
   Downloads PDFs from the "ARGUS Policy Corpus" Drive folder, compares MD5
   with the stage, uploads only new/changed files, and re-parses them.
   Created by TCC · CoCo Session S7
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ============================================================================
-- 1. DOC_INGEST_LOG — tracks every Drive sync run
-- ============================================================================
CREATE TABLE IF NOT EXISTS DOC_INGEST_LOG (
    drive_file_id       STRING,
    file_name           STRING,
    doc_type            STRING,      -- 'circular' | 'filing'
    drive_modified_time TIMESTAMP_NTZ,
    md5                 STRING,
    stage_path          STRING,
    action              STRING,      -- 'UNCHANGED' | 'INGESTED' | 'UPDATED'
    ingested_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================================
-- 2. ALTER DOCUMENTS — add Drive lineage columns (idempotent)
-- ============================================================================
ALTER TABLE DOCUMENTS ADD COLUMN IF NOT EXISTS drive_file_id STRING;
ALTER TABLE DOCUMENTS ADD COLUMN IF NOT EXISTS source_uri    STRING;

-- ============================================================================
-- 3. LINEAGE UPDATE — after syncing, join ingest log to documents
--    Run this after every sync to stamp Drive provenance on parsed docs.
-- ============================================================================
-- Template: adjust WHERE clause to limit to the current sync batch.
/*
UPDATE DOCUMENTS d
SET d.drive_file_id = l.drive_file_id,
    d.source_uri    = 'gdrive://ARGUS Policy Corpus/' || l.file_name
FROM DOC_INGEST_LOG l
WHERE d.relative_path = l.stage_path
  AND d.drive_file_id IS NULL;
*/

-- ============================================================================
-- 4. RE-PARSE TEMPLATE — for changed/new files only
--    Replace <STAGE_PATH> with the file's relative_path (e.g. circulars/X.pdf).
-- ============================================================================
/*
-- 4a. Delete old rows for the changed file
DELETE FROM DOCUMENT_CHUNKS WHERE relative_path = '<STAGE_PATH>';
DELETE FROM DOCUMENTS       WHERE relative_path = '<STAGE_PATH>';

-- 4b. Re-parse the PDF
INSERT INTO DOCUMENTS (relative_path, doc_type, content, parsed_at)
SELECT
    '<STAGE_PATH>',
    CASE WHEN '<STAGE_PATH>' LIKE 'circulars/%' THEN 'circular' ELSE 'filing' END,
    AI_PARSE_DOCUMENT(
        TO_FILE('@DOCS_STAGE', '<STAGE_PATH>'),
        {'mode': 'LAYOUT'}
    ):content::STRING,
    CURRENT_TIMESTAMP();

-- 4c. Re-chunk
INSERT INTO DOCUMENT_CHUNKS (relative_path, doc_type, regulator, chunk_index, chunk)
SELECT
    d.relative_path,
    d.doc_type,
    CASE
        WHEN d.relative_path ILIKE '%CBUAE%'  THEN 'CBUAE'
        WHEN d.relative_path ILIKE '%FATF%'   THEN 'FATF'
        WHEN d.relative_path ILIKE '%SAMA%'   THEN 'SAMA'
        WHEN d.relative_path ILIKE '%CBB%'    THEN 'CBB'
        WHEN d.relative_path ILIKE '%BANK_A%' THEN 'Gulf National Bank'
        WHEN d.relative_path ILIKE '%BANK_B%' THEN 'Levant Commercial'
        WHEN d.relative_path ILIKE '%BANK_C%' THEN 'Peninsula Finance NBFC'
        ELSE 'UNKNOWN'
    END,
    f.index,
    f.value::STRING
FROM DOCUMENTS d,
LATERAL FLATTEN(
    SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(d.content, 'markdown', 800, 100)
) f
WHERE d.relative_path = '<STAGE_PATH>';

-- 4d. Stamp lineage on the new row
UPDATE DOCUMENTS
SET drive_file_id = '<DRIVE_FILE_ID>',
    source_uri    = 'gdrive://ARGUS Policy Corpus/<FILE_NAME>'
WHERE relative_path = '<STAGE_PATH>';
*/

-- ============================================================================
-- 5. STAGE UPLOAD (CLI) — template for uploading a changed file
-- ============================================================================
-- For circulars:
--   snow stage copy "<local_path>" @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
-- For filings:
--   snow stage copy "<local_path>" @ARGUS.GOVERNED.DOCS_STAGE/filings/   -c argus --overwrite
-- Then: ALTER STAGE DOCS_STAGE REFRESH;
