/* ============================================================================
   ARGUS · 08_documents.sql — Document AI: parse circulars + filings,
   extract obligations, Cortex Search, evaluate & load into the twin.
   Created by TCC · CoCo Session S5
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ============================================================================
-- 1. STAGE — internal stage for PDF documents
-- ============================================================================
CREATE STAGE IF NOT EXISTS DOCS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Upload PDFs via CLI before running the rest:
--   snow stage copy policy_corpus/pdf/CBUAE_AML_2024.pdf @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
--   snow stage copy policy_corpus/pdf/FATF_R16_WIRE.pdf  @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
--   snow stage copy policy_corpus/pdf/SAMA_AMLCTF_2023.pdf @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
--   snow stage copy policy_corpus/pdf/CBB_FC_MODULE_2024.pdf @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
--   snow stage copy filings_corpus/pdf/STR-2026-0412_BANK_A.pdf @ARGUS.GOVERNED.DOCS_STAGE/filings/ -c argus --overwrite
--   snow stage copy filings_corpus/pdf/STR-2026-0588_BANK_B.pdf @ARGUS.GOVERNED.DOCS_STAGE/filings/ -c argus --overwrite
--   snow stage copy filings_corpus/pdf/STR-2025-1190_BANK_C.pdf @ARGUS.GOVERNED.DOCS_STAGE/filings/ -c argus --overwrite
--   ALTER STAGE DOCS_STAGE REFRESH;

-- ============================================================================
-- 2. DOCUMENTS — parse each PDF with AI_PARSE_DOCUMENT
-- ============================================================================
CREATE OR REPLACE TABLE documents (
    relative_path STRING,
    doc_type      STRING,   -- 'circular' | 'filing'
    content       STRING,
    parsed_at     TIMESTAMP_NTZ
);

INSERT INTO documents
SELECT
    relative_path,
    CASE WHEN relative_path LIKE 'circulars/%' THEN 'circular' ELSE 'filing' END,
    AI_PARSE_DOCUMENT(
        TO_FILE('@DOCS_STAGE', relative_path),
        {'mode': 'LAYOUT'}
    ):content::STRING,
    CURRENT_TIMESTAMP()
FROM DIRECTORY(@DOCS_STAGE)
WHERE relative_path LIKE '%.pdf';

-- ============================================================================
-- 3. DOCUMENT_CHUNKS — split content for Cortex Search
-- ============================================================================
CREATE OR REPLACE TABLE document_chunks (
    relative_path STRING,
    doc_type      STRING,
    regulator     STRING,
    chunk_index   INT,
    chunk         STRING
);

INSERT INTO document_chunks
SELECT
    d.relative_path,
    d.doc_type,
    CASE
        WHEN d.relative_path ILIKE '%CBUAE%'       THEN 'CBUAE'
        WHEN d.relative_path ILIKE '%FATF%'         THEN 'FATF'
        WHEN d.relative_path ILIKE '%SAMA%'         THEN 'SAMA'
        WHEN d.relative_path ILIKE '%CBB%'          THEN 'CBB'
        WHEN d.relative_path ILIKE '%BANK_A%'       THEN 'Gulf National Bank'
        WHEN d.relative_path ILIKE '%BANK_B%'       THEN 'Levant Commercial'
        WHEN d.relative_path ILIKE '%BANK_C%'       THEN 'Peninsula Finance NBFC'
        ELSE 'UNKNOWN'
    END,
    f.index,
    f.value::STRING
FROM documents d,
LATERAL FLATTEN(
    SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(d.content, 'markdown', 800, 100)
) f;

-- ============================================================================
-- 4. CORTEX SEARCH SERVICE — semantic search over policy & filing chunks
-- ============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE POLICY_SEARCH
    ON chunk
    ATTRIBUTES doc_type, regulator, relative_path
    WAREHOUSE = ARGUS_WH
    TARGET_LAG = '1 day'
AS
    SELECT chunk, doc_type, regulator, relative_path
    FROM document_chunks;

-- ============================================================================
-- 5. EXTRACTED_OBLIGATIONS — AI extraction from circulars (2-arg AI_COMPLETE)
-- ============================================================================
CREATE OR REPLACE TABLE extracted_obligations (
    regulation_id    STRING,
    regulator        STRING,
    title            STRING,
    effective_date   DATE,
    article_ref      STRING,
    clause_text      STRING,
    obligation_text  STRING,
    category         STRING,
    required_scope   STRING,
    source_path      STRING
);

INSERT INTO extracted_obligations
WITH circular_extractions AS (
    SELECT
        d.relative_path AS source_path,
        AI_COMPLETE(
            'claude-sonnet-4-5',
            CONCAT(
                'You are a regulatory compliance analyst. Extract ALL obligations from this regulatory circular.\n',
                'Return ONLY a valid JSON object (no markdown fences, no extra text) with an "obligations" array.\n\n',
                'For each article or section, produce one object with exactly these fields:\n',
                '- regulation_id: the Regulation ID as printed in the document header (e.g. REG-CBUAE-AML-2024)\n',
                '- regulator: the regulator SHORT abbreviation (use exactly: CBUAE, FATF, SAMA, or CBB)\n',
                '- title: the document title from the header\n',
                '- effective_date: effective date in YYYY-MM-DD format, or null if not stated\n',
                '- article_ref: the article/section reference. Use SHORT form: "Art." for Article, "Sec." for Section (e.g. "Art. 15", "Sec. 16.4", "FC-1.5")\n',
                '- clause_text: the full text of the article/section\n',
                '- obligation_text: concise summary of what the institution must do\n',
                '- category: ONLY "AML", "Reporting", or "KYC"\n',
                '- required_scope: MUST be exactly "cross_bank" or "single_bank". Use "cross_bank" when the text says single-institution checks are insufficient, or the requirement is about networks/chains/identifiers/flows spanning institutions. Use "single_bank" otherwise.\n\n',
                'IMPORTANT: Money mule networks that involve fan-in/fan-out from MULTIPLE parties or consolidation of inflows from MANY unrelated sources = "cross_bank" (multiple parties implies cross-institutional visibility needed).\n\n',
                '--- DOCUMENT START ---\n',
                d.content,
                '\n--- DOCUMENT END ---'
            )
        ) AS ai_result
    FROM documents d
    WHERE d.doc_type = 'circular'
)
SELECT
    ob.value:regulation_id::STRING,
    ob.value:regulator::STRING,
    ob.value:title::STRING,
    TRY_TO_DATE(ob.value:effective_date::STRING),
    ob.value:article_ref::STRING,
    ob.value:clause_text::STRING,
    ob.value:obligation_text::STRING,
    ob.value:category::STRING,
    CASE
        WHEN ob.value:required_scope::STRING IN ('cross_bank', 'single_bank')
        THEN ob.value:required_scope::STRING
        WHEN ob.value:required_scope::STRING ILIKE '%cross%' THEN 'cross_bank'
        ELSE 'single_bank'
    END,
    e.source_path
FROM circular_extractions e,
LATERAL FLATTEN(
    PARSE_JSON(REGEXP_REPLACE(e.ai_result, '^```json\\s*|\\s*```$', '')):obligations
) ob;

-- ============================================================================
-- 6. EXTRACTION_EVAL — evaluate against the answer key (seeded twin)
-- ============================================================================
CREATE OR REPLACE TABLE extraction_eval (
    regulation_id   STRING,
    article_ref     STRING,
    found           BOOLEAN,
    scope_expected  STRING,
    scope_extracted STRING,
    scope_match     BOOLEAN,
    status          STRING    -- MATCH | SCOPE_MISMATCH | MISSING
);

INSERT INTO extraction_eval
WITH answer_key AS (
    SELECT c.regulation_id, c.article_ref, o.required_scope,
           c.clause_id, o.obligation_id
    FROM clause c
    JOIN obligation o ON o.clause_id = c.clause_id
    WHERE c.source = 'seed'
)
SELECT
    ak.regulation_id,
    ak.article_ref,
    e.article_ref IS NOT NULL                        AS found,
    ak.required_scope                                AS scope_expected,
    e.required_scope                                 AS scope_extracted,
    e.required_scope = ak.required_scope             AS scope_match,
    CASE
        WHEN e.article_ref IS NULL                   THEN 'MISSING'
        WHEN e.required_scope != ak.required_scope   THEN 'SCOPE_MISMATCH'
        ELSE 'MATCH'
    END                                              AS status
FROM answer_key ak
LEFT JOIN extracted_obligations e
    ON e.regulation_id = ak.regulation_id
   AND UPPER(TRIM(e.article_ref)) = UPPER(TRIM(ak.article_ref));

-- ============================================================================
-- 7. HUMAN-IN-THE-LOOP — AI proposes, human approves
-- ============================================================================

CREATE TABLE IF NOT EXISTS obligation_review_queue (
    regulation_id        STRING,
    article_ref          STRING,
    proposed_clause_text STRING,
    proposed_obligation  STRING,
    proposed_category    STRING,
    proposed_scope       STRING,
    reason               STRING,
    status               STRING DEFAULT 'PENDING_REVIEW'
);

TRUNCATE TABLE IF EXISTS obligation_review_queue;

-- 7a. Update the twin where article AND scope match
UPDATE regulation r
SET r.source = 'cortex_extraction'
FROM extracted_obligations e
JOIN extraction_eval ev
    ON ev.regulation_id = e.regulation_id
   AND UPPER(TRIM(ev.article_ref)) = UPPER(TRIM(e.article_ref))
WHERE ev.status = 'MATCH'
  AND r.regulation_id = e.regulation_id;

UPDATE clause c
SET c.text   = e.clause_text,
    c.source = 'cortex_extraction'
FROM extracted_obligations e
JOIN extraction_eval ev
    ON ev.regulation_id = e.regulation_id
   AND UPPER(TRIM(ev.article_ref)) = UPPER(TRIM(e.article_ref))
WHERE ev.status = 'MATCH'
  AND c.regulation_id = e.regulation_id
  AND UPPER(TRIM(c.article_ref)) = UPPER(TRIM(e.article_ref));

MERGE INTO obligation o
USING (
    SELECT c.clause_id, e.obligation_text AS new_text
    FROM extracted_obligations e
    JOIN extraction_eval ev
        ON ev.regulation_id = e.regulation_id
       AND UPPER(TRIM(ev.article_ref)) = UPPER(TRIM(e.article_ref))
    JOIN clause c
        ON c.regulation_id = e.regulation_id
       AND UPPER(TRIM(c.article_ref)) = UPPER(TRIM(e.article_ref))
    WHERE ev.status = 'MATCH'
) src ON o.clause_id = src.clause_id
WHEN MATCHED THEN UPDATE SET
    o.obligation_text = src.new_text,
    o.source = 'cortex_extraction';

-- 7b. Queue scope mismatches
INSERT INTO obligation_review_queue
    (regulation_id, article_ref, proposed_clause_text, proposed_obligation,
     proposed_category, proposed_scope, reason)
SELECT
    e.regulation_id, e.article_ref, e.clause_text, e.obligation_text,
    e.category, e.required_scope,
    'Scope disagrees: expected ' || ev.scope_expected || ', extracted ' || ev.scope_extracted
FROM extracted_obligations e
JOIN extraction_eval ev
    ON ev.regulation_id = e.regulation_id
   AND UPPER(TRIM(ev.article_ref)) = UPPER(TRIM(e.article_ref))
WHERE ev.status = 'SCOPE_MISMATCH';

-- 7c. Queue novel articles not in the answer key
INSERT INTO obligation_review_queue
    (regulation_id, article_ref, proposed_clause_text, proposed_obligation,
     proposed_category, proposed_scope, reason)
SELECT
    e.regulation_id, e.article_ref, e.clause_text, e.obligation_text,
    e.category, e.required_scope,
    'Extracted article not in answer key'
FROM extracted_obligations e
LEFT JOIN clause c
    ON c.regulation_id = e.regulation_id
   AND UPPER(TRIM(c.article_ref)) = UPPER(TRIM(e.article_ref))
WHERE c.clause_id IS NULL;

-- ============================================================================
-- 8. PAST_FILINGS — extract structured data from STR filings
-- ============================================================================
CREATE OR REPLACE TABLE past_filings (
    filing_id                    STRING,
    institution                  STRING,
    regulator                    STRING,
    fiu                          STRING,
    filed_on                     DATE,
    typology                     STRING,
    status                       STRING,
    cross_institution_limitation BOOLEAN
);

INSERT INTO past_filings
WITH filing_extractions AS (
    SELECT
        AI_COMPLETE(
            'claude-sonnet-4-5',
            CONCAT(
                'Extract the following fields from this Suspicious Transaction Report.\n',
                'Return ONLY a valid JSON object (no markdown fences, no extra text) with these fields:\n',
                '- filing_id: the STR reference number (e.g. STR-2026-0412)\n',
                '- institution: the filing institution name and bank code in parentheses (e.g. "Gulf National Bank (BANK_A)")\n',
                '- regulator: the regulator abbreviation (CBUAE, SAMA, or CBB)\n',
                '- fiu: the Financial Intelligence Unit the STR was filed with (full name)\n',
                '- filed_on: the filing date in YYYY-MM-DD format\n',
                '- typology: the suspected typology or crime type\n',
                '- status: current status of the filing\n',
                '- cross_institution_limitation: true if the investigator noted limitations due to inability to see across institutions or other banks, false otherwise\n\n',
                '--- REPORT START ---\n',
                d.content,
                '\n--- REPORT END ---'
            )
        ) AS ai_result
    FROM documents d
    WHERE d.doc_type = 'filing'
)
SELECT
    j:filing_id::STRING,
    j:institution::STRING,
    j:regulator::STRING,
    j:fiu::STRING,
    TRY_TO_DATE(j:filed_on::STRING),
    j:typology::STRING,
    j:status::STRING,
    j:cross_institution_limitation::BOOLEAN
FROM filing_extractions,
LATERAL (SELECT PARSE_JSON(REGEXP_REPLACE(ai_result, '^```json\\s*|\\s*```$', '')) AS j);
