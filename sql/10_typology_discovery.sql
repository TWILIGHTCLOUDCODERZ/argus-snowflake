/* ============================================================================
   ARGUS · 10_typology_discovery.sql — Typology Discovery Engine
   Created by TCC · CoCo Session S8

   Graph expansion from seed signals → communities → roles → TYPOLOGY +
   TYPOLOGY_EVIDENCE + plain-English typology cards + detection queries.
   Class-based twin mapping: TYPOLOGY_CLASS + TYPOLOGY_CLASS_OBLIGATION
   replace the old RING-keyed TYPOLOGY_OBLIGATION table.

   Run AFTER 05_regulatory_twin.sql and 06_pipelines.sql.
   ============================================================================ */

USE DATABASE ARGUS;

-- =========================================================================
-- 1. TYPOLOGY table — discovered typologies
-- =========================================================================
CREATE TABLE IF NOT EXISTS ARGUS.GOVERNED.TYPOLOGY (
    typology_id       STRING,
    typology_class    STRING,
    name              STRING,
    banks_involved    ARRAY,
    member_count      NUMBER,
    first_seen        TIMESTAMP_NTZ,
    last_seen         TIMESTAMP_NTZ,
    total_value       NUMBER(18,2),
    confidence        NUMBER(3,2),
    detection_sql     STRING,
    card_md           STRING,
    status            STRING DEFAULT 'DISCOVERED',
    discovered_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =========================================================================
-- 2. TYPOLOGY_CLASS + TYPOLOGY_CLASS_OBLIGATION (from twin_seed.json)
-- =========================================================================
CREATE TABLE IF NOT EXISTS ARGUS.GOVERNED.TYPOLOGY_CLASS (
    typology_class STRING,
    name           STRING,
    description    STRING
);

CREATE TABLE IF NOT EXISTS ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION (
    typology_class STRING,
    obligation_id  STRING
);

-- Load from stage (idempotent: truncate first)
TRUNCATE TABLE IF EXISTS ARGUS.GOVERNED.TYPOLOGY_CLASS;
TRUNCATE TABLE IF EXISTS ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION;

CREATE OR REPLACE TEMPORARY TABLE _seed_json AS
SELECT $1 AS doc
FROM @ARGUS.RAW.ARGUS_STAGE/twin_seed.json (FILE_FORMAT => 'ARGUS.RAW.ARGUS_JSON');

INSERT INTO ARGUS.GOVERNED.TYPOLOGY_CLASS (typology_class, name, description)
SELECT f.value:typology_class::STRING,
       f.value:name::STRING,
       f.value:description::STRING
FROM _seed_json, LATERAL FLATTEN(doc:typology_classes) f;

INSERT INTO ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION (typology_class, obligation_id)
SELECT f.value:typology_class::STRING,
       f.value:obligation_id::STRING
FROM _seed_json, LATERAL FLATTEN(doc:typology_class_obligation) f;

-- Clear old RING-keyed typology_obligation (answer-key IDs must not live in governed data)
TRUNCATE TABLE IF EXISTS ARGUS.GOVERNED.TYPOLOGY_OBLIGATION;

-- =========================================================================
-- 3. Redefine TYPOLOGY_EXPOSURE — class-based (discovered → class → obligation → gap)
-- =========================================================================
CREATE OR REPLACE VIEW ARGUS.GOVERNED.TYPOLOGY_EXPOSURE AS
SELECT t.typology_id,
       g.obligation_id,
       g.obligation_text,
       g.regulator,
       g.article_ref,
       g.is_gap,
       g.severity,
       g.rationale
FROM ARGUS.GOVERNED.TYPOLOGY t
JOIN ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION tco ON tco.typology_class = t.typology_class
JOIN ARGUS.GOVERNED.CONTROL_GAP g ON g.obligation_id = tco.obligation_id;

GRANT SELECT ON VIEW ARGUS.GOVERNED.TYPOLOGY_EXPOSURE TO ROLE ARGUS_ANALYST;

-- =========================================================================
-- 4. SP_DISCOVER_TYPOLOGIES — the core graph algorithm
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES()
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    -- =================================================================
    -- STEP 1: Transfer edges (intra + inter-bank within consortium)
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _transfer_edges AS
    SELECT t.txn_id,
           t.account_id   AS from_account,
           t.bank_id      AS from_bank,
           a.account_id   AS to_account,
           a.bank_id      AS to_bank,
           t.amount,
           t.ts
    FROM ARGUS.RAW.TRANSACTIONS t
    JOIN ARGUS.RAW.ACCOUNTS a ON a.iban = t.counterparty_iban
    WHERE t.direction = 'debit'
      AND t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
      AND t.amount >= 10000;

    -- =================================================================
    -- STEP 2: Seeds
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _seeds AS
    SELECT account_id, bank_id,
           MIN(window_start) AS window_start,
           MAX(window_end)   AS window_end,
           LISTAGG(DISTINCT seed_type, ',') WITHIN GROUP (ORDER BY seed_type) AS seed_types
    FROM (
        -- Hub accounts
        SELECT account_id, bank_id, burst_start AS window_start, burst_end AS window_end, 'hub' AS seed_type
        FROM ARGUS.CURATED.DT_HUB_ACCOUNTS

        UNION ALL
        -- Structuring
        SELECT account_id, bank_id, first_deposit, last_deposit, 'structuring'
        FROM ARGUS.CURATED.DT_STRUCTURING

        UNION ALL
        -- Shared national_id at >=2 banks
        SELECT DISTINCT e.account_id, e.bank_id,
               ts_range.mn AS window_start,
               ts_range.mx AS window_end,
               'shared_identity' AS seed_type
        FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e
        JOIN ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL s
          ON s.identifier_hash = e.identifier_hash AND s.identifier_type = e.identifier_type
        JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) ts_range
          ON ts_range.account_id = e.account_id
        WHERE s.identifier_type = 'national_id'
          AND s.contributing_bank_count >= 2

        UNION ALL
        -- Cross-bank edge participants (captures circular layering)
        SELECT cb.account_id, cb.bank_id,
               MIN(cb.ts) AS window_start,
               MAX(cb.ts) AS window_end,
               'cross_bank_edge' AS seed_type
        FROM (
            SELECT from_account AS account_id, from_bank AS bank_id, ts
            FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES
            UNION ALL
            SELECT to_account, to_bank, ts
            FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES
        ) cb
        GROUP BY cb.account_id, cb.bank_id

        UNION ALL
        -- Open LIVE_ALERTS
        SELECT account_id, bank_id, first_seen, last_seen, 'alert'
        FROM ARGUS.GOVERNED.LIVE_ALERTS
        WHERE status = 'OPEN'
    ) raw_seeds
    GROUP BY account_id, bank_id;

    -- =================================================================
    -- STEP 3: BFS expansion (2 hops from seeds via transfer edges)
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _community (
        account_id   STRING,
        bank_id      STRING,
        window_start TIMESTAMP_NTZ,
        window_end   TIMESTAMP_NTZ,
        hop          INT
    );

    -- Hop 0: seeds
    INSERT INTO _community
    SELECT account_id, bank_id, window_start, window_end, 0 FROM _seeds;

    -- Hop 1 forward (community node is sender)
    INSERT INTO _community
    SELECT DISTINCT e.to_account, e.to_bank,
           LEAST(c.window_start, e.ts),
           GREATEST(c.window_end, e.ts),
           1
    FROM _community c
    JOIN _transfer_edges e ON e.from_account = c.account_id
    WHERE c.hop = 0
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.to_account NOT IN (SELECT account_id FROM _community);

    -- Hop 1 backward (community node is receiver)
    INSERT INTO _community
    SELECT DISTINCT e.from_account, e.from_bank,
           LEAST(c.window_start, e.ts),
           GREATEST(c.window_end, e.ts),
           1
    FROM _community c
    JOIN _transfer_edges e ON e.to_account = c.account_id
    WHERE c.hop = 0
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.from_account NOT IN (SELECT account_id FROM _community);

    -- Hop 2 forward (from hop-1 nodes)
    INSERT INTO _community
    SELECT DISTINCT e.to_account, e.to_bank,
           LEAST(c.window_start, e.ts),
           GREATEST(c.window_end, e.ts),
           2
    FROM _community c
    JOIN _transfer_edges e ON e.from_account = c.account_id
    WHERE c.hop = 1
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.to_account NOT IN (SELECT account_id FROM _community);

    -- Hop 2 backward (from hop-1 nodes)
    INSERT INTO _community
    SELECT DISTINCT e.from_account, e.from_bank,
           LEAST(c.window_start, e.ts),
           GREATEST(c.window_end, e.ts),
           2
    FROM _community c
    JOIN _transfer_edges e ON e.to_account = c.account_id
    WHERE c.hop = 1
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.from_account NOT IN (SELECT account_id FROM _community);

    -- =================================================================
    -- STEP 4: Identity expansion
    -- =================================================================

    -- National-ID links: auto-join across banks
    INSERT INTO _community
    SELECT DISTINCT e2.account_id, e2.bank_id,
           ts_range.mn, ts_range.mx, -1
    FROM _community c
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c.account_id AND e1.identifier_type = 'national_id'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash AND e2.identifier_type = 'national_id'
      AND e2.bank_id <> e1.bank_id
    JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) ts_range
      ON ts_range.account_id = e2.account_id
    WHERE e2.account_id NOT IN (SELECT account_id FROM _community);

    -- Device links: join ONLY if the account also has a transfer edge to a community member
    INSERT INTO _community
    SELECT DISTINCT e2.account_id, e2.bank_id,
           ts_range.mn, ts_range.mx, -2
    FROM _community c
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c.account_id AND e1.identifier_type = 'device'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash AND e2.identifier_type = 'device'
      AND e2.bank_id <> e1.bank_id
    JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) ts_range
      ON ts_range.account_id = e2.account_id
    WHERE e2.account_id NOT IN (SELECT account_id FROM _community)
      AND (   e2.account_id IN (SELECT from_account FROM _transfer_edges WHERE to_account IN (SELECT account_id FROM _community))
           OR e2.account_id IN (SELECT to_account FROM _transfer_edges WHERE from_account IN (SELECT account_id FROM _community))
          );

    -- Deduplicate community (keep earliest hop)
    CREATE OR REPLACE TEMPORARY TABLE _community_dedup AS
    SELECT account_id, bank_id,
           MIN(window_start) AS window_start,
           MAX(window_end) AS window_end,
           MIN(hop) AS hop
    FROM _community
    GROUP BY account_id, bank_id;

    DROP TABLE _community;
    ALTER TABLE _community_dedup RENAME TO _community;

    -- =================================================================
    -- STEP 5: Community edges (transfer + identity, between members only)
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _community_edges AS
    -- Transfer edges (directed, but label propagation treats them as undirected)
    SELECT DISTINCT e.from_account AS node_a, e.to_account AS node_b
    FROM _transfer_edges e
    WHERE e.from_account IN (SELECT account_id FROM _community)
      AND e.to_account IN (SELECT account_id FROM _community)

    UNION

    -- National-ID links between community members (undirected)
    SELECT DISTINCT LEAST(e1.account_id, e2.account_id),
                    GREATEST(e1.account_id, e2.account_id)
    FROM _community c1
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c1.account_id AND e1.identifier_type = 'national_id'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash AND e2.identifier_type = 'national_id'
      AND e2.account_id <> e1.account_id
    JOIN _community c2 ON c2.account_id = e2.account_id

    UNION

    -- Device links between community members (already filtered)
    SELECT DISTINCT LEAST(e1.account_id, e2.account_id),
                    GREATEST(e1.account_id, e2.account_id)
    FROM _community c1
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c1.account_id AND e1.identifier_type = 'device'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash AND e2.identifier_type = 'device'
      AND e2.account_id <> e1.account_id
    JOIN _community c2 ON c2.account_id = e2.account_id;

    -- =================================================================
    -- STEP 6: Connected components (iterative label propagation)
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _labels (
        node  STRING,
        label STRING
    );

    INSERT INTO _labels
    SELECT DISTINCT account_id, account_id FROM _community;

    LET v_changed INT := 1;
    WHILE (:v_changed > 0) DO
        UPDATE _labels tgt
        SET label = src.new_label
        FROM (
            SELECT l1.node, MIN(l2.label) AS new_label
            FROM _labels l1
            JOIN _community_edges e
              ON e.node_a = l1.node OR e.node_b = l1.node
            JOIN _labels l2
              ON l2.node = IFF(e.node_a = l1.node, e.node_b, e.node_a)
            WHERE l2.label < l1.label
            GROUP BY l1.node
        ) src
        WHERE tgt.node = src.node AND src.new_label < tgt.label;

        v_changed := SQLROWCOUNT;
    END WHILE;

    -- =================================================================
    -- STEP 7: Role assignment
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _cross_bank_te AS
    SELECT * FROM _transfer_edges
    WHERE from_account IN (SELECT account_id FROM _community)
      AND to_account IN (SELECT account_id FROM _community)
      AND from_bank <> to_bank;

    CREATE OR REPLACE TEMPORARY TABLE _same_bank_te AS
    SELECT * FROM _transfer_edges
    WHERE from_account IN (SELECT account_id FROM _community)
      AND to_account IN (SELECT account_id FROM _community)
      AND from_bank = to_bank;

    -- Consolidation: receives cross-bank from >=2 other banks
    CREATE OR REPLACE TEMPORARY TABLE _consolidation AS
    SELECT to_account AS account_id
    FROM _cross_bank_te
    GROUP BY to_account
    HAVING COUNT(DISTINCT from_bank) >= 2;

    -- Funnel: receives same-bank AND sends cross-bank
    CREATE OR REPLACE TEMPORARY TABLE _funnel AS
    SELECT DISTINCT s.to_account AS account_id
    FROM _same_bank_te s
    WHERE s.to_account IN (SELECT from_account FROM _cross_bank_te)
      AND s.to_account NOT IN (SELECT account_id FROM _consolidation);

    -- Source mule: sends same-bank to funnel/consolidation, no cross-bank activity
    CREATE OR REPLACE TEMPORARY TABLE _source_mule AS
    SELECT DISTINCT s.from_account AS account_id
    FROM _same_bank_te s
    WHERE s.from_account NOT IN (SELECT from_account FROM _cross_bank_te)
      AND s.from_account NOT IN (SELECT to_account FROM _cross_bank_te)
      AND (   s.to_account IN (SELECT account_id FROM _funnel)
           OR s.to_account IN (SELECT account_id FROM _consolidation)
          );

    -- Layering hop: part of a cross-bank cycle (A→B→C→A)
    CREATE OR REPLACE TEMPORARY TABLE _layering AS
    SELECT DISTINCT val AS account_id
    FROM (
        SELECT e1.from_account AS val
        FROM _cross_bank_te e1
        JOIN _cross_bank_te e2 ON e2.from_account = e1.to_account
        JOIN _cross_bank_te e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
        UNION
        SELECT e2.from_account
        FROM _cross_bank_te e1
        JOIN _cross_bank_te e2 ON e2.from_account = e1.to_account
        JOIN _cross_bank_te e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
        UNION
        SELECT e3.from_account
        FROM _cross_bank_te e1
        JOIN _cross_bank_te e2 ON e2.from_account = e1.to_account
        JOIN _cross_bank_te e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
    );

    -- Structuring
    CREATE OR REPLACE TEMPORARY TABLE _structuring AS
    SELECT account_id FROM ARGUS.CURATED.DT_STRUCTURING
    WHERE account_id IN (SELECT account_id FROM _community);

    -- Shared identity (national_id across banks, within community)
    CREATE OR REPLACE TEMPORARY TABLE _shared_identity AS
    SELECT DISTINCT e1.account_id
    FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
    WHERE e1.account_id IN (SELECT account_id FROM _community)
      AND e1.identifier_type = 'national_id'
      AND EXISTS (
          SELECT 1 FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
          WHERE e2.identifier_hash = e1.identifier_hash
            AND e2.identifier_type = 'national_id'
            AND e2.bank_id <> e1.bank_id
            AND e2.account_id IN (SELECT account_id FROM _community)
      );

    -- Combine roles
    CREATE OR REPLACE TEMPORARY TABLE _node_roles AS
    SELECT c.account_id,
           c.bank_id,
           CASE
               WHEN c.account_id IN (SELECT account_id FROM _consolidation) THEN 'consolidation'
               WHEN c.account_id IN (SELECT account_id FROM _funnel)        THEN 'funnel'
               WHEN c.account_id IN (SELECT account_id FROM _source_mule)   THEN 'source_mule'
               WHEN c.account_id IN (SELECT account_id FROM _layering)      THEN 'layering_hop'
               WHEN c.account_id IN (SELECT account_id FROM _structuring)   THEN 'structuring'
               WHEN c.account_id IN (SELECT account_id FROM _shared_identity) THEN 'shared_identity'
               ELSE 'member'
           END AS role,
           l.label AS component_id
    FROM _community c
    JOIN _labels l ON l.node = c.account_id;

    -- =================================================================
    -- STEP 8: Classify components
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _component_class AS
    SELECT component_id,
           CASE
               WHEN SUM(IFF(role IN ('consolidation','funnel','source_mule'), 1, 0)) > 0
                    THEN 'FAN_IN_FAN_OUT_MULE'
               WHEN SUM(IFF(role = 'layering_hop', 1, 0)) > 0
                    THEN 'CIRCULAR_LAYERING'
               WHEN SUM(IFF(role = 'shared_identity', 1, 0)) > 0
                    THEN 'SHARED_IDENTITY'
               WHEN SUM(IFF(role = 'structuring', 1, 0)) > 0
                    THEN 'CASH_STRUCTURING'
               ELSE 'UNKNOWN'
           END AS typology_class
    FROM _node_roles
    GROUP BY component_id;

    -- =================================================================
    -- STEP 9: Compute component stats
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _component_stats AS
    SELECT nr.component_id,
           cc.typology_class,
           ARRAY_AGG(DISTINCT nr.bank_id) AS banks_involved,
           COUNT(DISTINCT nr.account_id)  AS member_count,
           MIN(c.window_start)            AS first_seen,
           MAX(c.window_end)              AS last_seen
    FROM _node_roles nr
    JOIN _component_class cc ON cc.component_id = nr.component_id
    JOIN _community c ON c.account_id = nr.account_id
    GROUP BY nr.component_id, cc.typology_class;

    -- Total value per component (sum of transfer edge amounts within each component)
    CREATE OR REPLACE TEMPORARY TABLE _component_value AS
    SELECT l1.label AS component_id,
           SUM(e.amount) AS total_value
    FROM _transfer_edges e
    JOIN _labels l1 ON l1.node = e.from_account
    JOIN _labels l2 ON l2.node = e.to_account
    WHERE l1.label = l2.label
    GROUP BY l1.label;

    -- =================================================================
    -- STEP 10: Assign typology IDs and generate outputs
    -- =================================================================

    -- Number the components
    CREATE OR REPLACE TEMPORARY TABLE _typology_map AS
    SELECT cs.component_id,
           'TYP-' || LPAD(ROW_NUMBER() OVER (ORDER BY cs.component_id)::STRING, 4, '0') AS typology_id,
           cs.typology_class,
           tc.name AS class_name,
           cs.banks_involved,
           cs.member_count,
           cs.first_seen,
           cs.last_seen,
           COALESCE(cv.total_value, 0) AS total_value
    FROM _component_stats cs
    LEFT JOIN _component_value cv ON cv.component_id = cs.component_id
    LEFT JOIN ARGUS.GOVERNED.TYPOLOGY_CLASS tc ON tc.typology_class = cs.typology_class;

    -- Confidence: multi-signal = higher
    CREATE OR REPLACE TEMPORARY TABLE _confidence AS
    SELECT tm.component_id,
           CASE
               WHEN tm.member_count >= 10 AND ARRAY_SIZE(tm.banks_involved) >= 3 THEN 0.95
               WHEN tm.member_count >= 3  AND ARRAY_SIZE(tm.banks_involved) >= 2 THEN 0.90
               WHEN tm.member_count >= 3  THEN 0.85
               WHEN tm.member_count >= 2  THEN 0.80
               ELSE 0.75
           END AS confidence
    FROM _typology_map tm;

    -- =================================================================
    -- STEP 11: Detection SQL per typology
    -- =================================================================
    CREATE OR REPLACE TEMPORARY TABLE _detection_sql AS
    SELECT tm.component_id,
           CASE tm.typology_class
               WHEN 'FAN_IN_FAN_OUT_MULE' THEN
                   'WITH consol AS (SELECT account_id, bank_id FROM ARGUS.CURATED.DT_HUB_ACCOUNTS WHERE account_id IN ('
                   || (SELECT LISTAGG('''' || nr.account_id || '''', ',') WITHIN GROUP (ORDER BY nr.account_id)
                       FROM _node_roles nr WHERE nr.component_id = tm.component_id AND nr.role = 'consolidation')
                   || ')), funnels AS (SELECT DISTINCT t.account_id FROM ARGUS.RAW.TRANSACTIONS t '
                   || 'JOIN ARGUS.RAW.ACCOUNTS a ON a.iban = t.counterparty_iban '
                   || 'WHERE t.direction = ''debit'' AND a.account_id IN (SELECT account_id FROM consol) '
                   || 'AND t.counterparty_bank IN (''BANK_A'',''BANK_B'',''BANK_C'') AND t.amount >= 10000), '
                   || 'mules AS (SELECT DISTINCT t.account_id FROM ARGUS.RAW.TRANSACTIONS t '
                   || 'JOIN ARGUS.RAW.ACCOUNTS a ON a.iban = t.counterparty_iban '
                   || 'WHERE t.direction = ''debit'' AND t.amount >= 10000 '
                   || 'AND a.account_id IN (SELECT account_id FROM funnels UNION SELECT account_id FROM consol) '
                   || 'AND t.bank_id = a.bank_id) '
                   || 'SELECT ''consolidation'' AS role, account_id FROM consol '
                   || 'UNION ALL SELECT ''funnel'', account_id FROM funnels '
                   || 'UNION ALL SELECT ''source_mule'', account_id FROM mules'

               WHEN 'CIRCULAR_LAYERING' THEN
                   'SELECT DISTINCT val AS account_id, ''layering_hop'' AS role FROM ('
                   || 'SELECT e1.from_account AS val FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES e1 '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e2 ON e2.from_account = e1.to_account '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account '
                   || 'WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank '
                   || 'UNION SELECT e2.from_account FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES e1 '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e2 ON e2.from_account = e1.to_account '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account '
                   || 'WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank '
                   || 'UNION SELECT e3.from_account FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES e1 '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e2 ON e2.from_account = e1.to_account '
                   || 'JOIN ARGUS.CURATED.DT_CROSS_BANK_EDGES e3 ON e3.from_account = e2.to_account AND e3.to_account = e1.from_account '
                   || 'WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank)'

               WHEN 'SHARED_IDENTITY' THEN
                   'SELECT DISTINCT e.account_id, ''shared_identity'' AS role '
                   || 'FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e '
                   || 'WHERE e.identifier_type = ''national_id'' AND e.identifier_hash IN ('
                   || (SELECT LISTAGG(DISTINCT '''' || e1.identifier_hash || '''', ',') WITHIN GROUP (ORDER BY e1.identifier_hash)
                       FROM _community cm
                       JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
                         ON e1.account_id = cm.account_id AND e1.identifier_type = 'national_id'
                       JOIN _labels lb ON lb.node = cm.account_id
                       WHERE lb.label = tm.component_id)
                   || ')'

               WHEN 'CASH_STRUCTURING' THEN
                   'SELECT account_id, ''structuring'' AS role FROM ARGUS.CURATED.DT_STRUCTURING '
                   || 'WHERE account_id IN ('
                   || (SELECT LISTAGG('''' || nr.account_id || '''', ',') WITHIN GROUP (ORDER BY nr.account_id)
                       FROM _node_roles nr WHERE nr.component_id = tm.component_id AND nr.role = 'structuring')
                   || ')'

               ELSE 'SELECT ''no detection query'' AS info'
           END AS detection_sql
    FROM _typology_map tm;

    -- =================================================================
    -- STEP 12: Write TYPOLOGY and TYPOLOGY_EVIDENCE
    -- =================================================================

    -- Remove previous discovered rows
    DELETE FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED';
    DELETE FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
    WHERE typology_id IN (SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED')
       OR typology_id LIKE 'TYP-%';

    -- Insert typologies (without card_md for now — generated next)
    INSERT INTO ARGUS.GOVERNED.TYPOLOGY
        (typology_id, typology_class, name, banks_involved, member_count,
         first_seen, last_seen, total_value, confidence, detection_sql, card_md, status)
    SELECT tm.typology_id,
           tm.typology_class,
           COALESCE(tm.class_name, tm.typology_class) || ' — ' || tm.typology_id,
           tm.banks_involved,
           tm.member_count,
           tm.first_seen,
           tm.last_seen,
           tm.total_value,
           conf.confidence,
           ds.detection_sql,
           NULL,
           'DISCOVERED'
    FROM _typology_map tm
    JOIN _confidence conf ON conf.component_id = tm.component_id
    LEFT JOIN _detection_sql ds ON ds.component_id = tm.component_id;

    -- Insert evidence
    INSERT INTO ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
        (typology_id, entity_type, entity_id, role, bank_id)
    SELECT tm.typology_id,
           'account',
           nr.account_id,
           nr.role,
           nr.bank_id
    FROM _node_roles nr
    JOIN _typology_map tm ON tm.component_id = nr.component_id;

    -- =================================================================
    -- STEP 13: Typology cards via AI_COMPLETE
    -- =================================================================
    LET v_typ_id STRING;
    LET v_facts STRING;
    LET v_card STRING;

    LET cur CURSOR FOR
        SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED' AND card_md IS NULL;

    FOR rec IN cur DO
        v_typ_id := rec.typology_id;

        -- Build JSON facts
        SELECT OBJECT_CONSTRUCT(
            'typology_id', t.typology_id,
            'class', t.typology_class,
            'banks', t.banks_involved,
            'member_count', t.member_count,
            'first_seen', t.first_seen::STRING,
            'last_seen', t.last_seen::STRING,
            'total_value_aed', t.total_value,
            'confidence', t.confidence,
            'members', (
                SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
                    'account_id', e.entity_id,
                    'role', e.role,
                    'bank', e.bank_id
                ))
                FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE e
                WHERE e.typology_id = :v_typ_id
            )
        )::STRING
        INTO :v_facts
        FROM ARGUS.GOVERNED.TYPOLOGY t
        WHERE t.typology_id = :v_typ_id;

        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            'claude-sonnet-4-5',
            'You are a financial crime analyst writing a brief typology card. '
            || 'Write a plain-English summary (4-6 sentences) from ONLY these facts — do NOT invent details. '
            || 'Cover: what happened, who is involved by role, value, time window, why it matters. '
            || 'Facts: ' || :v_facts
        )
        INTO :v_card;

        UPDATE ARGUS.GOVERNED.TYPOLOGY SET card_md = :v_card WHERE typology_id = :v_typ_id;
    END FOR;

    -- =================================================================
    -- STEP 14: Validate detection queries
    -- =================================================================
    -- (We skip execution of detection_sql inside the procedure for safety;
    --  the validation script will verify them externally.)

    LET v_count INT := (SELECT COUNT(*) FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED');

    RETURN 'Discovered ' || :v_count || ' typologies';
END;

-- =========================================================================
-- 5. Grants
-- =========================================================================
GRANT SELECT ON TABLE ARGUS.GOVERNED.TYPOLOGY TO ROLE ARGUS_ANALYST;
GRANT SELECT ON TABLE ARGUS.GOVERNED.TYPOLOGY_EVIDENCE TO ROLE ARGUS_ANALYST;
GRANT SELECT ON TABLE ARGUS.GOVERNED.TYPOLOGY_CLASS TO ROLE ARGUS_ANALYST;
GRANT SELECT ON TABLE ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION TO ROLE ARGUS_ANALYST;
