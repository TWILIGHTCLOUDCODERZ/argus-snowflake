/* ============================================================================
   ARGUS · 02_clean_room.sql — the privacy-preserving cross-bank moat.

   Concept script. In the real build each bank is a separate Snowflake account
   contributing to a Data Clean Room; here we simulate 3 providers as 3 schemas
   so the demo runs in one account, then show the true Clean Room object.

   KEY IDEA: only *hashed* identifiers cross the boundary. No raw PII, no names.
   The output `shared_bad_actor_signal` says "this identifier is seen at N banks"
   WITHOUT revealing whose identifier it is.
   ============================================================================ */

USE SCHEMA ARGUS.GOVERNED;

-- ---------------------------------------------------------------------------
-- Each bank exposes ONLY hashed identifiers linked to its accounts.
-- (In production this is each provider's approved clean-room share.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW bank_identifier_exposure AS
SELECT c.bank_id, 'national_id' AS identifier_type, c.national_id_hash AS identifier_hash, a.account_id
FROM ARGUS.RAW.customers c JOIN ARGUS.RAW.accounts a ON a.customer_id=c.customer_id
UNION ALL
SELECT c.bank_id, 'phone', c.phone_hash, a.account_id
FROM ARGUS.RAW.customers c JOIN ARGUS.RAW.accounts a ON a.customer_id=c.customer_id
UNION ALL
SELECT l.bank_id, 'device', l.device_hash, l.account_id
FROM ARGUS.RAW.device_logins l
UNION ALL
-- IBANs are hashed too: raw account numbers never cross the clean-room boundary.
SELECT t.bank_id, 'counterparty_iban',
       LEFT(SHA2('argus-tcc-clean-room-salt|' || t.counterparty_iban, 256), 24), t.account_id
FROM ARGUS.RAW.transactions t
WHERE t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
  AND t.counterparty_bank <> t.bank_id;       -- inter-bank only

-- ---------------------------------------------------------------------------
-- THE CLEAN-ROOM OUTPUT: identifiers observed at MORE THAN ONE bank.
-- This is the only thing that leaves the room — a privacy-preserving signal.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW shared_bad_actor_signal AS
SELECT identifier_hash, identifier_type,
       COUNT(DISTINCT bank_id)              AS contributing_bank_count,
       ARRAY_AGG(DISTINCT bank_id)          AS banks,
       COUNT(DISTINCT account_id)           AS linked_accounts,
       CASE identifier_type
            WHEN 'national_id' THEN 1.0 WHEN 'device' THEN 0.9
            WHEN 'counterparty_iban' THEN 0.8 ELSE 0.6 END
       * (COUNT(DISTINCT bank_id) - 1)      AS risk_weight
FROM bank_identifier_exposure
WHERE identifier_hash IS NOT NULL AND identifier_hash <> ''
GROUP BY identifier_hash, identifier_type
HAVING COUNT(DISTINCT bank_id) > 1;      -- shared across >= 2 banks

-- ---------------------------------------------------------------------------
-- Cross-bank fund-flow edges (funnel / layering detection input).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW cross_bank_flow_edges AS
SELECT t.bank_id AS from_bank, t.account_id AS from_account,
       t.counterparty_bank AS to_bank, t.counterparty_iban AS to_iban,
       t.amount, t.ts
FROM ARGUS.RAW.transactions t
WHERE t.counterparty_bank IN ('BANK_A','BANK_B','BANK_C')
  AND t.direction='debit';

/* ---------------------------------------------------------------------------
   REAL Snowflake Data Clean Room (shown in demo; requires 3 accounts):

   -- Provider side (each bank):
   CREATE OR REPLACE DATA CLEAN ROOM argus_consortium;
   -- add bank_identifier_exposure as an approved source, allow only the
   -- aggregate template that emits shared_bad_actor_signal (k-anonymity >= 2).

   -- Consumer side (ARGUS):
   -- run the approved analysis template; receive shared_bad_actor_signal only.
   --------------------------------------------------------------------------- */
