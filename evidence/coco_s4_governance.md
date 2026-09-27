# ARGUS -- CoCo Session S4: Governance + Clean Room

*Created by TCC. Single-account consortium simulation with role-based
isolation, tag-based PII masking, and a secure clean-room view.*

## Objects Created (`sql/07_governance_clean_room.sql`)

| Object | Type | Purpose |
|--------|------|---------|
| `ARGUS_BANK_A` | Role | Bank A staff -- sees only BANK_A rows |
| `ARGUS_BANK_B` | Role | Bank B staff -- sees only BANK_B rows |
| `ARGUS_BANK_C` | Role | Bank C staff -- sees only BANK_C rows |
| `ARGUS_ANALYST` | Role | Consortium compliance analyst -- all banks, PII masked |
| `ARGUS.GOVERNED.RAP_BANK_ISOLATION` | Row Access Policy | Isolates rows by `bank_id`; INVOKER_ROLE() bypass for secure views |
| `ARGUS.GOVERNED.PII` | Tag | Classification: `national_id`, `phone`, `name`, `email`, `dob` |
| `ARGUS.GOVERNED.MASK_PII_STRING` | Masking Policy | `'***MASKED***'` for non-privileged roles (STRING) |
| `ARGUS.GOVERNED.MASK_PII_DATE` | Masking Policy | `NULL` for non-privileged roles (DATE) |
| `ARGUS.GOVERNED.SHARED_BAD_ACTOR_SIGNAL` | Secure View | Recreated as SECURE; same cross-bank aggregate logic |

## Row Access Policy Logic

```sql
CASE
  WHEN INVOKER_ROLE() IN ('ACCOUNTADMIN') THEN TRUE
  WHEN IS_ROLE_IN_SESSION('ARGUS_ANALYST') THEN TRUE
  WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_A') AND bank_id = 'BANK_A' THEN TRUE
  WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_B') AND bank_id = 'BANK_B' THEN TRUE
  WHEN IS_ROLE_IN_SESSION('ARGUS_BANK_C') AND bank_id = 'BANK_C' THEN TRUE
  ELSE FALSE
END
```

- Applied to: `RAW.CUSTOMERS`, `RAW.ACCOUNTS`, `RAW.TRANSACTIONS`, `RAW.DEVICE_LOGINS`
- `INVOKER_ROLE()` returns the secure view owner (ACCOUNTADMIN) when a bank role
  queries through the SECURE VIEW `SHARED_BAD_ACTOR_SIGNAL`, allowing the cross-bank
  aggregate to see all rows. Direct table access by a bank role returns only that
  bank's rows.

## Tag-Based Masking

| Column | Tag Value | ACCOUNTADMIN | Bank Role | ARGUS_ANALYST |
|--------|-----------|-------------|-----------|---------------|
| `full_name` | `name` | real | real | `***MASKED***` |
| `national_id` | `national_id` | real | real | `***MASKED***` |
| `phone` | `phone` | real | real | `***MASKED***` |
| `email` | `email` | real | real | `***MASKED***` |
| `dob` | `dob` | real | real | `NULL` |

Bank roles see real PII for their OWN customers only (row isolation limits scope).

## Verification Results

| Role | Customers Visible | Banks Visible | national_id Sample | Shared Signal Rows |
|------|-------------------|---------------|--------------------|--------------------|
| ACCOUNTADMIN | 540 | 3 | `PH-801285876` (real) | 8 |
| ARGUS_BANK_A | 180 | 1 (BANK_A) | `PH-801285876` (real) | 8 |
| ARGUS_ANALYST | 540 | 3 | `***MASKED***` | 8 |

### Access Control Checks

- **ARGUS_BANK_A** `SELECT` on `ARGUS.GOVERNED.CONTROL_GAP`: **DENIED** (Object does not exist or not authorized) -- correct.
- **ARGUS_ANALYST** semantic view query (channel x total_amount): **SUCCESS** -- returns 4 channels.
- **ARGUS_ANALYST** Cortex Search `POLICY_SEARCH`: USAGE granted.

### Regression Checks

- **Semantic view** (`ARGUS_FRAUD_SV`): queries avoiding the `banks.bank_name x transactions.*` multi-path work for all roles. The `DIMENSIONS banks.bank_name METRICS transactions.cross_bank_amount` query has a pre-existing multi-path limitation (multiple tables reference BANKS in the star schema); this is unrelated to governance changes.
- **validate_week2.py --backend snowflake**: **6/6 PASS**, YAML parity OK.

## Analyst Grants Summary

| Scope | Grant |
|-------|-------|
| RAW tables | SELECT on all current tables |
| CURATED tables/views/DTs | SELECT on all current + FUTURE |
| GOVERNED tables/views | SELECT on all current + FUTURE |
| Semantic views | SELECT on `ARGUS_FRAUD_SV`, `ARGUS_REGTWIN_SV` |
| Cortex Search | USAGE on `POLICY_SEARCH` |

## Upgrade Path to a Real Snowflake Data Clean Room

The single-account simulation proves the governance model. In production, each bank
runs in its **own Snowflake account**. The upgrade path:

### 1. One Provider Account Per Bank

Each bank (BANK_A, BANK_B, BANK_C) owns a Snowflake account. The bank's raw data
(customers, accounts, transactions, device_logins) lives exclusively in that account.
No raw PII ever leaves the provider.

### 2. Data Clean Room Setup

```
-- Provider side (each bank):
CREATE DATA CLEAN ROOM argus_consortium;

-- Register the bank_identifier_exposure view as an approved data source.
-- Only hashed identifiers are exposed; raw columns are excluded.
ALTER DATA CLEAN ROOM argus_consortium
  ADD DATA SOURCE bank_identifier_exposure;
```

### 3. Approved Analysis Templates

The Clean Room administrator defines a single approved template that implements
the `shared_bad_actor_signal` aggregation (k-anonymity >= 2). The template:

- Accepts only hashed identifier columns as input
- Outputs only aggregate counts (contributing_bank_count, linked_accounts, risk_weight)
- Enforces `HAVING COUNT(DISTINCT bank_id) > 1` (no single-bank identifiers leak)
- Returns no raw account IDs, customer names, or bank-specific details

### 4. Consumer Side (ARGUS Consortium Hub)

A separate consortium account runs the approved template:

```
-- Consumer side:
CALL argus_consortium.run_analysis('shared_bad_actor_signal');
-- Receives only the aggregate result; never sees individual bank data.
```

### 5. What Changes vs. the Simulation

| Aspect | Single-Account Simulation | Real Data Clean Room |
|--------|---------------------------|----------------------|
| Isolation | Row access policy on `bank_id` | Separate Snowflake accounts |
| PII protection | Tag-based masking policy | Data never leaves provider |
| Cross-bank aggregate | SECURE VIEW with INVOKER_ROLE bypass | Approved DCR analysis template |
| Audit | ACCOUNT_USAGE query history | DCR audit log per provider |
| Bank onboarding | CREATE ROLE + GRANT | Provider account + DCR enrollment |
| Compliance evidence | Masking + RAP = "defense in depth" | Cryptographic proof of computation |

### 6. Migration Steps

1. **Provision** one Snowflake account per bank (or use existing bank accounts).
2. **Deploy** the bank's RAW schema + `bank_identifier_exposure` view into each provider account.
3. **Create** the Data Clean Room object and register each provider.
4. **Migrate** the `shared_bad_actor_signal` logic into an approved analysis template with k-anonymity enforcement.
5. **Test** that the consumer account receives the same 8 shared identifiers as the simulation.
6. **Retire** the single-account roles (`ARGUS_BANK_A/B/C`) and row access policy; the DCR boundary replaces them.
7. **Retain** `ARGUS_ANALYST` and the masking policy in the consortium hub account for the compliance team.
