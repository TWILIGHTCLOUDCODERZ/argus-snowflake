/* ============================================================================
   ARGUS · 05_regulatory_twin.sql — Living Regulatory Digital Twin.
   Created by TCC · Week 2

   regulation -> clause -> obligation -> control  (+ lineage, + typology links)
   Seed mirrors data/twin_seed.json (single source of truth). In production the
   regulation/clause rows are extracted by CoCo + Cortex from circulars pulled
   through the Google Drive MCP connector (policy_corpus/*.md stands in here).

   Run 05 BEFORE 03 (the reg-twin semantic view reads these tables).
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- `source` records provenance: 'seed' (loaded from twin_seed.json) or
-- 'cortex_extraction' (parsed from the circular PDFs by Cortex — see 08_documents.sql).
CREATE OR REPLACE TABLE regulation (
    regulation_id STRING, regulator STRING, title STRING,
    effective_date DATE, source_uri STRING, source STRING DEFAULT 'seed'
);
CREATE OR REPLACE TABLE clause (
    clause_id STRING, regulation_id STRING, article_ref STRING, text STRING,
    source STRING DEFAULT 'seed'
);
CREATE OR REPLACE TABLE obligation (
    obligation_id STRING, clause_id STRING, obligation_text STRING,
    category STRING, required_scope STRING,         -- single_bank | cross_bank
    source STRING DEFAULT 'seed'
);
CREATE OR REPLACE TABLE control (
    control_id STRING, name STRING, description STRING,
    coverage_scope STRING,                          -- single_bank | cross_bank
    owner STRING, status STRING                     -- active | not_deployed
);
CREATE OR REPLACE TABLE control_obligation   (control_id STRING, obligation_id STRING);
CREATE OR REPLACE TABLE control_data_lineage (control_id STRING, data_object STRING, semantic_view STRING);
CREATE OR REPLACE TABLE typology_obligation  (typology_id STRING, obligation_id STRING);

-- ---------------------------------------------------------------------------
-- Seed: loaded straight from data/twin_seed.json on the stage — ONE source of
-- truth, no hand-copied rows to drift. Upload it first:
--   snow stage copy data/twin_seed.json @ARGUS.RAW.ARGUS_STAGE -c argus --overwrite
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT ARGUS.RAW.ARGUS_JSON TYPE = JSON;

CREATE OR REPLACE TEMPORARY TABLE _seed AS
SELECT $1 AS doc FROM @ARGUS.RAW.ARGUS_STAGE/twin_seed.json (FILE_FORMAT => 'ARGUS.RAW.ARGUS_JSON');

INSERT INTO regulation (regulation_id, regulator, title, effective_date, source_uri)
SELECT f.value:regulation_id::STRING, f.value:regulator::STRING, f.value:title::STRING, f.value:effective_date::DATE, f.value:source_uri::STRING
FROM _seed, LATERAL FLATTEN(doc:regulations) f;

INSERT INTO clause (clause_id, regulation_id, article_ref, text)
SELECT f.value:clause_id::STRING, f.value:regulation_id::STRING, f.value:article_ref::STRING, f.value:text::STRING
FROM _seed, LATERAL FLATTEN(doc:clauses) f;

INSERT INTO obligation (obligation_id, clause_id, obligation_text, category, required_scope)
SELECT f.value:obligation_id::STRING, f.value:clause_id::STRING, f.value:obligation_text::STRING, f.value:category::STRING, f.value:required_scope::STRING
FROM _seed, LATERAL FLATTEN(doc:obligations) f;

INSERT INTO control
SELECT f.value:control_id::STRING, f.value:name::STRING, f.value:description::STRING, f.value:coverage_scope::STRING, f.value:owner::STRING, f.value:status::STRING
FROM _seed, LATERAL FLATTEN(doc:controls) f;

INSERT INTO control_obligation
SELECT f.value:control_id::STRING, f.value:obligation_id::STRING FROM _seed, LATERAL FLATTEN(doc:control_obligation) f;

INSERT INTO control_data_lineage
SELECT f.value:control_id::STRING, f.value:data_object::STRING, f.value:semantic_view::STRING
FROM _seed, LATERAL FLATTEN(doc:control_data_lineage) f;

INSERT INTO typology_obligation
SELECT f.value:typology_id::STRING, f.value:obligation_id::STRING FROM _seed, LATERAL FLATTEN(doc:typology_obligation) f;

-- ---------------------------------------------------------------------------
-- CONTROL GAP — the core Twin computation.
-- An obligation is covered only by an ACTIVE control whose coverage_scope meets
-- the obligation's required_scope (a single-bank control cannot satisfy a
-- cross-bank obligation — that is exactly the blind spot ARGUS exposes).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW control_gap AS
SELECT
    o.obligation_id,
    o.obligation_text,
    o.required_scope,
    cl.article_ref,
    r.regulator,
    COUNT_IF(c.status = 'active'
             AND (o.required_scope = 'single_bank' OR c.coverage_scope = 'cross_bank')) = 0
        AS is_gap,
    IFF(is_gap, IFF(o.required_scope = 'cross_bank', 'HIGH', 'MEDIUM'), 'NONE') AS severity,
    LISTAGG(c.control_id || ' (' || c.coverage_scope || ', ' || c.status || ')', '; ')
        WITHIN GROUP (ORDER BY c.control_id) AS mapped_controls,
    IFF(is_gap,
        'No active control with ' || o.required_scope || ' coverage. Mapped: '
          || COALESCE(mapped_controls, 'none'),
        'Covered by an active, adequately-scoped control.') AS rationale
FROM obligation o
JOIN clause cl     ON cl.clause_id = o.clause_id
JOIN regulation r  ON r.regulation_id = cl.regulation_id
LEFT JOIN control_obligation co ON co.obligation_id = o.obligation_id
LEFT JOIN control c             ON c.control_id = co.control_id
GROUP BY o.obligation_id, o.obligation_text, o.required_scope, cl.article_ref, r.regulator;

-- ---------------------------------------------------------------------------
-- TYPOLOGY EXPOSURE — the correlation loop: fraud typology -> obligation -> gap.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW typology_exposure AS
SELECT t.typology_id, g.obligation_id, g.obligation_text, g.regulator, g.article_ref,
       g.is_gap, g.severity, g.rationale
FROM typology_obligation t
JOIN control_gap g ON g.obligation_id = t.obligation_id;

-- Typology evidence (membership) is written by the Typology agent in Week 3.
CREATE TABLE IF NOT EXISTS typology_evidence (
    typology_id STRING, entity_type STRING, entity_id STRING, role STRING, bank_id STRING
);
