/* ============================================================================
   ARGUS · 00_setup_warehouse.sql — compute + containers (run once, via CoCo/snow).
   X-Small warehouse that suspends after 60s idle to protect trial credits.
   ============================================================================ */

CREATE WAREHOUSE IF NOT EXISTS ARGUS_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'ARGUS - Risk & Regulatory Intelligence Copilot (TCC)';

CREATE DATABASE IF NOT EXISTS ARGUS COMMENT = 'ARGUS - Created by TCC';
CREATE SCHEMA IF NOT EXISTS ARGUS.RAW;
CREATE SCHEMA IF NOT EXISTS ARGUS.CURATED;
CREATE SCHEMA IF NOT EXISTS ARGUS.GOVERNED;

-- Internal stage for the synthetic CSVs (uploaded with: snow stage copy data/*.csv @ARGUS.RAW.ARGUS_STAGE)
CREATE STAGE IF NOT EXISTS ARGUS.RAW.ARGUS_STAGE COMMENT = 'Synthetic ARGUS data';
