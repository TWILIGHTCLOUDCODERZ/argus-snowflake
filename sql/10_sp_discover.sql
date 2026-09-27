USE SCHEMA ARGUS.GOVERNED;

CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._transfer_edges AS
    SELECT t.txn_id, t.account_id AS from_account, t.bank_id AS from_bank,
           a.account_id AS to_account, a.bank_id AS to_bank, t.amount, t.ts
    FROM ARGUS.RAW.TRANSACTIONS t
    JOIN ARGUS.RAW.ACCOUNTS a ON a.iban = t.counterparty_iban
    WHERE t.direction = 'debit'
      AND t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
      AND t.amount >= 10000;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._seeds AS
    SELECT account_id, bank_id, MIN(ws) AS window_start, MAX(we) AS window_end
    FROM (
        SELECT account_id, bank_id, burst_start AS ws, burst_end AS we FROM ARGUS.CURATED.DT_HUB_ACCOUNTS
        UNION ALL
        SELECT account_id, bank_id, first_deposit, last_deposit FROM ARGUS.CURATED.DT_STRUCTURING
        UNION ALL
        SELECT DISTINCT e.account_id, e.bank_id, tr.mn, tr.mx
        FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e
        JOIN ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL s
          ON s.identifier_hash = e.identifier_hash AND s.identifier_type = e.identifier_type
        JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx
              FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) tr
          ON tr.account_id = e.account_id
        WHERE s.identifier_type = 'national_id' AND s.contributing_bank_count >= 2
        UNION ALL
        SELECT cb.account_id, cb.bank_id, MIN(cb.ts), MAX(cb.ts)
        FROM (SELECT from_account AS account_id, from_bank AS bank_id, ts
              FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES
              UNION ALL
              SELECT to_account, to_bank, ts FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES) cb
        GROUP BY cb.account_id, cb.bank_id
        UNION ALL
        SELECT account_id, bank_id, first_seen, last_seen
        FROM ARGUS.GOVERNED.LIVE_ALERTS WHERE status = 'OPEN'
    ) GROUP BY account_id, bank_id;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._community (
        account_id STRING, bank_id STRING,
        window_start TIMESTAMP_NTZ, window_end TIMESTAMP_NTZ, hop INT);
    INSERT INTO ARGUS.GOVERNED._community
    SELECT account_id, bank_id, window_start, window_end, 0 FROM ARGUS.GOVERNED._seeds;

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e.to_account, e.to_bank,
           LEAST(c.window_start, e.ts), GREATEST(c.window_end, e.ts), 1
    FROM ARGUS.GOVERNED._community c JOIN ARGUS.GOVERNED._transfer_edges e ON e.from_account = c.account_id
    WHERE c.hop = 0
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.to_account NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e.from_account, e.from_bank,
           LEAST(c.window_start, e.ts), GREATEST(c.window_end, e.ts), 1
    FROM ARGUS.GOVERNED._community c JOIN ARGUS.GOVERNED._transfer_edges e ON e.to_account = c.account_id
    WHERE c.hop = 0
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.from_account NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e.to_account, e.to_bank,
           LEAST(c.window_start, e.ts), GREATEST(c.window_end, e.ts), 2
    FROM ARGUS.GOVERNED._community c JOIN ARGUS.GOVERNED._transfer_edges e ON e.from_account = c.account_id
    WHERE c.hop = 1
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.to_account NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e.from_account, e.from_bank,
           LEAST(c.window_start, e.ts), GREATEST(c.window_end, e.ts), 2
    FROM ARGUS.GOVERNED._community c JOIN ARGUS.GOVERNED._transfer_edges e ON e.to_account = c.account_id
    WHERE c.hop = 1
      AND e.ts BETWEEN DATEADD('day', -7, c.window_start) AND DATEADD('day', 7, c.window_end)
      AND e.from_account NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e2.account_id, e2.bank_id, tr.mn, tr.mx, -1
    FROM ARGUS.GOVERNED._community c
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c.account_id AND e1.identifier_type = 'national_id'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash
      AND e2.identifier_type = 'national_id' AND e2.bank_id <> e1.bank_id
    JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx
          FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) tr
      ON tr.account_id = e2.account_id
    WHERE e2.account_id NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    INSERT INTO ARGUS.GOVERNED._community
    SELECT DISTINCT e2.account_id, e2.bank_id, tr.mn, tr.mx, -2
    FROM ARGUS.GOVERNED._community c
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c.account_id AND e1.identifier_type = 'device'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash
      AND e2.identifier_type = 'device' AND e2.bank_id <> e1.bank_id
    JOIN (SELECT account_id, MIN(ts) AS mn, MAX(ts) AS mx
          FROM ARGUS.RAW.TRANSACTIONS GROUP BY account_id) tr
      ON tr.account_id = e2.account_id
    WHERE e2.account_id NOT IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND (e2.account_id IN (
             SELECT from_account FROM ARGUS.GOVERNED._transfer_edges
             WHERE to_account IN (SELECT account_id FROM ARGUS.GOVERNED._community))
        OR e2.account_id IN (
             SELECT to_account FROM ARGUS.GOVERNED._transfer_edges
             WHERE from_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)));

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._cd AS
    SELECT account_id, bank_id,
           MIN(window_start) AS window_start, MAX(window_end) AS window_end,
           MIN(hop) AS hop
    FROM ARGUS.GOVERNED._community GROUP BY account_id, bank_id;
    DROP TABLE ARGUS.GOVERNED._community;
    ALTER TABLE ARGUS.GOVERNED._cd RENAME TO ARGUS.GOVERNED._community;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._community_edges AS
    SELECT DISTINCT e.from_account AS node_a, e.to_account AS node_b
    FROM ARGUS.GOVERNED._transfer_edges e
    WHERE e.from_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND e.to_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
    UNION
    SELECT DISTINCT LEAST(e1.account_id, e2.account_id),
                    GREATEST(e1.account_id, e2.account_id)
    FROM ARGUS.GOVERNED._community c1
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c1.account_id AND e1.identifier_type = 'national_id'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash
      AND e2.identifier_type = 'national_id' AND e2.account_id <> e1.account_id
    JOIN ARGUS.GOVERNED._community c2 ON c2.account_id = e2.account_id
    UNION
    SELECT DISTINCT LEAST(e1.account_id, e2.account_id),
                    GREATEST(e1.account_id, e2.account_id)
    FROM ARGUS.GOVERNED._community c1
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
      ON e1.account_id = c1.account_id AND e1.identifier_type = 'device'
    JOIN ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
      ON e2.identifier_hash = e1.identifier_hash
      AND e2.identifier_type = 'device' AND e2.account_id <> e1.account_id
    JOIN ARGUS.GOVERNED._community c2 ON c2.account_id = e2.account_id;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._labels (node STRING, label STRING);
    INSERT INTO ARGUS.GOVERNED._labels
    SELECT DISTINCT account_id, account_id FROM ARGUS.GOVERNED._community;

    LET v_changed INT := 1;
    WHILE (:v_changed > 0) DO
        UPDATE ARGUS.GOVERNED._labels tgt SET label = src.new_label
        FROM (
            SELECT l1.node, MIN(l2.label) AS new_label
            FROM ARGUS.GOVERNED._labels l1
            JOIN ARGUS.GOVERNED._community_edges e
              ON e.node_a = l1.node OR e.node_b = l1.node
            JOIN ARGUS.GOVERNED._labels l2
              ON l2.node = IFF(e.node_a = l1.node, e.node_b, e.node_a)
            WHERE l2.label < l1.label
            GROUP BY l1.node
        ) src
        WHERE tgt.node = src.node AND src.new_label < tgt.label;
        v_changed := SQLROWCOUNT;
    END WHILE;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._xb AS
    SELECT * FROM ARGUS.GOVERNED._transfer_edges
    WHERE from_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND to_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND from_bank <> to_bank;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._sb AS
    SELECT * FROM ARGUS.GOVERNED._transfer_edges
    WHERE from_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND to_account IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND from_bank = to_bank;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._consolidation AS
    SELECT to_account AS account_id FROM ARGUS.GOVERNED._xb
    GROUP BY to_account HAVING COUNT(DISTINCT from_bank) >= 2;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._funnel AS
    SELECT DISTINCT s.to_account AS account_id FROM ARGUS.GOVERNED._sb s
    WHERE s.to_account IN (SELECT from_account FROM ARGUS.GOVERNED._xb)
      AND s.to_account NOT IN (SELECT account_id FROM ARGUS.GOVERNED._consolidation);

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._source_mule AS
    SELECT DISTINCT s.from_account AS account_id FROM ARGUS.GOVERNED._sb s
    WHERE s.from_account NOT IN (SELECT from_account FROM ARGUS.GOVERNED._xb)
      AND s.from_account NOT IN (SELECT to_account FROM ARGUS.GOVERNED._xb)
      AND (s.to_account IN (SELECT account_id FROM ARGUS.GOVERNED._funnel)
        OR s.to_account IN (SELECT account_id FROM ARGUS.GOVERNED._consolidation));

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._layering AS
    SELECT DISTINCT val AS account_id FROM (
        SELECT e1.from_account AS val FROM ARGUS.GOVERNED._xb e1
        JOIN ARGUS.GOVERNED._xb e2 ON e2.from_account = e1.to_account
        JOIN ARGUS.GOVERNED._xb e3 ON e3.from_account = e2.to_account
          AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
        UNION
        SELECT e2.from_account FROM ARGUS.GOVERNED._xb e1
        JOIN ARGUS.GOVERNED._xb e2 ON e2.from_account = e1.to_account
        JOIN ARGUS.GOVERNED._xb e3 ON e3.from_account = e2.to_account
          AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
        UNION
        SELECT e3.from_account FROM ARGUS.GOVERNED._xb e1
        JOIN ARGUS.GOVERNED._xb e2 ON e2.from_account = e1.to_account
        JOIN ARGUS.GOVERNED._xb e3 ON e3.from_account = e2.to_account
          AND e3.to_account = e1.from_account
        WHERE e1.from_bank <> e2.from_bank AND e2.from_bank <> e3.from_bank
    );

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._structuring AS
    SELECT account_id FROM ARGUS.CURATED.DT_STRUCTURING
    WHERE account_id IN (SELECT account_id FROM ARGUS.GOVERNED._community);

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._sid AS
    SELECT DISTINCT e1.account_id
    FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e1
    WHERE e1.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._community)
      AND e1.identifier_type = 'national_id'
      AND EXISTS (
          SELECT 1 FROM ARGUS.GOVERNED.BANK_IDENTIFIER_EXPOSURE e2
          WHERE e2.identifier_hash = e1.identifier_hash
            AND e2.identifier_type = 'national_id'
            AND e2.bank_id <> e1.bank_id
            AND e2.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._community));

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._node_roles AS
    SELECT c.account_id, c.bank_id,
           CASE
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._consolidation) THEN 'consolidation'
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._funnel) THEN 'funnel'
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._source_mule) THEN 'source_mule'
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._layering) THEN 'layering_hop'
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._structuring) THEN 'structuring'
               WHEN c.account_id IN (SELECT account_id FROM ARGUS.GOVERNED._sid) THEN 'shared_identity'
               ELSE 'member'
           END AS role,
           l.label AS component_id
    FROM ARGUS.GOVERNED._community c JOIN ARGUS.GOVERNED._labels l ON l.node = c.account_id;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._cc AS
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
    FROM ARGUS.GOVERNED._node_roles GROUP BY component_id;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._cs AS
    SELECT nr.component_id, cc.typology_class,
           ARRAY_AGG(DISTINCT nr.bank_id) AS banks_involved,
           COUNT(DISTINCT nr.account_id) AS member_count,
           MIN(c.window_start) AS first_seen, MAX(c.window_end) AS last_seen
    FROM ARGUS.GOVERNED._node_roles nr
    JOIN ARGUS.GOVERNED._cc cc ON cc.component_id = nr.component_id
    JOIN ARGUS.GOVERNED._community c ON c.account_id = nr.account_id
    GROUP BY nr.component_id, cc.typology_class;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._cv AS
    SELECT l1.label AS component_id, SUM(e.amount) AS total_value
    FROM ARGUS.GOVERNED._transfer_edges e
    JOIN ARGUS.GOVERNED._labels l1 ON l1.node = e.from_account
    JOIN ARGUS.GOVERNED._labels l2 ON l2.node = e.to_account
    WHERE l1.label = l2.label GROUP BY l1.label;

    -- Snapshot existing typology member fingerprints for ID reuse
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._old_fingerprints AS
    SELECT typology_id,
           LISTAGG(entity_id, ',') WITHIN GROUP (ORDER BY entity_id) AS member_fingerprint
    FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
    WHERE typology_id LIKE 'TYP-%' AND entity_type = 'account'
    GROUP BY typology_id;

    -- Build new component fingerprints
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._new_fingerprints AS
    SELECT nr.component_id,
           LISTAGG(nr.account_id, ',') WITHIN GROUP (ORDER BY nr.account_id) AS member_fingerprint
    FROM ARGUS.GOVERNED._node_roles nr
    GROUP BY nr.component_id;

    -- Match new components to existing typology IDs by member set
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._id_map AS
    SELECT nf.component_id, oldf.typology_id AS reused_id
    FROM ARGUS.GOVERNED._new_fingerprints nf
    JOIN ARGUS.GOVERNED._old_fingerprints oldf ON oldf.member_fingerprint = nf.member_fingerprint;

    -- Find max existing numeric suffix for new ID assignment
    LET v_max_id INT := (SELECT COALESCE(MAX(CAST(REPLACE(typology_id, 'TYP-', '') AS INT)), 0)
                          FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id LIKE 'TYP-%');

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._tm AS
    SELECT cs.component_id,
           COALESCE(
               im.reused_id,
               'TYP-' || LPAD((:v_max_id + ROW_NUMBER() OVER (
                   ORDER BY cs.component_id
               ))::STRING, 4, '0')
           ) AS typology_id,
           cs.typology_class,
           tc.name AS class_name,
           cs.banks_involved, cs.member_count,
           cs.first_seen, cs.last_seen,
           COALESCE(cv.total_value, 0) AS total_value
    FROM ARGUS.GOVERNED._cs cs
    LEFT JOIN ARGUS.GOVERNED._cv cv ON cv.component_id = cs.component_id
    LEFT JOIN ARGUS.GOVERNED.TYPOLOGY_CLASS tc ON tc.typology_class = cs.typology_class
    LEFT JOIN ARGUS.GOVERNED._id_map im ON im.component_id = cs.component_id
    WHERE im.reused_id IS NOT NULL;

    -- Assign new IDs to genuinely new components
    INSERT INTO ARGUS.GOVERNED._tm
    SELECT cs.component_id,
           'TYP-' || LPAD((:v_max_id + ROW_NUMBER() OVER (
               ORDER BY cs.component_id
           ))::STRING, 4, '0') AS typology_id,
           cs.typology_class,
           tc.name AS class_name,
           cs.banks_involved, cs.member_count,
           cs.first_seen, cs.last_seen,
           COALESCE(cv.total_value, 0) AS total_value
    FROM ARGUS.GOVERNED._cs cs
    LEFT JOIN ARGUS.GOVERNED._cv cv ON cv.component_id = cs.component_id
    LEFT JOIN ARGUS.GOVERNED.TYPOLOGY_CLASS tc ON tc.typology_class = cs.typology_class
    LEFT JOIN ARGUS.GOVERNED._id_map im ON im.component_id = cs.component_id
    WHERE im.reused_id IS NULL;

    -- Preserve existing cards and detection_sql for reused typologies
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._old_cards AS
    SELECT typology_id, card_md, detection_sql
    FROM ARGUS.GOVERNED.TYPOLOGY
    WHERE typology_id IN (SELECT reused_id FROM ARGUS.GOVERNED._id_map);

    DELETE FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED';
    DELETE FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE typology_id LIKE 'TYP-%';

    INSERT INTO ARGUS.GOVERNED.TYPOLOGY
        (typology_id, typology_class, name, banks_involved, member_count,
         first_seen, last_seen, total_value, confidence,
         detection_sql, card_md, status)
    SELECT tm.typology_id, tm.typology_class,
           COALESCE(tm.class_name, tm.typology_class) || ' - ' || tm.typology_id,
           tm.banks_involved, tm.member_count,
           tm.first_seen, tm.last_seen, tm.total_value,
           CASE
               WHEN tm.member_count >= 10 AND ARRAY_SIZE(tm.banks_involved) >= 3 THEN 0.95
               WHEN tm.member_count >= 3 AND ARRAY_SIZE(tm.banks_involved) >= 2 THEN 0.90
               WHEN tm.member_count >= 3 THEN 0.85
               WHEN tm.member_count >= 2 THEN 0.80
               ELSE 0.75
           END,
           NULL, NULL, 'DISCOVERED'
    FROM ARGUS.GOVERNED._tm tm;

    INSERT INTO ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
        (typology_id, entity_type, entity_id, role, bank_id)
    SELECT tm.typology_id, 'account', nr.account_id, nr.role, nr.bank_id
    FROM ARGUS.GOVERNED._node_roles nr
    JOIN ARGUS.GOVERNED._tm tm ON tm.component_id = nr.component_id;

    -- Restore preserved cards for reused typologies
    UPDATE ARGUS.GOVERNED.TYPOLOGY t
    SET card_md = oc.card_md,
        detection_sql = oc.detection_sql
    FROM ARGUS.GOVERNED._old_cards oc
    WHERE t.typology_id = oc.typology_id;

    -- Generate detection_sql + AI cards only for NEW typologies (no preserved card)
    LET v_typ_id STRING;
    LET v_facts STRING;
    LET v_card STRING;
    LET cur CURSOR FOR
        SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY
        WHERE status = 'DISCOVERED' AND card_md IS NULL;
    FOR rec IN cur DO
        v_typ_id := rec.typology_id;

        UPDATE ARGUS.GOVERNED.TYPOLOGY
        SET detection_sql = 'SELECT entity_id AS account_id, role FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE typology_id = ''' || :v_typ_id || ''''
        WHERE typology_id = :v_typ_id;

        LET v_class2 STRING := (SELECT typology_class FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_banks STRING := (SELECT ARRAY_TO_STRING(banks_involved, ', ') FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_mc INT := (SELECT member_count FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_fs STRING := (SELECT first_seen::STRING FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_ls STRING := (SELECT last_seen::STRING FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_tv STRING := (SELECT total_value::STRING FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :v_typ_id);
        LET v_members STRING := (SELECT LISTAGG(entity_id || '(' || role || ',' || bank_id || ')', '; ') WITHIN GROUP (ORDER BY role, entity_id)
                                  FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE typology_id = :v_typ_id);

        v_facts := '{"typology_id":"' || :v_typ_id || '","class":"' || :v_class2 || '","banks":"' || :v_banks
                   || '","member_count":' || :v_mc || ',"first_seen":"' || :v_fs || '","last_seen":"' || :v_ls
                   || '","total_value_aed":' || :v_tv || ',"members":"' || :v_members || '"}';

        v_card := (SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-5',
            'You are a financial crime analyst. Write a brief typology card (4-6 sentences) from ONLY these facts. Do NOT invent. Cover: what happened, who by role, value, time window, why it matters. Facts: '
            || :v_facts));

        UPDATE ARGUS.GOVERNED.TYPOLOGY
        SET card_md = :v_card
        WHERE typology_id = :v_typ_id;
    END FOR;

    LET v_count INT := (
        SELECT COUNT(*)
        FROM ARGUS.GOVERNED.TYPOLOGY
        WHERE status = 'DISCOVERED');
    RETURN 'Discovered ' || :v_count || ' typologies';
END;
$$;
