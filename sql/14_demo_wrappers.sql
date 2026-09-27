/* ============================================================================
   ARGUS · 14_demo_wrappers.sql — Narrow owner's-rights demo procedures
   Created by TCC · CoCo Session S11

   Three wrapper procedures that let ARGUS_ANALYST drive the demo without
   needing direct write access to RAW or GOVERNED tables.  All execute as
   OWNER (ACCOUNTADMIN) so they can write to tables the analyst cannot.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;
USE SCHEMA ARGUS.GOVERNED;

-- =========================================================================
-- 1. SP_DEMO_NEXT_BATCH — deliver one live batch + evaluate alerts
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_DEMO_NEXT_BATCH()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    LET v_batch_result STRING;
    LET v_alert_result STRING;
    CALL ARGUS.RAW.SP_DELIVER_NEXT_BATCH() INTO :v_batch_result;
    CALL ARGUS.GOVERNED.SP_RAISE_ALERTS() INTO :v_alert_result;
    LET v_alert_count INT := (SELECT COUNT(*) FROM ARGUS.GOVERNED.LIVE_ALERTS);
    RETURN :v_batch_result || ' | Alerts: ' || :v_alert_count;
END;
$$;

-- =========================================================================
-- 2. SP_DEMO_REDISCOVER — run typology discovery
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_DEMO_REDISCOVER()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    LET v_result STRING;
    CALL ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES() INTO :v_result;
    RETURN :v_result;
END;
$$;

-- =========================================================================
-- 3. SP_DEMO_RESET — full demo reset: clean live data, remove live-only
--    findings/filings, rediscover baseline typologies
-- =========================================================================
CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_DEMO_RESET()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    LET v_reset STRING;
    CALL ARGUS.RAW.SP_RESET_LIVE_DEMO() INTO :v_reset;

    -- Remove findings/filings for typologies that only exist in live data
    -- (i.e. any typology not in the baseline 5). After reset, rediscovery
    -- will restore the baseline set.  Keep findings for baseline typologies.
    DELETE FROM ARGUS.GOVERNED.FILING
    WHERE finding_id IN (
        SELECT finding_id FROM ARGUS.GOVERNED.FINDING
        WHERE typology_id NOT IN (SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY)
          AND typology_id LIKE 'TYP-%'
    );
    DELETE FROM ARGUS.GOVERNED.FINDING_CLAIM
    WHERE finding_id IN (
        SELECT finding_id FROM ARGUS.GOVERNED.FINDING
        WHERE typology_id NOT IN (SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY)
          AND typology_id LIKE 'TYP-%'
    );
    DELETE FROM ARGUS.GOVERNED.FINDING
    WHERE typology_id NOT IN (SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY)
      AND typology_id LIKE 'TYP-%';

    -- Rediscover to restore baseline typologies
    LET v_discover STRING;
    CALL ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES() INTO :v_discover;

    -- Suspend root task
    ALTER TASK ARGUS.RAW.TASK_FEED_LIVE SUSPEND;

    RETURN :v_reset || ' | ' || :v_discover || ' | Root task suspended';
END;
$$;

-- =========================================================================
-- 4. GRANTS — analyst can call these three wrappers
-- =========================================================================
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_DEMO_NEXT_BATCH() TO ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_DEMO_REDISCOVER() TO ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_DEMO_RESET() TO ROLE ARGUS_ANALYST;

-- Analyst also needs USAGE on the S9 procedures (called by the orchestrator)
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_BUILD_FINDING(VARCHAR) TO ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_BUILD_FINDING_ADHOC(ARRAY) TO ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_VERIFY_FINDING(VARCHAR) TO ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_DRAFT_FILING(VARCHAR) TO ROLE ARGUS_ANALYST;

-- Analyst can approve filing drafts — through a narrow procedure only.
-- (Replaces a table-wide UPDATE grant, which would also have let the analyst rewrite a
-- draft's narrative or approve a draft the grounding check had rejected.)
ALTER TABLE ARGUS.GOVERNED.FILING ADD COLUMN IF NOT EXISTS approved_at TIMESTAMP_NTZ;

CREATE OR REPLACE PROCEDURE ARGUS.GOVERNED.SP_APPROVE_FILING(P_FILING_ID STRING, P_APPROVER STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    LET v_status STRING := (SELECT MAX(status) FROM ARGUS.GOVERNED.FILING WHERE filing_id = :P_FILING_ID);
    IF (v_status IS NULL) THEN
        RETURN 'REFUSED: filing ' || :P_FILING_ID || ' not found';
    END IF;
    IF (v_status <> 'DRAFT_PENDING_HUMAN') THEN
        RETURN 'REFUSED: only drafts awaiting review can be approved (status is ' || :v_status || ')';
    END IF;
    UPDATE ARGUS.GOVERNED.FILING
       SET status = 'APPROVED', approved_by = :P_APPROVER, approved_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
     WHERE filing_id = :P_FILING_ID AND status = 'DRAFT_PENDING_HUMAN';
    RETURN 'APPROVED: ' || :P_FILING_ID || ' by ' || :P_APPROVER || ' (not sent)';
END;
$$;

REVOKE UPDATE ON TABLE ARGUS.GOVERNED.FILING FROM ROLE ARGUS_ANALYST;
GRANT USAGE ON PROCEDURE ARGUS.GOVERNED.SP_APPROVE_FILING(VARCHAR, VARCHAR) TO ROLE ARGUS_ANALYST;

-- Analyst can write to AGENT_RUN_LOG (orchestrator logs handoffs)
GRANT INSERT ON TABLE ARGUS.GOVERNED.AGENT_RUN_LOG TO ROLE ARGUS_ANALYST;
