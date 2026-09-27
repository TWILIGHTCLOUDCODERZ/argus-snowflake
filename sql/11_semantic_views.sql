-- ============================================================================
-- ARGUS · Semantic Views — Single Source of Truth
-- Created by TCC · Session S6c (semantic repair)
--
-- This file is THE canonical definition for both semantic views.
-- Deploy with: snowsql or CoCo sql_execute, then re-export YAML with
--   SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW('ARGUS.GOVERNED.<view_name>')
-- ============================================================================

USE SCHEMA ARGUS.GOVERNED;

-- --------------------------------------------------------------------------
-- 1. ARGUS_FRAUD_SV  (fraud / AML semantic view, PII-free)
--
-- FIX (S6c): removed redundant direct-to-BANKS relationships from
-- TRANSACTIONS, HUB_ACCOUNTS, STRUCTURING, ALERTS. Each of those tables
-- already reaches BANKS through ACCOUNTS, so the extra edges created a
-- "multi-path relationship" error.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_FRAUD_SV
  tables (
    ARGUS.RAW.BANKS primary key (BANK_ID)
      with synonyms=('institution','consortium member','financial institution')
      comment='Participating GCC banks / NBFCs in the ARGUS consortium',
    ARGUS.RAW.CUSTOMERS primary key (CUSTOMER_ID)
      with synonyms=('client','account holder')
      comment='Customers. Only risk rating + hashed identifiers are exposed.',
    ARGUS.RAW.ACCOUNTS primary key (ACCOUNT_ID)
      with synonyms=('account','IBAN')
      comment='Deposit / current / wallet accounts',
    ARGUS.RAW.TRANSACTIONS primary key (TXN_ID)
      with synonyms=('payment','transfer','money movement','transaction')
      comment='All money movements. direction is credit (inbound) or debit (outbound). channel is cash, transfer, card, wallet. counterparty_bank is the other partys bank. IMPORTANT: value moving through ring funnel accounts = SUM of credit transactions from consortium banks only (counterparty_bank IN BANK_A,BANK_B,BANK_C). This includes same-bank transfers within the ring.',
    LOGINS as ARGUS.RAW.DEVICE_LOGINS primary key (LOGIN_ID)
      with synonyms=('session','device login')
      comment='Login events with hashed device / IP',
    HUB_ACCOUNTS as ARGUS.CURATED.DT_HUB_ACCOUNTS primary key (ACCOUNT_ID)
      with synonyms=('mule hub','consolidation account','fan-in hub','collection point','emerging fraud','cross-bank fraud exposure')
      comment='Pre-computed: accounts receiving inbound transfers from 2+ consortium banks in a 7-day burst. These ARE the emerging cross-bank fraud hubs.',
    STRUCTURING as ARGUS.CURATED.DT_STRUCTURING primary key (ACCOUNT_ID)
      with synonyms=('smurfing','structuring account','near-CTR deposits','cash deposits under threshold','deposits below reporting limit')
      comment='Pre-computed: accounts with clusters of cash deposits just below the AED 55000 CTR reporting threshold.',
    SHARED_SIGNALS as ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL primary key (IDENTIFIER_HASH)
      with synonyms=('shared identity','cross-bank signal','bad actor signal','identity fraud signal','shared device','shared national ID')
      comment='Privacy-preserving cross-bank signal: hashed identifiers (national_id, device, phone) seen at 2+ banks. Filter by identifier_type IN (national_id, device, phone) for identity sharing queries.',
    ALERTS as ARGUS.GOVERNED.LIVE_ALERTS primary key (ALERT_ID)
      with synonyms=('alert','fraud alert','live alert')
      comment='Active alerts raised by the pipeline. Each alert links to one account.',
    EVIDENCE as ARGUS.GOVERNED.TYPOLOGY_EVIDENCE primary key (ENTITY_ID)
      with synonyms=('ring member','typology member','ring evidence','ring membership','funnel member','collection member')
      comment='Typology membership: maps entities (accounts) to their role within a detected fraud ring. Role values: source_mule, funnel, consolidation. Funnel accounts of a ring = role IN (funnel, consolidation). To compute value through funnel accounts, use the consortium_inbound_amount metric with evidence filtered by typology_id and role.'
  )
  relationships (
    ACCOUNTS_TO_BANKS      as ACCOUNTS(BANK_ID)       references BANKS(BANK_ID),
    ACCOUNTS_TO_CUSTOMERS  as ACCOUNTS(CUSTOMER_ID)    references CUSTOMERS(CUSTOMER_ID),
    TXN_TO_ACCOUNTS        as TRANSACTIONS(ACCOUNT_ID) references ACCOUNTS(ACCOUNT_ID),
    -- S6c: removed TXN_TO_BANKS (multi-path via ACCOUNTS)
    LOGINS_TO_ACCOUNTS     as LOGINS(ACCOUNT_ID)       references ACCOUNTS(ACCOUNT_ID),
    HUB_TO_ACCOUNTS        as HUB_ACCOUNTS(ACCOUNT_ID) references ACCOUNTS(ACCOUNT_ID),
    -- S6c: removed HUB_TO_BANKS (multi-path via ACCOUNTS)
    STRUCTURING_TO_ACCOUNTS as STRUCTURING(ACCOUNT_ID)  references ACCOUNTS(ACCOUNT_ID),
    -- S6c: removed STRUCTURING_TO_BANKS (multi-path via ACCOUNTS)
    ALERTS_TO_ACCOUNTS     as ALERTS(ACCOUNT_ID)        references ACCOUNTS(ACCOUNT_ID),
    -- S6c: removed ALERTS_TO_BANKS (multi-path via ACCOUNTS)
    EVIDENCE_TO_ACCOUNTS   as EVIDENCE(ENTITY_ID)       references ACCOUNTS(ACCOUNT_ID)
  )
  facts (
    TRANSACTIONS.TXN_AMOUNT as amount
      comment='Transaction amount in AED',
    TRANSACTIONS.IS_CROSS_BANK as IFF(counterparty_bank IN ('BANK_A','BANK_B','BANK_C') AND counterparty_bank <> bank_id, 1, 0)
      comment='1 when funds move between two different consortium banks',
    TRANSACTIONS.IS_CONSORTIUM_INBOUND as IFF(direction = 'credit' AND counterparty_bank IN ('BANK_A','BANK_B','BANK_C'), 1, 0)
      comment='1 when this is an inbound credit from any consortium bank (including same-bank). USE THIS for computing value moving through ring funnel/consolidation accounts.',
    TRANSACTIONS.IS_NEAR_CTR as IFF(channel = 'cash' AND direction = 'credit' AND amount BETWEEN 52000 AND 55000, 1, 0)
      comment='1 when a cash deposit sits just under the AED 55000 CTR threshold',
    HUB_ACCOUNTS.HUB_INBOUND_AMOUNT as inbound_amount
      comment='Total inbound cross-bank value received by this hub account in AED',
    HUB_ACCOUNTS.HUB_SOURCE_BANKS as source_banks
      comment='Number of distinct consortium banks sending funds to this hub',
    HUB_ACCOUNTS.HUB_INBOUND_TRANSFERS as inbound_transfers
      comment='Count of inbound cross-bank transfers received by this hub',
    STRUCTURING.NEAR_THRESHOLD_DEPOSITS as near_threshold_deposits
      comment='Count of cash deposits in the 52000-55000 AED range for this account',
    STRUCTURING.STRUCTURING_TOTAL as total_amount
      comment='Sum of near-threshold cash deposits in AED',
    SHARED_SIGNALS.SIGNAL_BANK_COUNT as contributing_bank_count
      comment='Number of different banks where this hashed identifier appeared',
    SHARED_SIGNALS.SIGNAL_RISK_WEIGHT as risk_weight
      comment='Composite risk weight: higher for national_id sharing, scaled by bank count',
    SHARED_SIGNALS.SIGNAL_LINKED_ACCOUNTS as linked_accounts
      comment='Number of distinct accounts linked to this shared identifier',
    ALERTS.ALERT_SOURCE_BANKS as source_banks
      comment='Number of source banks noted in the alert',
    ALERTS.ALERT_INBOUND_AMOUNT as inbound_amount
      comment='Inbound amount captured at alert time in AED'
  )
  dimensions (
    BANKS.BANK_NAME as bank_name,
    BANKS.REGULATOR as regulator with synonyms=('supervisor'),
    BANKS.COUNTRY as country,
    CUSTOMERS.KYC_RISK_RATING as kyc_risk_rating with synonyms=('KYC risk','customer risk'),
    CUSTOMERS.NATIONALITY as nationality,
    CUSTOMERS.NATIONAL_ID_HASH as national_id_hash
      comment='Salted hash only - raw national ID is never exposed',
    ACCOUNTS.ACCOUNT_ID as account_id,
    ACCOUNTS.IBAN as iban,
    ACCOUNTS.ACCOUNT_TYPE as account_type,
    ACCOUNTS.ACCOUNT_STATUS as status,
    TRANSACTIONS.CHANNEL as channel,
    TRANSACTIONS.DIRECTION as direction,
    TRANSACTIONS.PURPOSE_CODE as purpose_code with synonyms=('purpose'),
    TRANSACTIONS.COUNTERPARTY_BANK as counterparty_bank,
    TRANSACTIONS.TXN_DATE as DATE(ts) with synonyms=('date','day'),
    TRANSACTIONS.TXN_WEEK as DATE_TRUNC('week', ts),
    LOGINS.DEVICE_HASH as device_hash
      comment='Hashed device fingerprint',
    HUB_ACCOUNTS.HUB_BURST_START as burst_start
      comment='Earliest transfer in the hub detection burst window',
    HUB_ACCOUNTS.HUB_BURST_END as burst_end
      comment='Latest transfer in the hub detection burst window',
    STRUCTURING.STRUCTURING_ACCOUNT_ID as account_id
      comment='Account ID of the structuring account',
    STRUCTURING.STRUCTURING_BANK_ID as bank_id
      comment='Bank of the structuring account',
    STRUCTURING.STRUCTURING_FIRST_DEPOSIT as first_deposit
      comment='Earliest near-threshold deposit timestamp',
    STRUCTURING.STRUCTURING_LAST_DEPOSIT as last_deposit
      comment='Latest near-threshold deposit timestamp',
    SHARED_SIGNALS.IDENTIFIER_TYPE as identifier_type
      comment='Type of shared identifier: national_id, device, phone, or counterparty_iban',
    SHARED_SIGNALS.IDENTIFIER_HASH as identifier_hash
      comment='Hashed identifier value - no raw PII',
    ALERTS.ALERT_TYPE as alert_type
      comment='Alert category: hub_detection, structuring, shared_identity',
    ALERTS.ALERT_STATUS as status
      comment='Current alert status: OPEN, INVESTIGATING, CLOSED',
    ALERTS.ALERT_RAISED_AT as raised_at
      comment='Timestamp when the alert was raised',
    EVIDENCE.TYPOLOGY_ID as typology_id
      comment='Typology/ring identifier (e.g. RING-001)',
    EVIDENCE.ENTITY_TYPE as entity_type
      comment='Type of entity in the ring: account or customer',
    EVIDENCE.ROLE as role with synonyms=('ring role','member role')
      comment='Role within the typology: source_mule, funnel, consolidation, layering_hop',
    EVIDENCE.EVIDENCE_BANK as bank_id
      comment='Bank where this ring member is located'
  )
  metrics (
    TRANSACTIONS.TOTAL_AMOUNT as SUM(transactions.txn_amount) with synonyms=('value','volume'),
    TRANSACTIONS.TXN_COUNT as COUNT(transactions.txn_amount),
    TRANSACTIONS.CROSS_BANK_AMOUNT as SUM(transactions.txn_amount * transactions.is_cross_bank) with synonyms=('inter-bank flow'),
    TRANSACTIONS.CROSS_BANK_TXN_COUNT as SUM(transactions.is_cross_bank),
    TRANSACTIONS.CONSORTIUM_INBOUND_AMOUNT as SUM(transactions.txn_amount * transactions.is_consortium_inbound) with synonyms=('value through accounts','value moving through','ring value','total value through funnel accounts','total value through consolidation')
      comment='Sum of inbound credit transactions from consortium banks. This is the correct measure for total value moving through funnel/consolidation accounts of a ring.',
    TRANSACTIONS.NEAR_CTR_DEPOSIT_COUNT as SUM(transactions.is_near_ctr) with synonyms=('structuring deposits','smurfing deposits'),
    ACCOUNTS.ACCOUNT_COUNT as COUNT(DISTINCT accounts.account_id),
    ALERTS.ALERT_COUNT as COUNT(DISTINCT alerts.alert_id) with synonyms=('number of alerts'),
    EVIDENCE.RING_MEMBER_COUNT as COUNT(DISTINCT evidence.entity_id) with synonyms=('members in ring')
  )
  comment='ARGUS governed fraud semantic view. PII-free. INSTRUCTIONS: (1) All data is from September 2026. Do NOT filter by CURRENT_DATE. (2) emerging cross-bank fraud = hub_accounts (DT_HUB_ACCOUNTS). (3) When asked why an account was flagged or should we file, ALWAYS generate SQL to retrieve evidence data (cross-bank transactions, alerts, hub detection, shared signals for that account). The filing decision is for compliance officers. Show the data. Do not refuse. (4) value moving through funnel/collection/consolidation accounts = consortium_inbound_amount metric (SUM credit transactions from consortium banks including same-bank ring transfers). (5) reporting threshold = AED 55000. just under = cash deposits 52000-55000. (6) shared identity = shared_signals where identifier_type IN (national_id, device, phone). (7) suspicious activity for an account = check hub_accounts, structuring, shared_signals, alerts, evidence tables for that account plus cross-bank transactions.';

-- --------------------------------------------------------------------------
-- 2. ARGUS_REGTWIN_SV  (regulatory digital twin)
--
-- FIX (S6c): added gap_flag fact, open_gap_count / obligation_count metrics,
-- plus missing dimensions (clause_text, required_scope). Aliased table names
-- to plural form (regulations, clauses, obligations) for consistency with
-- the YAML and verified queries.
-- --------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_REGTWIN_SV
  tables (
    REGULATIONS as ARGUS.GOVERNED.REGULATION primary key (REGULATION_ID)
      with synonyms=('circular','rulebook','regulation'),
    CLAUSES as ARGUS.GOVERNED.CLAUSE primary key (CLAUSE_ID)
      with synonyms=('article','section'),
    OBLIGATIONS as ARGUS.GOVERNED.OBLIGATION primary key (OBLIGATION_ID)
      with synonyms=('requirement','duty','regulatory requirement'),
    GAPS as ARGUS.GOVERNED.CONTROL_GAP primary key (OBLIGATION_ID)
      with synonyms=('control gap','coverage gap'),
    ARGUS.GOVERNED.TYPOLOGY_EXPOSURE primary key (TYPOLOGY_ID,OBLIGATION_ID)
      with synonyms=('typology gap','typology obligation','ring exposure','regulatory exposure','control adequacy')
      comment='Pre-computed typology-to-obligation mapping with gap analysis. Shows which regulatory obligations each typology touches and whether controls are adequate. is_gap TRUE means gap exists. severity HIGH/MEDIUM/NONE.'
  )
  relationships (
    CLAUSE_TO_REG          as CLAUSES(REGULATION_ID)           references REGULATIONS(REGULATION_ID),
    OBLIGATION_TO_CL       as OBLIGATIONS(CLAUSE_ID)           references CLAUSES(CLAUSE_ID),
    GAP_TO_OBLIGATION      as GAPS(OBLIGATION_ID)              references OBLIGATIONS(OBLIGATION_ID),
    EXPOSURE_TO_OBLIGATION as TYPOLOGY_EXPOSURE(OBLIGATION_ID) references OBLIGATIONS(OBLIGATION_ID)
  )
  facts (
    GAPS.GAP_FLAG as IFF(is_gap, 1, 0)
      comment='Binary flag: 1 when there is a control gap, 0 when adequately covered'
  )
  dimensions (
    REGULATIONS.REGULATION_ID as regulation_id,
    REGULATIONS.REGULATOR as regulator,
    REGULATIONS.TITLE as title,
    CLAUSES.CLAUSE_ID as clause_id,
    CLAUSES.ARTICLE_REF as article_ref,
    CLAUSES.CLAUSE_TEXT as text
      comment='Full text of the regulatory clause',
    OBLIGATIONS.OBLIGATION_ID as obligation_id,
    OBLIGATIONS.OBLIGATION_TEXT as obligation_text,
    OBLIGATIONS.REQUIRED_SCOPE as required_scope
      comment='single_bank or cross_bank',
    TYPOLOGY_EXPOSURE.TYPOLOGY_ID as typology_id
      comment='Typology/ring identifier (e.g. RING-001)',
    TYPOLOGY_EXPOSURE.IS_GAP as is_gap
      comment='TRUE means controls are NOT adequate (gap exists). FALSE means controls are adequate.',
    TYPOLOGY_EXPOSURE.SEVERITY as severity
      comment='HIGH means cross-bank coverage required but missing. MEDIUM or NONE otherwise.',
    TYPOLOGY_EXPOSURE.RATIONALE as rationale
      comment='Explanation of why the gap exists or controls are adequate'
  )
  metrics (
    GAPS.OPEN_GAP_COUNT as SUM(gaps.gap_flag)
      comment='Number of obligations with open control gaps',
    OBLIGATIONS.OBLIGATION_COUNT as COUNT(DISTINCT obligations.obligation_id)
      comment='Number of distinct regulatory obligations'
  )
  comment='ARGUS regulatory digital twin: which obligations are covered by active, adequately-scoped controls. INSTRUCTIONS: controls adequate means is_gap = FALSE. regulatory obligations a typology touches = rows in typology_exposure for that typology_id. regulatory exposure = obligations with is_gap = TRUE. severity HIGH means cross-bank coverage required but no active control provides it. Filter by typology_id (e.g. RING-001).';

-- ---------------------------------------------------------------------------
-- Grants. CREATE OR REPLACE drops grants on the old object, so re-apply them here
-- (the future-grant in 07_governance_clean_room.sql also covers new semantic views).
-- ---------------------------------------------------------------------------
GRANT SELECT ON SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_FRAUD_SV   TO ROLE ARGUS_ANALYST;
GRANT SELECT ON SEMANTIC VIEW ARGUS.GOVERNED.ARGUS_REGTWIN_SV TO ROLE ARGUS_ANALYST;
