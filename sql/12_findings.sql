/* ============================================================================
   ARGUS · 12_findings.sql — Findings, Evidence Ledger, Verifier & Filing Drafts
   Created by TCC · CoCo Session S9

   Tables : FINDING, FINDING_CLAIM, FILING
   UDFs   : FN_GROUNDING_CHECK (JS — number-level narrative grounding)
   Procs  : SP_BUILD_FINDING, SP_BUILD_FINDING_ADHOC, SP_VERIFY_FINDING,
            SP_DRAFT_FILING

   Principle: claims are facts computed by SQL; the LLM only writes prose from
   verified claims.  Nothing is filed automatically — every filing is a draft
   awaiting a human.
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. TABLES
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS FINDING (
    finding_id        STRING,
    typology_id       STRING,
    typology_class    STRING,
    title             STRING,
    banks_involved    ARRAY,
    total_value       NUMBER(18,2),
    confidence        NUMBER(3,2),
    status            STRING DEFAULT 'DRAFT',       -- DRAFT | VERIFIED | REJECTED
    verifier_reason   STRING,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    verified_at       TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS FINDING_CLAIM (
    claim_id          STRING,
    finding_id        STRING,
    claim_seq         NUMBER,
    claim_type        STRING,   -- FLOW | ROLE | IDENTITY | STRUCTURING | REGULATORY | CONTROL_GAP
    claim_text        STRING,
    bank_id           STRING,
    structured_refs   ARRAY,    -- txn_ids / account_ids / signal hashes
    clause_refs       ARRAY,    -- clause_ids
    confidence        NUMBER(3,2),
    verified          BOOLEAN DEFAULT FALSE,
    verification_note STRING
);

CREATE TABLE IF NOT EXISTS FILING (
    filing_id         STRING,
    finding_id        STRING,
    filing_type       STRING,   -- STR | CONTROL_GAP_MEMO
    bank_id           STRING,
    regulator         STRING,
    fiu               STRING,
    narrative_md      STRING,
    cited_claims      ARRAY,
    status            STRING DEFAULT 'DRAFT_PENDING_HUMAN',
    grounding_check   VARIANT,
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    approved_by       STRING
);

GRANT SELECT ON FINDING       TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FINDING_CLAIM TO ROLE ARGUS_ANALYST;
GRANT SELECT ON FILING        TO ROLE ARGUS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. SP_BUILD_FINDING — deterministic claim builder (no LLM, no FOR loops)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE SP_BUILD_FINDING(P_TYPOLOGY_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    LET v_typ_class STRING;
    LET v_typ_name STRING;
    LET v_banks ARRAY;
    LET v_total_value FLOAT;
    LET v_confidence FLOAT;

    SELECT typology_class, name, banks_involved, total_value, confidence
      INTO :v_typ_class, :v_typ_name, :v_banks, :v_total_value, :v_confidence
      FROM ARGUS.GOVERNED.TYPOLOGY WHERE typology_id = :P_TYPOLOGY_ID;

    IF (v_typ_class IS NULL) THEN
        RETURN 'ERROR: typology ' || :P_TYPOLOGY_ID || ' not found';
    END IF;

    LET v_finding_id STRING := 'FND-' || LPAD(
        (SELECT COALESCE(MAX(REPLACE(finding_id, 'FND-', '')::INT), 0) + 1
           FROM ARGUS.GOVERNED.FINDING)::STRING, 4, '0');

    INSERT INTO ARGUS.GOVERNED.FINDING
        (finding_id, typology_id, typology_class, title, banks_involved, total_value, confidence, status)
    SELECT :v_finding_id, :P_TYPOLOGY_ID, :v_typ_class, :v_typ_name,
           :v_banks, :v_total_value, :v_confidence, 'DRAFT';

    -- Pre-compute clause_refs for the typology class (excluding OB-10 reporting)
    LET v_class_clause_refs ARRAY := (
        SELECT ARRAY_AGG(DISTINCT cl.clause_id)
          FROM ARGUS.GOVERNED.TYPOLOGY_CLASS_OBLIGATION tco
          JOIN ARGUS.GOVERNED.OBLIGATION o ON o.obligation_id = tco.obligation_id
          JOIN ARGUS.GOVERNED.CLAUSE cl ON cl.clause_id = o.clause_id
         WHERE tco.typology_class = :v_typ_class AND o.obligation_id != 'OB-10');

    LET v_seq NUMBER := 0;

    -- ── FLOW claims (FAN_IN_FAN_OUT_MULE or CIRCULAR_LAYERING) ──
    IF (v_typ_class IN ('FAN_IN_FAN_OUT_MULE', 'CIRCULAR_LAYERING')) THEN
        CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._build_members AS
        SELECT entity_id AS account_id, role, bank_id
          FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
         WHERE typology_id = :P_TYPOLOGY_ID AND entity_type = 'account';

        CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._build_flows AS
        SELECT t.account_id AS sender_account, m_s.bank_id AS m_s_bank,
               m_s.role AS sender_role, a2.account_id AS receiver_account,
               m_r.bank_id AS m_r_bank, m_r.role AS receiver_role,
               COUNT(*) AS txn_count, SUM(t.amount) AS total_amount,
               MIN(t.ts) AS first_ts, MAX(t.ts) AS last_ts,
               ARRAY_AGG(t.txn_id) AS txn_ids
          FROM ARGUS.RAW.TRANSACTIONS t
          JOIN ARGUS.RAW.ACCOUNTS a2 ON a2.iban = t.counterparty_iban
          JOIN ARGUS.GOVERNED._build_members m_s ON m_s.account_id = t.account_id
          JOIN ARGUS.GOVERNED._build_members m_r ON m_r.account_id = a2.account_id
         WHERE t.direction = 'debit' AND t.account_id != a2.account_id
         GROUP BY t.account_id, m_s.bank_id, m_s.role,
                  a2.account_id, m_r.bank_id, m_r.role;

        INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
            (claim_id, finding_id, claim_seq, claim_type, claim_text,
             bank_id, structured_refs, clause_refs, confidence)
        SELECT :v_finding_id || '-C' || LPAD(
                   (ROW_NUMBER() OVER (ORDER BY first_ts) + :v_seq)::STRING, 2, '0'),
               :v_finding_id,
               ROW_NUMBER() OVER (ORDER BY first_ts) + :v_seq,
               'FLOW',
               sender_account || ' (' || sender_role || ', ' || m_s_bank || ') sent ' ||
                   txn_count || ' transfers totalling AED ' ||
                   TO_CHAR(total_amount, '999,999,999.99') || ' to ' ||
                   receiver_account || ' (' || receiver_role || ', ' || m_r_bank ||
                   ') between ' || TO_VARCHAR(first_ts, 'YYYY-MM-DD HH24:MI') ||
                   ' and ' || TO_VARCHAR(last_ts, 'YYYY-MM-DD HH24:MI') || '.',
               m_s_bank, txn_ids, :v_class_clause_refs, :v_confidence
          FROM ARGUS.GOVERNED._build_flows;
        v_seq := :v_seq + (SELECT COUNT(*) FROM ARGUS.GOVERNED._build_flows);
    END IF;

    -- ── STRUCTURING claims ──
    IF (v_typ_class = 'CASH_STRUCTURING') THEN
        CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._build_struct AS
        SELECT s.account_id, s.bank_id, s.near_threshold_deposits, s.total_amount,
               s.first_deposit, s.last_deposit,
               (SELECT ARRAY_AGG(t.txn_id) FROM ARGUS.RAW.TRANSACTIONS t
                 WHERE t.account_id = s.account_id AND t.direction = 'credit'
                   AND t.channel = 'cash' AND t.amount >= 50000 AND t.amount < 55000) AS struct_txns
          FROM ARGUS.CURATED.DT_STRUCTURING s
          JOIN ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
            ON te.entity_id = s.account_id AND te.typology_id = :P_TYPOLOGY_ID;

        INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
            (claim_id, finding_id, claim_seq, claim_type, claim_text,
             bank_id, structured_refs, clause_refs, confidence)
        SELECT :v_finding_id || '-C' || LPAD(
                   (ROW_NUMBER() OVER (ORDER BY account_id) + :v_seq)::STRING, 2, '0'),
               :v_finding_id,
               ROW_NUMBER() OVER (ORDER BY account_id) + :v_seq,
               'STRUCTURING',
               'Account ' || account_id || ' at ' || bank_id || ' made ' ||
                   near_threshold_deposits || ' cash deposits near the AED 55,000 CTR threshold totalling AED ' ||
                   TO_CHAR(total_amount, '999,999,999.99') || ' between ' ||
                   TO_VARCHAR(first_deposit, 'YYYY-MM-DD HH24:MI') || ' and ' ||
                   TO_VARCHAR(last_deposit, 'YYYY-MM-DD HH24:MI') || '.',
               bank_id, struct_txns, :v_class_clause_refs, :v_confidence
          FROM ARGUS.GOVERNED._build_struct;
        v_seq := :v_seq + (SELECT COUNT(*) FROM ARGUS.GOVERNED._build_struct);
    END IF;

    -- ── IDENTITY claims (SHARED_IDENTITY) ──
    IF (v_typ_class = 'SHARED_IDENTITY') THEN
        LET v_shared_nid_hash STRING := (
            SELECT c.national_id_hash
              FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
              JOIN ARGUS.RAW.ACCOUNTS a ON a.account_id = te.entity_id
              JOIN ARGUS.RAW.CUSTOMERS c ON c.customer_id = a.customer_id AND c.bank_id = a.bank_id
             WHERE te.typology_id = :P_TYPOLOGY_ID AND te.role = 'shared_identity'
             GROUP BY c.national_id_hash HAVING COUNT(DISTINCT te.bank_id) >= 2 LIMIT 1);
        IF (v_shared_nid_hash IS NOT NULL) THEN
            v_seq := :v_seq + 1;
            LET v_identity_accounts ARRAY := (
                SELECT ARRAY_AGG(te.entity_id) FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
                 WHERE te.typology_id = :P_TYPOLOGY_ID AND te.role = 'shared_identity');
            INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
                (claim_id, finding_id, claim_seq, claim_type, claim_text,
                 bank_id, structured_refs, clause_refs, confidence)
            SELECT :v_finding_id || '-C' || LPAD(:v_seq::STRING, 2, '0'),
                   :v_finding_id, :v_seq, 'IDENTITY',
                   'The same national identity document (hash: ' || :v_shared_nid_hash ||
                       ') was used to open accounts at ' || ARRAY_SIZE(:v_banks) ||
                       ' different banks: ' || ARRAY_TO_STRING(:v_identity_accounts, ', ') || '.',
                   NULL, :v_identity_accounts, :v_class_clause_refs, :v_confidence;
        END IF;
        LET v_shared_dev_hash STRING := (
            SELECT dl.device_hash
              FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
              JOIN ARGUS.RAW.DEVICE_LOGINS dl ON dl.account_id = te.entity_id
             WHERE te.typology_id = :P_TYPOLOGY_ID AND te.role = 'shared_identity'
             GROUP BY dl.device_hash HAVING COUNT(DISTINCT dl.bank_id) >= 2 LIMIT 1);
        IF (v_shared_dev_hash IS NOT NULL) THEN
            v_seq := :v_seq + 1;
            INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
                (claim_id, finding_id, claim_seq, claim_type, claim_text,
                 bank_id, structured_refs, clause_refs, confidence)
            SELECT :v_finding_id || '-C' || LPAD(:v_seq::STRING, 2, '0'),
                   :v_finding_id, :v_seq, 'IDENTITY',
                   'The same device (hash: ' || :v_shared_dev_hash ||
                       ') was used to access accounts across multiple banks.',
                   NULL, ARRAY_CONSTRUCT(:v_shared_dev_hash), :v_class_clause_refs, :v_confidence;
        END IF;
    END IF;

    -- ── ROLE claims ──
    LET v_role_base NUMBER := :v_seq;
    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(
               (ROW_NUMBER() OVER (ORDER BY role) + :v_role_base)::STRING, 2, '0'),
           :v_finding_id, ROW_NUMBER() OVER (ORDER BY role) + :v_role_base, 'ROLE',
           cnt || ' account(s) serve as ' || role || ': ' ||
               ARRAY_TO_STRING(accounts, ', ') || ' across bank(s) ' ||
               ARRAY_TO_STRING(banks, ', ') || '.',
           NULL, accounts, :v_class_clause_refs, :v_confidence
      FROM (SELECT te.role, ARRAY_AGG(te.entity_id) AS accounts,
                   COUNT(*) AS cnt, ARRAY_AGG(DISTINCT te.bank_id) AS banks
              FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
             WHERE te.typology_id = :P_TYPOLOGY_ID AND te.entity_type = 'account'
             GROUP BY te.role);
    v_seq := :v_seq + (SELECT COUNT(DISTINCT role)
        FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
       WHERE typology_id = :P_TYPOLOGY_ID AND entity_type = 'account');

    -- ── REGULATORY claims ──
    LET v_reg_base NUMBER := :v_seq;
    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(
               (ROW_NUMBER() OVER (ORDER BY te.obligation_id) + :v_reg_base)::STRING, 2, '0'),
           :v_finding_id, ROW_NUMBER() OVER (ORDER BY te.obligation_id) + :v_reg_base,
           'REGULATORY',
           'Obligation ' || te.obligation_id || ' (' || te.regulator || ' ' ||
               te.article_ref || '): ' || te.obligation_text || ' | Clause: ' || cl.text ||
               IFF(te.is_gap, ' [GAP: no adequate control deployed]', ' [COVERED]'),
           NULL, ARRAY_CONSTRUCT(te.obligation_id), ARRAY_CONSTRUCT(cl.clause_id), :v_confidence
      FROM ARGUS.GOVERNED.TYPOLOGY_EXPOSURE te
      JOIN ARGUS.GOVERNED.OBLIGATION o ON o.obligation_id = te.obligation_id
      JOIN ARGUS.GOVERNED.CLAUSE cl ON cl.clause_id = o.clause_id
     WHERE te.typology_id = :P_TYPOLOGY_ID;
    v_seq := :v_seq + (SELECT COUNT(*) FROM ARGUS.GOVERNED.TYPOLOGY_EXPOSURE
                        WHERE typology_id = :P_TYPOLOGY_ID);

    -- ── CONTROL_GAP claims ──
    LET v_gap_base NUMBER := :v_seq;
    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(
               (ROW_NUMBER() OVER (ORDER BY cg.obligation_id) + :v_gap_base)::STRING, 2, '0'),
           :v_finding_id, ROW_NUMBER() OVER (ORDER BY cg.obligation_id) + :v_gap_base,
           'CONTROL_GAP',
           'Control gap for obligation ' || cg.obligation_id || ': ' ||
               cg.obligation_text || '. Mapped controls: ' ||
               COALESCE(cg.mapped_controls, 'none') || '. Rationale: ' || cg.rationale,
           NULL, ARRAY_CONSTRUCT(cg.obligation_id), ARRAY_CONSTRUCT(cl.clause_id), :v_confidence
      FROM (SELECT DISTINCT cg2.obligation_id, cg2.obligation_text,
                   cg2.mapped_controls, cg2.rationale, o2.clause_id
              FROM ARGUS.GOVERNED.TYPOLOGY_EXPOSURE te2
              JOIN ARGUS.GOVERNED.CONTROL_GAP cg2 ON cg2.obligation_id = te2.obligation_id
              JOIN ARGUS.GOVERNED.OBLIGATION o2 ON o2.obligation_id = cg2.obligation_id
             WHERE te2.typology_id = :P_TYPOLOGY_ID AND cg2.is_gap = TRUE) cg
       JOIN ARGUS.GOVERNED.CLAUSE cl ON cl.clause_id = cg.clause_id;

    -- ── SUMMARY claim (citable totals) ──
    v_seq := :v_seq + (SELECT COUNT(DISTINCT cg2.obligation_id)
        FROM ARGUS.GOVERNED.TYPOLOGY_EXPOSURE te2
        JOIN ARGUS.GOVERNED.CONTROL_GAP cg2 ON cg2.obligation_id = te2.obligation_id
       WHERE te2.typology_id = :P_TYPOLOGY_ID AND cg2.is_gap = TRUE);

    v_seq := :v_seq + 1;
    LET v_member_count NUMBER := (
        SELECT COUNT(DISTINCT entity_id) FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE
         WHERE typology_id = :P_TYPOLOGY_ID AND entity_type = 'account');
    LET v_first_ts STRING := (
        SELECT COALESCE(
            MIN(REGEXP_SUBSTR(claim_text, '\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}')),
            'N/A')
          FROM ARGUS.GOVERNED.FINDING_CLAIM
         WHERE finding_id = :v_finding_id AND claim_type IN ('FLOW','STRUCTURING'));
    LET v_last_ts STRING := (
        SELECT COALESCE(
            MAX(REGEXP_SUBSTR(claim_text, '\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}')),
            'N/A')
          FROM ARGUS.GOVERNED.FINDING_CLAIM
         WHERE finding_id = :v_finding_id AND claim_type IN ('FLOW','STRUCTURING'));
    LET v_flow_count NUMBER := (
        SELECT COUNT(*) FROM ARGUS.GOVERNED.FINDING_CLAIM
         WHERE finding_id = :v_finding_id AND claim_type IN ('FLOW','STRUCTURING'));
    LET v_bank_list STRING := (
        SELECT ARRAY_TO_STRING(:v_banks, ', '));

    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(:v_seq::STRING, 2, '0'),
           :v_finding_id, :v_seq, 'SUMMARY',
           'SUMMARY: Finding ' || :v_finding_id || ' involves ' ||
               ARRAY_SIZE(:v_banks) || ' banks (' || :v_bank_list ||
               ') with ' || :v_member_count || ' member accounts. ' ||
               'Total network value: AED ' || TO_CHAR(:v_total_value, '999,999,999.99') ||
               ' across ' || :v_flow_count || ' flows between ' ||
               :v_first_ts || ' and ' || :v_last_ts || '.',
           NULL, ARRAY_CONSTRUCT(), ARRAY_CONSTRUCT(), :v_confidence;

    RETURN :v_finding_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. SP_BUILD_FINDING_ADHOC — ad-hoc finding from arbitrary account IDs
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE SP_BUILD_FINDING_ADHOC(P_ACCOUNT_IDS ARRAY)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- Delegate to SP_BUILD_FINDING if accounts match a known typology
    LET v_typ_id STRING := (
        SELECT te.typology_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
         WHERE ARRAY_CONTAINS(te.entity_id::VARIANT, :P_ACCOUNT_IDS)
           AND te.typology_id LIKE 'TYP-%'
         GROUP BY te.typology_id ORDER BY COUNT(*) DESC LIMIT 1);

    IF (v_typ_id IS NOT NULL) THEN
        LET v_result STRING;
        CALL ARGUS.GOVERNED.SP_BUILD_FINDING(:v_typ_id);
        v_result := (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())));
        RETURN v_result;
    END IF;

    LET v_finding_id STRING := 'FND-' || LPAD(
        (SELECT COALESCE(MAX(REPLACE(finding_id, 'FND-', '')::INT), 0) + 1
           FROM ARGUS.GOVERNED.FINDING)::STRING, 4, '0');

    LET v_banks ARRAY := (
        SELECT ARRAY_AGG(DISTINCT a.bank_id) FROM ARGUS.RAW.ACCOUNTS a
         WHERE ARRAY_CONTAINS(a.account_id::VARIANT, :P_ACCOUNT_IDS));

    INSERT INTO ARGUS.GOVERNED.FINDING
        (finding_id, typology_id, typology_class, title, banks_involved,
         total_value, confidence, status)
    SELECT :v_finding_id, 'ADHOC', 'ADHOC',
           'Ad-hoc investigation of accounts ' || ARRAY_TO_STRING(:P_ACCOUNT_IDS, ', '),
           :v_banks, 0, 0.50, 'DRAFT';

    LET v_seq NUMBER := 0;

    -- Shared device (weak signal only)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._adhoc_shared_dev AS
    SELECT dl.device_hash, ARRAY_AGG(DISTINCT dl.account_id) AS accts
      FROM ARGUS.RAW.DEVICE_LOGINS dl
     WHERE ARRAY_CONTAINS(dl.account_id::VARIANT, :P_ACCOUNT_IDS)
     GROUP BY dl.device_hash HAVING COUNT(DISTINCT dl.account_id) >= 2;

    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(
               (ROW_NUMBER() OVER (ORDER BY device_hash) + :v_seq)::STRING, 2, '0'),
           :v_finding_id, ROW_NUMBER() OVER (ORDER BY device_hash) + :v_seq, 'IDENTITY',
           'Shared device (hash: ' || device_hash || ') used by accounts: ' ||
               ARRAY_TO_STRING(accts, ', ') || '.',
           NULL, ARRAY_CONSTRUCT(device_hash), ARRAY_CONSTRUCT(), 0.30
      FROM ARGUS.GOVERNED._adhoc_shared_dev;
    v_seq := :v_seq + (SELECT COUNT(*) FROM ARGUS.GOVERNED._adhoc_shared_dev);

    -- Shared national ID (stronger signal)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._adhoc_shared_nid AS
    SELECT c.national_id_hash, ARRAY_AGG(DISTINCT a.account_id) AS accts
      FROM ARGUS.RAW.ACCOUNTS a
      JOIN ARGUS.RAW.CUSTOMERS c ON c.customer_id = a.customer_id AND c.bank_id = a.bank_id
     WHERE ARRAY_CONTAINS(a.account_id::VARIANT, :P_ACCOUNT_IDS)
     GROUP BY c.national_id_hash HAVING COUNT(DISTINCT a.bank_id) >= 2;

    INSERT INTO ARGUS.GOVERNED.FINDING_CLAIM
        (claim_id, finding_id, claim_seq, claim_type, claim_text,
         bank_id, structured_refs, clause_refs, confidence)
    SELECT :v_finding_id || '-C' || LPAD(
               (ROW_NUMBER() OVER (ORDER BY national_id_hash) + :v_seq)::STRING, 2, '0'),
           :v_finding_id, ROW_NUMBER() OVER (ORDER BY national_id_hash) + :v_seq, 'IDENTITY',
           'Shared national ID (hash: ' || national_id_hash || ') across accounts: ' ||
               ARRAY_TO_STRING(accts, ', ') || '.',
           NULL, accts, ARRAY_CONSTRUCT('CL-02', 'CL-07', 'CL-08'), 0.80
      FROM ARGUS.GOVERNED._adhoc_shared_nid;

    RETURN :v_finding_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. SP_VERIFY_FINDING — the guardrail (set-based, no FOR-cursor issues)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE SP_VERIFY_FINDING(P_FINDING_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    LET v_status STRING := (SELECT status FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);
    LET v_confidence FLOAT := (SELECT confidence FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);

    IF (v_status IS NULL) THEN
        RETURN 'ERROR: finding ' || :P_FINDING_ID || ' not found';
    END IF;
    IF (v_status != 'DRAFT') THEN
        RETURN 'ERROR: finding ' || :P_FINDING_ID || ' is already ' || :v_status;
    END IF;

    -- Weak-signal rule (checked first for specificity): device-only evidence → REJECTED
    LET v_has_flow BOOLEAN := (SELECT COUNT(*) > 0 FROM ARGUS.GOVERNED.FINDING_CLAIM
        WHERE finding_id = :P_FINDING_ID AND claim_type = 'FLOW');
    LET v_has_nid BOOLEAN := (SELECT COUNT(*) > 0 FROM ARGUS.GOVERNED.FINDING_CLAIM
        WHERE finding_id = :P_FINDING_ID AND claim_type = 'IDENTITY'
        AND claim_text LIKE '%national%');
    LET v_has_structuring BOOLEAN := (SELECT COUNT(*) > 0 FROM ARGUS.GOVERNED.FINDING_CLAIM
        WHERE finding_id = :P_FINDING_ID AND claim_type = 'STRUCTURING');

    IF (NOT v_has_flow AND NOT v_has_nid AND NOT v_has_structuring) THEN
        UPDATE ARGUS.GOVERNED.FINDING
           SET status = 'REJECTED',
               verifier_reason = 'Insufficient evidence — weak signal only (no flows, no national-ID link, no structuring)',
               verified_at = CURRENT_TIMESTAMP()
         WHERE finding_id = :P_FINDING_ID;
        RETURN 'REJECTED: insufficient evidence — weak signal only';
    END IF;

    IF (v_confidence < 0.70) THEN
        UPDATE ARGUS.GOVERNED.FINDING
           SET status = 'REJECTED',
               verifier_reason = 'Confidence ' || :v_confidence || ' below 0.70 threshold',
               verified_at = CURRENT_TIMESTAMP()
         WHERE finding_id = :P_FINDING_ID;
        RETURN 'REJECTED: confidence below threshold';
    END IF;

    -- Flatten refs into temp tables for set-based verification
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_struct AS
    SELECT fc.claim_id, fc.claim_type, f.value::STRING AS ref_val
      FROM ARGUS.GOVERNED.FINDING_CLAIM fc,
           LATERAL FLATTEN(input => fc.structured_refs) f
     WHERE fc.finding_id = :P_FINDING_ID;

    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_clauses AS
    SELECT fc.claim_id, f.value::STRING AS clause_val
      FROM ARGUS.GOVERNED.FINDING_CLAIM fc,
           LATERAL FLATTEN(input => fc.clause_refs) f
     WHERE fc.finding_id = :P_FINDING_ID AND ARRAY_SIZE(fc.clause_refs) > 0;

    -- Verify txn refs (FLOW, STRUCTURING)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_txn_ok AS
    SELECT s.claim_id, COUNT(*) AS total_refs, COUNT(t.txn_id) AS found_refs
      FROM ARGUS.GOVERNED._v_struct s LEFT JOIN ARGUS.RAW.TRANSACTIONS t ON t.txn_id = s.ref_val
     WHERE s.claim_type IN ('FLOW', 'STRUCTURING') GROUP BY s.claim_id;

    -- Verify account refs (ROLE)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_acct_ok AS
    SELECT s.claim_id, COUNT(*) AS total_refs, COUNT(a.account_id) AS found_refs
      FROM ARGUS.GOVERNED._v_struct s LEFT JOIN ARGUS.RAW.ACCOUNTS a ON a.account_id = s.ref_val
     WHERE s.claim_type = 'ROLE' GROUP BY s.claim_id;

    -- Verify identity refs (accounts or device hashes)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_id_ok AS
    SELECT s.claim_id, COUNT(DISTINCT a.account_id) AS acct_found,
           COUNT(DISTINCT dl.device_hash) AS dev_found
      FROM ARGUS.GOVERNED._v_struct s
      LEFT JOIN ARGUS.RAW.ACCOUNTS a ON a.account_id = s.ref_val
      LEFT JOIN (SELECT DISTINCT device_hash FROM ARGUS.RAW.DEVICE_LOGINS) dl
        ON dl.device_hash = s.ref_val
     WHERE s.claim_type = 'IDENTITY' GROUP BY s.claim_id;

    -- Verify obligation refs (REGULATORY, CONTROL_GAP)
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_reg_ok AS
    SELECT s.claim_id, COUNT(*) AS total_refs, COUNT(o.obligation_id) AS found_refs
      FROM ARGUS.GOVERNED._v_struct s LEFT JOIN ARGUS.GOVERNED.OBLIGATION o ON o.obligation_id = s.ref_val
     WHERE s.claim_type IN ('REGULATORY', 'CONTROL_GAP') GROUP BY s.claim_id;

    -- Verify clause refs
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_cl_ok AS
    SELECT c.claim_id, COUNT(*) AS total_refs, COUNT(cl.clause_id) AS found_refs
      FROM ARGUS.GOVERNED._v_clauses c LEFT JOIN ARGUS.GOVERNED.CLAUSE cl ON cl.clause_id = c.clause_val
     GROUP BY c.claim_id;

    -- Compute per-claim verification result
    CREATE OR REPLACE TEMPORARY TABLE ARGUS.GOVERNED._v_results AS
    SELECT fc.claim_id, fc.claim_type,
           CASE
               WHEN fc.claim_type IN ('FLOW','STRUCTURING') AND t.found_refs < t.total_refs THEN FALSE
               WHEN fc.claim_type = 'ROLE' AND a.found_refs < a.total_refs THEN FALSE
               WHEN fc.claim_type = 'IDENTITY' AND COALESCE(i.acct_found,0) = 0
                    AND COALESCE(i.dev_found,0) = 0 THEN FALSE
               WHEN fc.claim_type IN ('REGULATORY','CONTROL_GAP') AND r.found_refs < r.total_refs THEN FALSE
               ELSE TRUE
           END AS struct_ok,
           CASE WHEN cl.found_refs IS NOT NULL AND cl.found_refs < cl.total_refs
                THEN FALSE ELSE TRUE END AS clause_ok,
           CASE
               WHEN fc.claim_type IN ('FLOW','STRUCTURING') AND t.found_refs < t.total_refs
                   THEN 'FAIL: ' || (t.total_refs - t.found_refs) || ' of ' || t.total_refs || ' txn_ids not found'
               WHEN fc.claim_type = 'ROLE' AND a.found_refs < a.total_refs
                   THEN 'FAIL: ' || (a.total_refs - a.found_refs) || ' of ' || a.total_refs || ' account_ids not found'
               WHEN fc.claim_type = 'IDENTITY' AND COALESCE(i.acct_found,0) = 0
                    AND COALESCE(i.dev_found,0) = 0
                   THEN 'FAIL: no structured_refs resolve to accounts or device_logins'
               WHEN fc.claim_type IN ('REGULATORY','CONTROL_GAP') AND r.found_refs < r.total_refs
                   THEN 'FAIL: ' || (r.total_refs - r.found_refs) || ' obligation_ids not found'
               ELSE 'OK'
           END ||
           CASE WHEN cl.found_refs IS NOT NULL AND cl.found_refs < cl.total_refs
               THEN '; FAIL: ' || (cl.total_refs - cl.found_refs) || ' clause_refs not found'
               ELSE '' END AS note
      FROM ARGUS.GOVERNED.FINDING_CLAIM fc
      LEFT JOIN ARGUS.GOVERNED._v_txn_ok t ON t.claim_id = fc.claim_id
      LEFT JOIN ARGUS.GOVERNED._v_acct_ok a ON a.claim_id = fc.claim_id
      LEFT JOIN ARGUS.GOVERNED._v_id_ok i ON i.claim_id = fc.claim_id
      LEFT JOIN ARGUS.GOVERNED._v_reg_ok r ON r.claim_id = fc.claim_id
      LEFT JOIN ARGUS.GOVERNED._v_cl_ok cl ON cl.claim_id = fc.claim_id
     WHERE fc.finding_id = :P_FINDING_ID;

    -- Update all claims
    UPDATE ARGUS.GOVERNED.FINDING_CLAIM fc
       SET verified = (vr.struct_ok AND vr.clause_ok), verification_note = vr.note
      FROM ARGUS.GOVERNED._v_results vr WHERE fc.claim_id = vr.claim_id;

    LET v_fail_count NUMBER := (SELECT COUNT(*) FROM ARGUS.GOVERNED._v_results WHERE NOT (struct_ok AND clause_ok));
    LET v_fail_claims STRING := (SELECT LISTAGG(claim_id || ': ' || note, '; ')
        FROM ARGUS.GOVERNED._v_results WHERE NOT (struct_ok AND clause_ok));

    IF (v_fail_count = 0) THEN
        UPDATE ARGUS.GOVERNED.FINDING
           SET status = 'VERIFIED', verifier_reason = 'All claims verified',
               verified_at = CURRENT_TIMESTAMP()
         WHERE finding_id = :P_FINDING_ID;
        RETURN 'VERIFIED';
    ELSE
        UPDATE ARGUS.GOVERNED.FINDING
           SET status = 'REJECTED', verifier_reason = :v_fail_claims,
               verified_at = CURRENT_TIMESTAMP()
         WHERE finding_id = :P_FINDING_ID;
        RETURN 'REJECTED: ' || :v_fail_claims;
    END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. FN_GROUNDING_CHECK — verify every number in narrative appears in cited claims
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION ARGUS.GOVERNED.FN_GROUNDING_CHECK(
    P_NARRATIVE STRING,
    P_CITED_CLAIM_TEXTS STRING
)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
STRICT
AS
$$
    var text = P_NARRATIVE || '';
    var claimTexts = P_CITED_CLAIM_TEXTS || '';

    // Strip ignorable patterns from a copy of the narrative
    // ID tokens
    text = text.replace(/A\d{7}/g, ' ');
    text = text.replace(/TX\d{8,}/g, ' ');
    text = text.replace(/FND-\d+/g, ' ');
    text = text.replace(/TYP-\d+/g, ' ');
    text = text.replace(/OB-\d+/g, ' ');
    text = text.replace(/CL-\d+/g, ' ');
    text = text.replace(/\[C\d+\]/g, ' ');
    text = text.replace(/STR-\d{4,}-\d+/g, ' ');
    text = text.replace(/C-?\d{2}\b/g, ' ');

    // Article and regulation references
    text = text.replace(/Art\.?\s*\d+(\.\d+)*/gi, ' ');
    text = text.replace(/FC-\d+(\.\d+)*/gi, ' ');
    text = text.replace(/Section\s+\d+(\.\d+)*/gi, ' ');
    text = text.replace(/Article\s+\d+(\.\d+)*/gi, ' ');

    // Dates: YYYY-MM-DD with optional HH:MM
    text = text.replace(/\d{4}-\d{2}-\d{2}(\s+\d{2}:\d{2}(:\d{2})?)?/g, ' ');
    // DD/MM/YYYY
    text = text.replace(/\d{2}\/\d{2}\/\d{4}/g, ' ');

    // Standalone 4-digit years 2020-2039
    text = text.replace(/\b20[2-3]\d\b/g, ' ');

    // Extract remaining numbers (including comma-formatted decimals)
    var matches = text.match(/[\d,]+\.?\d*/g) || [];

    // Normalise: strip commas, parse as float, keep only real numbers
    // Ignore small numbers (< 1000) — these are regulatory boilerplate (days, counts, sections)
    var nums = [];
    for (var i = 0; i < matches.length; i++) {
        var raw = matches[i].replace(/,/g, '');
        if (raw === '' || raw === '.') continue;
        var val = parseFloat(raw);
        if (isNaN(val)) continue;
        if (val < 1000) continue;
        // Deduplicate
        var isDup = false;
        for (var j = 0; j < nums.length; j++) {
            if (Math.abs(nums[j] - val) < 0.005) { isDup = true; break; }
        }
        if (!isDup) nums.push(val);
    }

    // Normalise claim texts the same way (strip commas)
    var claimNorm = claimTexts.replace(/,/g, '');

    var violations = [];
    for (var k = 0; k < nums.length; k++) {
        var n = nums[k];
        var found = false;
        // Check integer representation
        if (n === Math.floor(n)) {
            if (claimNorm.indexOf(n.toString()) >= 0) found = true;
        }
        // Check with 2-decimal representation
        if (!found && claimNorm.indexOf(n.toFixed(2)) >= 0) found = true;
        // Check natural string (no trailing zeros)
        if (!found && claimNorm.indexOf(parseFloat(n.toFixed(6)).toString()) >= 0) found = true;

        if (!found) violations.push(n.toString());
    }

    return {
        numbers_checked: nums.length,
        violations: violations,
        passed: violations.length === 0
    };
$$;

GRANT USAGE ON FUNCTION ARGUS.GOVERNED.FN_GROUNDING_CHECK(STRING, STRING) TO ROLE ARGUS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. SP_DRAFT_FILING — per-bank STR drafts + control-gap memo (LLM prose only)
--    Uses DECLARE cursor + RESULTSET pattern for Snowflake SQL scripting.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE SP_DRAFT_FILING(P_FINDING_ID STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_status STRING;
    v_typology_id STRING;
    v_title STRING;
    v_banks ARRAY;
    v_total_value FLOAT;
    NL STRING DEFAULT CHR(10);
    v_sample_str STRING;
    v_filing_count NUMBER DEFAULT 0;
    v_retry NUMBER;
    v_max_retries NUMBER DEFAULT 3;
    v_grounding_violations STRING;
    v_bid STRING;
    v_bname STRING;
    v_breg STRING;
    v_bfiu STRING;
    v_bank_claims STRING;
    v_bank_accounts STRING;
    v_bank_txn_ids STRING;
    v_prompt STRING;
    v_narrative STRING;
    v_other_bank_acct_leak NUMBER;
    v_grounding_ok BOOLEAN;
    v_cited_claims ARRAY;
    v_grounding_details VARIANT;
    v_filing_id STRING;
    v_filing_status STRING;
    v_gap_claims STRING;
    v_memo_prompt STRING;
    v_memo_narrative STRING;
    v_memo_cited ARRAY;
    v_cited_claim_texts STRING;
    v_number_grounding VARIANT;
BEGIN
    v_status := (SELECT status FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);
    v_typology_id := (SELECT typology_id FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);
    v_title := (SELECT title FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);
    v_banks := (SELECT banks_involved FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);
    v_total_value := (SELECT total_value FROM ARGUS.GOVERNED.FINDING WHERE finding_id = :P_FINDING_ID);

    IF (v_status IS NULL) THEN
        RETURN 'ERROR: finding ' || :P_FINDING_ID || ' not found';
    END IF;
    IF (v_status != 'VERIFIED') THEN
        RETURN 'REFUSED: finding ' || :P_FINDING_ID || ' is ' || v_status ||
               ' — only VERIFIED findings may be filed';
    END IF;

    v_sample_str := (SELECT CONTENT FROM ARGUS.GOVERNED.DOCUMENTS WHERE doc_type = 'filing' LIMIT 1);

    -- Iterate involved banks via LET RESULTSET + cursor
    LET rs RESULTSET := (
        SELECT b.bank_id, b.bank_name, b.regulator,
               CASE b.regulator
                   WHEN 'CBUAE' THEN 'UAE Financial Intelligence Unit (goAML)'
                   WHEN 'SAMA'  THEN 'General Directorate of Financial Investigation (GDFI)'
                   WHEN 'CBB'   THEN 'Financial Intelligence Directorate (FID), Bahrain'
               END AS fiu
          FROM ARGUS.RAW.BANKS b
         WHERE ARRAY_CONTAINS(b.bank_id::VARIANT, :v_banks)
         ORDER BY b.bank_id);
    LET c1 CURSOR FOR rs;

    FOR bank_rec IN c1 DO
        v_bid := bank_rec.bank_id;
        v_bname := bank_rec.bank_name;
        v_breg := bank_rec.regulator;
        v_bfiu := bank_rec.fiu;

        -- Collect claims relevant to this bank
        v_bank_claims := (
            SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
                'claim_id', claim_id, 'claim_type', claim_type,
                'claim_text', claim_text,
                'bank_id', COALESCE(bank_id, 'CROSS_BANK'),
                'structured_refs', structured_refs,
                'clause_refs', clause_refs))::STRING
              FROM ARGUS.GOVERNED.FINDING_CLAIM
             WHERE finding_id = :P_FINDING_ID AND verified = TRUE
               AND (bank_id = :v_bid OR bank_id IS NULL
                    OR claim_type IN ('REGULATORY', 'CONTROL_GAP', 'ROLE')));

        v_bank_accounts := (
            SELECT ARRAY_AGG(te.entity_id)::STRING
              FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
             WHERE te.typology_id = :v_typology_id AND te.bank_id = :v_bid);

        v_bank_txn_ids := (
            SELECT ARRAY_AGG(t.txn_id)::STRING
              FROM ARGUS.RAW.TRANSACTIONS t
              JOIN ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te ON te.entity_id = t.account_id
             WHERE te.typology_id = :v_typology_id AND te.bank_id = :v_bid);

        -- Build prompt with data minimisation instructions
        v_prompt := 'You are drafting a Suspicious Transaction Report (STR) for ' ||
            v_bname || ' (' || v_bid || '), regulated by ' || v_breg ||
            ', to be filed with ' || v_bfiu || '.' || NL || NL ||
            'Finding: ' || :P_FINDING_ID || ' — ' || v_title || NL ||
            'Total network value: AED ' || v_total_value::STRING || NL || NL ||
            'VERIFIED CLAIMS (cite as [C01], [C02] etc.):' || NL || v_bank_claims || NL || NL ||
            'THIS BANKS OWN ACCOUNTS: ' || v_bank_accounts || NL ||
            'THIS BANKS OWN TXN IDs: ' || v_bank_txn_ids || NL || NL ||
            'DATA MINIMISATION: Cite ONLY this banks own IDs. For cross-bank signals, ' ||
            'write "accounts at other consortium institutions" without naming them.' || NL || NL ||
            'IMPORTANT: The SUMMARY claim contains the finding totals. You MUST cite it ' ||
            '(e.g. [Cxx]) when mentioning total network value or aggregate figures. ' ||
            'Every monetary amount in your narrative must appear verbatim in a cited claim. ' ||
            'Do NOT compute subtotals, sums, or derived amounts — only use numbers from claims.' || NL || NL ||
            'STYLE from past filing:' || NL || COALESCE(v_sample_str, '') || NL || NL ||
            'Write ## Narrative, cite [C01] etc., end with ## Supporting Evidence.';

        -- Retry loop: up to 3 attempts on grounding failure
        v_retry := 0;
        v_grounding_ok := FALSE;
        WHILE (v_retry < v_max_retries AND NOT v_grounding_ok) DO
            IF (v_retry > 0) THEN
                v_prompt := v_prompt || NL || NL ||
                    'PREVIOUS ATTEMPT FAILED GROUNDING CHECK. Violations: ' ||
                    COALESCE(v_grounding_violations, 'unknown') ||
                    '. Fix: use ONLY numbers that appear verbatim in the cited claims. ' ||
                    'Do NOT invent, round, or compute any monetary amounts.';
            END IF;

            v_narrative := (SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-5', :v_prompt));

            -- Grounding check: no other bank's account IDs in narrative
            v_other_bank_acct_leak := (
                SELECT COUNT(*) FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE te
                 WHERE te.typology_id = :v_typology_id AND te.bank_id != :v_bid
                   AND CONTAINS(:v_narrative, te.entity_id));

            v_cited_claims := (
                SELECT ARRAY_AGG(DISTINCT REGEXP_SUBSTR(v.value::STRING, 'C[0-9]+'))
                  FROM TABLE(FLATTEN(input => REGEXP_SUBSTR_ALL(:v_narrative, '\\[C[0-9]+\\]'))) v
                 WHERE REGEXP_SUBSTR(v.value::STRING, 'C[0-9]+') IS NOT NULL);

            v_cited_claim_texts := (
                SELECT COALESCE(LISTAGG(fc.claim_text, ' | '), '')
                  FROM ARGUS.GOVERNED.FINDING_CLAIM fc
                 WHERE fc.finding_id = :P_FINDING_ID AND fc.verified = TRUE
                   AND fc.claim_id IN (
                       SELECT :P_FINDING_ID || '-' || v2.value::STRING
                         FROM TABLE(FLATTEN(input => :v_cited_claims)) v2));

            v_number_grounding := (
                SELECT ARGUS.GOVERNED.FN_GROUNDING_CHECK(:v_narrative, :v_cited_claim_texts));

            v_grounding_ok := (v_other_bank_acct_leak = 0)
                              AND (v_number_grounding:"passed"::BOOLEAN = TRUE);

            IF (NOT v_grounding_ok) THEN
                v_grounding_violations := 'leaks=' || v_other_bank_acct_leak::STRING ||
                    ', number_violations=' || COALESCE(v_number_grounding:"violations"::STRING, '?');
            END IF;

            v_retry := v_retry + 1;
        END WHILE;

        v_grounding_details := (SELECT OBJECT_CONSTRUCT(
            'other_bank_account_leaks', :v_other_bank_acct_leak,
            'cited_claims', :v_cited_claims,
            'numbers_checked', :v_number_grounding:"numbers_checked",
            'number_violations', :v_number_grounding:"violations",
            'grounding_passed', :v_grounding_ok,
            'attempts', :v_retry));

        v_filing_id := :P_FINDING_ID || '-STR-' || v_bid;
        v_filing_status := IFF(v_grounding_ok, 'DRAFT_PENDING_HUMAN', 'REJECTED_GROUNDING');

        INSERT INTO ARGUS.GOVERNED.FILING
            (filing_id, finding_id, filing_type, bank_id, regulator, fiu,
             narrative_md, cited_claims, status, grounding_check)
        SELECT :v_filing_id, :P_FINDING_ID, 'STR', :v_bid, :v_breg, :v_bfiu,
               :v_narrative, :v_cited_claims, :v_filing_status, :v_grounding_details;

        v_filing_count := v_filing_count + 1;
    END FOR;

    -- ── CONTROL_GAP_MEMO ──
    v_gap_claims := (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
            'claim_id', claim_id, 'claim_type', claim_type,
            'claim_text', claim_text, 'clause_refs', clause_refs))::STRING
          FROM ARGUS.GOVERNED.FINDING_CLAIM
         WHERE finding_id = :P_FINDING_ID AND verified = TRUE
           AND claim_type IN ('CONTROL_GAP', 'REGULATORY', 'SUMMARY'));

    IF (v_gap_claims IS NOT NULL AND LENGTH(v_gap_claims) > 5) THEN
        v_memo_prompt := 'You are drafting a Board Control Gap Memorandum for the ARGUS consortium.' ||
            NL || NL || 'Finding: ' || :P_FINDING_ID || ' — ' || v_title || NL ||
            'Total network value: AED ' || v_total_value::STRING || NL || NL ||
            'CONTROL GAP, REGULATORY AND SUMMARY CLAIMS:' || NL || v_gap_claims || NL || NL ||
            'IMPORTANT: Cite claims using [C01], [C02] etc. The SUMMARY claim contains ' ||
            'the finding totals — you MUST cite it when mentioning total network value or ' ||
            'aggregate figures. Every monetary amount must appear verbatim in a cited claim. ' ||
            'Do NOT compute subtotals, sums, or derived amounts — only use numbers from claims.' || NL || NL ||
            'Write ## Board Control Gap Memorandum. For each gap: obligation, regulation, ' ||
            'missing control, risk. Cite [C01] etc. End with ## Recommended Actions.';

        -- Retry loop for memo
        v_retry := 0;
        v_grounding_ok := FALSE;
        WHILE (v_retry < v_max_retries AND NOT v_grounding_ok) DO
            IF (v_retry > 0) THEN
                v_memo_prompt := v_memo_prompt || NL || NL ||
                    'PREVIOUS ATTEMPT FAILED GROUNDING CHECK. Violations: ' ||
                    COALESCE(v_grounding_violations, 'unknown') ||
                    '. Fix: use ONLY numbers that appear verbatim in the cited claims.';
            END IF;

            v_memo_narrative := (SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-5', :v_memo_prompt));

            v_memo_cited := (
                SELECT ARRAY_AGG(DISTINCT REGEXP_SUBSTR(v.value::STRING, 'C[0-9]+'))
                  FROM TABLE(FLATTEN(input => REGEXP_SUBSTR_ALL(:v_memo_narrative, '\\[C[0-9]+\\]'))) v
                 WHERE REGEXP_SUBSTR(v.value::STRING, 'C[0-9]+') IS NOT NULL);

            v_cited_claim_texts := (
                SELECT COALESCE(LISTAGG(fc.claim_text, ' | '), '')
                  FROM ARGUS.GOVERNED.FINDING_CLAIM fc
                 WHERE fc.finding_id = :P_FINDING_ID AND fc.verified = TRUE
                   AND fc.claim_id IN (
                       SELECT :P_FINDING_ID || '-' || v2.value::STRING
                         FROM TABLE(FLATTEN(input => :v_memo_cited)) v2));

            v_number_grounding := (
                SELECT ARGUS.GOVERNED.FN_GROUNDING_CHECK(:v_memo_narrative, :v_cited_claim_texts));

            v_grounding_ok := (v_number_grounding:"passed"::BOOLEAN = TRUE);

            IF (NOT v_grounding_ok) THEN
                v_grounding_violations := 'number_violations=' ||
                    COALESCE(v_number_grounding:"violations"::STRING, '?');
            END IF;

            v_retry := v_retry + 1;
        END WHILE;

        v_grounding_details := (SELECT OBJECT_CONSTRUCT(
            'cited_claims', :v_memo_cited,
            'numbers_checked', :v_number_grounding:"numbers_checked",
            'number_violations', :v_number_grounding:"violations",
            'grounding_passed', :v_grounding_ok,
            'attempts', :v_retry));

        INSERT INTO ARGUS.GOVERNED.FILING
            (filing_id, finding_id, filing_type, bank_id, regulator, fiu,
             narrative_md, cited_claims, status, grounding_check)
        SELECT :P_FINDING_ID || '-MEMO', :P_FINDING_ID, 'CONTROL_GAP_MEMO',
               NULL, NULL, NULL, :v_memo_narrative, :v_memo_cited,
               IFF(:v_grounding_ok, 'DRAFT_PENDING_HUMAN', 'REJECTED_GROUNDING'),
               :v_grounding_details;

        v_filing_count := v_filing_count + 1;
    END IF;

    RETURN 'Created ' || v_filing_count || ' filing(s) for finding ' || :P_FINDING_ID;
END;
$$;
