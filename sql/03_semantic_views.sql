/* ============================================================================
   ARGUS · 03_semantic_views.sql — governed semantic layer for Cortex Analyst.
   Created by TCC · Snowflake CoCo Hack (GCC Edition) · Week 2

   Authored with CoCo from argus_ontology.yaml, then validated against the
   ontology's natural-language questions (see semantic/verified_queries.yaml and
   validation/validate_week2.py).

   GOVERNANCE: raw PII (full_name, national_id, phone, email, dob) is deliberately
   NOT exposed. Business/compliance users can only reach governed dimensions and
   hashed identifiers. This is what makes answers "governed" by construction.

   Syntax note: CREATE SEMANTIC VIEW clause grammar evolves between Snowflake
   releases — have CoCo validate/adjust against your account (`DESCRIBE SEMANTIC
   VIEW` after create) as part of the Development-phase evidence.
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ---------------------------------------------------------------------------
-- 1) FRAUD semantic view — accounts, transactions, logins, banks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ARGUS.GOVERNED.argus_fraud_sv

  TABLES (
    banks AS ARGUS.RAW.banks
      PRIMARY KEY (bank_id)
      WITH SYNONYMS ('institution', 'consortium member')
      COMMENT = 'Participating GCC banks / NBFCs in the ARGUS consortium',

    customers AS ARGUS.RAW.customers
      PRIMARY KEY (customer_id)
      WITH SYNONYMS ('client', 'account holder')
      COMMENT = 'Customers. Only risk rating + hashed identifiers are exposed.',

    accounts AS ARGUS.RAW.accounts
      PRIMARY KEY (account_id)
      WITH SYNONYMS ('account', 'IBAN')
      COMMENT = 'Deposit / current / wallet accounts',

    transactions AS ARGUS.RAW.transactions
      PRIMARY KEY (txn_id)
      WITH SYNONYMS ('payment', 'transfer', 'money movement')
      COMMENT = 'All money movements; cross-bank when counterparty_bank is a consortium bank',

    logins AS ARGUS.RAW.device_logins
      PRIMARY KEY (login_id)
      WITH SYNONYMS ('session', 'device login')
      COMMENT = 'Login events with hashed device / IP'
  )

  RELATIONSHIPS (
    accounts_to_customers AS accounts (customer_id) REFERENCES customers,
    accounts_to_banks     AS accounts (bank_id)     REFERENCES banks,
    txn_to_accounts       AS transactions (account_id) REFERENCES accounts,
    logins_to_accounts    AS logins (account_id)    REFERENCES accounts
  )

  FACTS (
    transactions.txn_amount AS amount
      COMMENT = 'Transaction amount in AED',
    transactions.is_cross_bank AS IFF(counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
                                      AND counterparty_bank <> bank_id, 1, 0)
      COMMENT = '1 when funds move between two different consortium banks',
    transactions.is_near_ctr AS IFF(channel = 'cash' AND direction = 'credit'
                                    AND amount BETWEEN 52000 AND 55000, 1, 0)
      COMMENT = '1 when a cash deposit sits just under the AED 55,000 CTR threshold'
  )

  DIMENSIONS (
    banks.bank_name         AS bank_name,
    banks.regulator         AS regulator        WITH SYNONYMS ('supervisor'),
    banks.country           AS country,
    customers.kyc_risk_rating AS kyc_risk_rating WITH SYNONYMS ('KYC risk', 'customer risk'),
    customers.nationality   AS nationality,
    customers.national_id_hash AS national_id_hash
      COMMENT = 'Salted hash only - raw national ID is never exposed',
    accounts.account_id     AS account_id,
    accounts.iban           AS iban,
    accounts.account_type   AS account_type,
    accounts.account_status AS status,
    transactions.channel    AS channel,
    transactions.direction  AS direction,
    transactions.purpose_code AS purpose_code  WITH SYNONYMS ('purpose'),
    transactions.counterparty_bank AS counterparty_bank,
    transactions.txn_date   AS DATE(ts)          WITH SYNONYMS ('date', 'day'),
    transactions.txn_week   AS DATE_TRUNC('week', ts),
    logins.device_hash      AS device_hash
      COMMENT = 'Hashed device fingerprint'
  )

  METRICS (
    transactions.total_amount      AS SUM(transactions.txn_amount)
      WITH SYNONYMS ('value', 'volume'),
    transactions.txn_count         AS COUNT(transactions.txn_amount),
    transactions.cross_bank_amount AS SUM(transactions.txn_amount * transactions.is_cross_bank)
      WITH SYNONYMS ('inter-bank flow'),
    transactions.cross_bank_txn_count AS SUM(transactions.is_cross_bank),
    transactions.near_ctr_deposit_count AS SUM(transactions.is_near_ctr)
      WITH SYNONYMS ('structuring deposits', 'smurfing deposits'),
    accounts.account_count         AS COUNT(DISTINCT accounts.account_id)
  )

  COMMENT = 'ARGUS governed fraud semantic view. PII-free. Backs Cortex Analyst for compliance users.';


-- ---------------------------------------------------------------------------
-- 2) REGULATORY TWIN semantic view — regulation -> clause -> obligation -> control
--    (tables created in 05_regulatory_twin.sql; run that first)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ARGUS.GOVERNED.argus_regtwin_sv

  TABLES (
    regulations AS ARGUS.GOVERNED.regulation PRIMARY KEY (regulation_id)
      WITH SYNONYMS ('circular', 'rulebook', 'regulation'),
    clauses     AS ARGUS.GOVERNED.clause     PRIMARY KEY (clause_id)
      WITH SYNONYMS ('article', 'section'),
    obligations AS ARGUS.GOVERNED.obligation PRIMARY KEY (obligation_id)
      WITH SYNONYMS ('requirement', 'duty'),
    gaps        AS ARGUS.GOVERNED.control_gap PRIMARY KEY (obligation_id)
      WITH SYNONYMS ('control gap', 'coverage gap')
  )

  RELATIONSHIPS (
    clause_to_reg     AS clauses (regulation_id)   REFERENCES regulations,
    obligation_to_cl  AS obligations (clause_id)   REFERENCES clauses,
    gap_to_obligation AS gaps (obligation_id)      REFERENCES obligations
  )

  FACTS (
    gaps.gap_flag AS IFF(is_gap, 1, 0)
  )

  DIMENSIONS (
    regulations.regulator     AS regulator,
    regulations.reg_title     AS title,
    clauses.article_ref       AS article_ref,
    clauses.clause_text       AS text,
    obligations.obligation_text AS obligation_text,
    obligations.required_scope  AS required_scope,
    gaps.severity             AS severity,
    gaps.rationale            AS rationale
  )

  METRICS (
    gaps.open_gap_count   AS SUM(gaps.gap_flag) WITH SYNONYMS ('number of gaps'),
    obligations.obligation_count AS COUNT(DISTINCT obligations.obligation_id)
  )

  COMMENT = 'ARGUS regulatory digital twin: which obligations are covered by active, adequately-scoped controls.';
