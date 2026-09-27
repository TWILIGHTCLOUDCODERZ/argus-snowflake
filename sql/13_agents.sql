/* ============================================================================
   ARGUS · 13_agents.sql — Cortex Agents + Orchestrator infrastructure
   Created by TCC · CoCo Session S10

   Objects:
     UDF   : FN_TYPOLOGY_CARD
     Table : AGENT_RUN_LOG
     Agents: EVIDENCE_AGENT, POLICY_AGENT
   The orchestrator lives in app/orchestrator.py (Python, calls agents via
   DATA_AGENT_RUN + procedures directly for the Verifier / Narrative steps).
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. SUPPORTING OBJECTS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Typology card lookup — used as a custom tool by EVIDENCE_AGENT.
-- Parameter name matches the input_schema so Cortex Agents can call it with
-- named arguments.
-- Parameter name P_TYP_ID avoids collision with the TYPOLOGY.TYPOLOGY_ID column.
-- The Cortex Agent input_schema also uses p_typ_id so named-argument calls match.
CREATE OR REPLACE FUNCTION ARGUS.GOVERNED.FN_TYPOLOGY_CARD(P_TYP_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
    SELECT COALESCE(card_md, 'No typology card found for ' || P_TYP_ID)
      FROM ARGUS.GOVERNED.TYPOLOGY
     WHERE typology_id = P_TYP_ID
$$;

GRANT USAGE ON FUNCTION ARGUS.GOVERNED.FN_TYPOLOGY_CARD(STRING) TO ROLE ARGUS_ANALYST;

-- Handoff log — every orchestrator step is recorded for replay / audit.
CREATE TABLE IF NOT EXISTS ARGUS.GOVERNED.AGENT_RUN_LOG (
    run_id        STRING,
    step          NUMBER,
    from_agent    STRING,
    to_agent      STRING,
    input_summary STRING,
    output_summary STRING,
    refs          ARRAY,
    started_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    duration_ms   NUMBER
);

GRANT SELECT ON ARGUS.GOVERNED.AGENT_RUN_LOG TO ROLE ARGUS_ANALYST;
GRANT INSERT ON ARGUS.GOVERNED.AGENT_RUN_LOG TO ROLE ARGUS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. EVIDENCE AGENT  (fraud / AML evidence specialist)
--    Tools: Cortex Analyst over ARGUS_FRAUD_SV  +  FN_TYPOLOGY_CARD (custom)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE AGENT ARGUS.GOVERNED.EVIDENCE_AGENT
  COMMENT = 'ARGUS Evidence Agent: answers what happened and why an account was flagged.'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    tool_not_accessible: reject
    budget:
      seconds: 60
      tokens: 16000

  instructions:
    response: >
      You are the ARGUS Evidence Agent. Your job is to provide transaction-level
      evidence about fraud signals, hub detections, shared identities, and
      typology memberships.  Always cite specific transaction IDs, account IDs,
      amounts, and dates.  Never speculate beyond what the data shows.  Never
      reveal raw PII (national IDs, phone numbers) — use hashes only.
      If asked about filing decisions, say: "Filing decisions are made by the
      Verifier — I provide the evidence only."
    orchestration: >
      Use the FraudAnalyst tool for any question about transactions, accounts,
      hub detections, alerts, structuring, shared signals, or ring membership.
      Use the TypologyCard tool to retrieve the human-readable explanation card
      for a specific typology ID.  Always start with FraudAnalyst for data,
      then supplement with TypologyCard if a typology ID is mentioned.

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: FraudAnalyst
        description: >
          Converts natural language to SQL over the ARGUS fraud semantic view.
          Contains transactions, accounts, customers (PII-free), hub detections,
          structuring signals, shared bad-actor signals, alerts, and typology
          evidence (ring membership with roles).
    - tool_spec:
        type: generic
        name: TypologyCard
        description: >
          Retrieves the markdown typology card for a given typology ID (e.g.
          TYP-0003).  The card contains the classification, summary narrative,
          member count, banks involved, total value, and time window.
        input_schema:
          type: object
          properties:
            p_typ_id:
              type: string
              description: "The typology ID, e.g. TYP-0001, TYP-0003"
          required:
            - p_typ_id

  tool_resources:
    FraudAnalyst:
      semantic_view: ARGUS.GOVERNED.ARGUS_FRAUD_SV
      execution_environment:
        type: warehouse
        warehouse: ARGUS_WH
    TypologyCard:
      type: function
      execution_environment:
        type: warehouse
        warehouse: ARGUS_WH
      identifier: "ARGUS.GOVERNED.FN_TYPOLOGY_CARD"
  $$;

GRANT USAGE ON AGENT ARGUS.GOVERNED.EVIDENCE_AGENT TO ROLE ARGUS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. POLICY AGENT  (regulatory / compliance specialist)
--    Tools: Cortex Search (POLICY_SEARCH)  +  Cortex Analyst (ARGUS_REGTWIN_SV)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE AGENT ARGUS.GOVERNED.POLICY_AGENT
  COMMENT = 'ARGUS Policy Agent: which regulations apply, obligations, control gaps, precedent STRs.'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    tool_not_accessible: reject
    budget:
      seconds: 60
      tokens: 16000

  instructions:
    response: >
      You are the ARGUS Policy Agent. Your job is to identify which regulatory
      obligations apply to a fraud typology, whether controls are adequate,
      and what precedent filings exist.  Always cite specific clause IDs
      (e.g. CL-01), article references, obligation IDs, and regulation titles.
      When discussing control gaps, state severity (HIGH/MEDIUM/NONE) and
      rationale.  Never make filing decisions — that is the Verifier's job.
    orchestration: >
      Use PolicySearch for questions about regulatory text, past STR filings,
      circular contents, or AML policy guidance.  Use RegTwinAnalyst for
      structured queries about obligations, control gaps, typology exposure,
      and regulatory coverage metrics.  For questions like "which obligations
      does typology X touch", start with RegTwinAnalyst.  For questions like
      "what does CBUAE Art 31 say", use PolicySearch.

  tools:
    - tool_spec:
        type: cortex_search
        name: PolicySearch
        description: >
          Searches parsed GCC regulatory circulars (CBUAE, SAMA, CBB, FATF)
          and past STR filings.  Returns relevant text chunks with document
          type and regulator attribution.
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: RegTwinAnalyst
        description: >
          Converts natural language to SQL over the ARGUS regulatory digital
          twin semantic view.  Contains regulations, clauses, obligations,
          control gaps, and typology exposure (which typologies touch which
          obligations, with gap severity).

  tool_resources:
    PolicySearch:
      search_service: ARGUS.GOVERNED.POLICY_SEARCH
      max_results: 5
      columns_and_descriptions:
        CHUNK:
          description: "The text chunk from the regulatory document"
          type: string
          searchable: true
          filterable: false
        DOC_TYPE:
          description: "Document type: circular or str_filing"
          type: string
          searchable: false
          filterable: true
        REGULATOR:
          description: "Regulator: CBUAE, SAMA, CBB, or FATF"
          type: string
          searchable: false
          filterable: true
    RegTwinAnalyst:
      semantic_view: ARGUS.GOVERNED.ARGUS_REGTWIN_SV
      execution_environment:
        type: warehouse
        warehouse: ARGUS_WH
  $$;

GRANT USAGE ON AGENT ARGUS.GOVERNED.POLICY_AGENT TO ROLE ARGUS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. FUTURE GRANTS (cover CREATE OR REPLACE re-deploys)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Future grants so re-deploy doesn't break access.
GRANT USAGE ON FUTURE AGENTS IN SCHEMA ARGUS.GOVERNED TO ROLE ARGUS_ANALYST;
