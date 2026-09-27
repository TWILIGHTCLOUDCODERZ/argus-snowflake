#!/usr/bin/env python3
"""
ARGUS · Week 2 validation harness  ·  Created by TCC

Validates the semantic layer against the ontology's natural-language questions.
ONE set of checks, TWO backends — so the offline and warehouse results can't drift:

  --backend sqlite     (default) offline, stdlib sqlite3, SQLite dialect of the
                       verified queries. Needs no Snowflake account.
  --backend snowflake  runs the REAL verified-query SQL from
                       semantic/verified_queries.yaml on Snowflake via the
                       `argus` connection in ~/.snowflake/connections.toml.

Each answer is checked against data/ground_truth/planted_rings.json.
Writes validation/week2_validation_report[_snowflake].md as testing evidence.

  python validation/validate_week2.py
  .venv/Scripts/python validation/validate_week2.py --backend snowflake
"""
from __future__ import annotations
import argparse, csv, hashlib, json, os, re, sqlite3, sys

sys.stdout.reconfigure(encoding="utf-8")   # Windows consoles default to cp1252
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DATA = os.path.join(ROOT, "data")
YAML_PATH = os.path.join(ROOT, "semantic", "verified_queries.yaml")
SALT = "argus-tcc-clean-room-salt"
BANKS = ("BANK_A", "BANK_B", "BANK_C")

ap = argparse.ArgumentParser()
ap.add_argument("--backend", choices=("sqlite", "snowflake"), default="sqlite")
ap.add_argument("--connection", default="argus", help="connection name in connections.toml")
args = ap.parse_args()

gt = json.load(open(os.path.join(DATA, "ground_truth", "planted_rings.json"), encoding="utf-8"))
rings = {t["typology_id"]: t for t in gt["typologies"]}
benign = gt.get("benign_controls", [])

# typology_evidence is written by the Typology agent in Week 3. Until then both
# backends stand it in from ground truth so Q6 can be validated (clearly labelled;
# on Snowflake it's a session TEMPORARY table, so nothing persists).
EVIDENCE_ROWS = [(t["typology_id"], m["entity_type"], m["entity_id"], m["role"], m["bank_id"])
                 for t in gt["typologies"] for m in t["members"]]


# =========================================================================== #
# Backend 1 — SQLite (offline)
# =========================================================================== #
class SqliteBackend:
    name = "sqlite (offline)"

    Q = {
        "Q1": f"""
SELECT account_id, bank_id, COUNT(DISTINCT counterparty_bank) AS source_banks,
       COUNT(*) AS inbound_transfers, SUM(amount) AS inbound_amount
  FROM transactions
 WHERE direction = 'credit' AND counterparty_bank IN {BANKS} AND counterparty_bank <> bank_id
 GROUP BY account_id, bank_id
HAVING COUNT(DISTINCT counterparty_bank) >= 2
   AND julianday(date(MAX(ts))) - julianday(date(MIN(ts))) <= 7
 ORDER BY inbound_amount DESC""",
        "Q2": f"""
SELECT 'cross_bank_inflow' AS evidence_type, txn_id AS evidence_ref, amount, counterparty_bank AS detail
  FROM transactions WHERE account_id = :account_id AND direction = 'credit'
   AND counterparty_bank IN {BANKS} AND counterparty_bank <> bank_id
UNION ALL
SELECT 'cross_bank_outflow', txn_id, amount, counterparty_bank
  FROM transactions WHERE account_id = :account_id AND direction = 'debit'
   AND counterparty_bank IN {BANKS} AND counterparty_bank <> bank_id
UNION ALL
SELECT 'near_ctr_cash_deposit', txn_id, amount, channel
  FROM transactions WHERE account_id = :account_id AND channel = 'cash' AND direction = 'credit'
   AND amount BETWEEN 52000 AND 55000
UNION ALL
SELECT 'shared_identifier_' || s.identifier_type, s.identifier_hash, NULL,
       s.contributing_bank_count || ' banks'
  FROM shared_bad_actor_signal s
  JOIN bank_identifier_exposure e ON e.identifier_hash = s.identifier_hash
                                 AND e.identifier_type = s.identifier_type
 WHERE e.account_id = :account_id AND s.identifier_type IN ('national_id','device','phone')""",
        "Q3": """
SELECT identifier_type, identifier_hash, contributing_bank_count, banks, linked_accounts, risk_weight
  FROM shared_bad_actor_signal
 WHERE identifier_type IN ('national_id','device','phone')
 ORDER BY risk_weight DESC, contributing_bank_count DESC""",
        "Q4": """
SELECT account_id, bank_id, COUNT(*) AS near_threshold_deposits, SUM(amount) AS total_amount
  FROM transactions
 WHERE channel = 'cash' AND direction = 'credit' AND amount BETWEEN 52000 AND 55000
 GROUP BY account_id, bank_id
HAVING COUNT(*) >= 6 AND julianday(date(MAX(ts))) - julianday(date(MIN(ts))) <= 7
 ORDER BY near_threshold_deposits DESC""",
        "Q5": """
SELECT typology_id, obligation_id, obligation_text, regulator, article_ref, is_gap, severity, rationale
  FROM typology_exposure WHERE typology_id = :typology_id ORDER BY is_gap DESC, severity""",
        "Q6": f"""
SELECT e.typology_id, COUNT(DISTINCT e.entity_id) AS hub_accounts, SUM(t.amount) AS value_through_hubs
  FROM typology_evidence e
  JOIN transactions t ON t.account_id = e.entity_id AND t.direction = 'credit'
 WHERE e.typology_id = :typology_id AND e.role IN ('funnel','consolidation')
   AND t.counterparty_bank IN {BANKS}
 GROUP BY e.typology_id""",
    }

    def __init__(self):
        con = self.con = sqlite3.connect(":memory:")
        con.create_function("argus_hash", 1, lambda v: None if v in (None, "") else
                            hashlib.sha256((SALT + "|" + v).encode()).hexdigest()[:24])

        def load_csv(table, path, real_cols=()):
            with open(path, encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            cols = list(rows[0].keys())
            con.execute(f"CREATE TABLE {table} ({', '.join(c + (' REAL' if c in real_cols else ' TEXT') for c in cols)})")
            con.executemany(f"INSERT INTO {table} VALUES ({','.join('?' * len(cols))})",
                            [[(float(r[c]) if c in real_cols else r[c]) for c in cols] for r in rows])

        for t in ("banks", "customers", "accounts", "device_logins"):
            load_csv(t, os.path.join(DATA, f"{t}.csv"))
        load_csv("transactions", os.path.join(DATA, "transactions.csv"), real_cols=("amount",))

        twin = json.load(open(os.path.join(DATA, "twin_seed.json"), encoding="utf-8"))
        for table, key in [("regulation", "regulations"), ("clause", "clauses"), ("obligation", "obligations"),
                           ("control", "controls"), ("control_obligation", "control_obligation"),
                           ("typology_obligation", "typology_obligation")]:
            rows = twin[key]; cols = list(rows[0].keys())
            con.execute(f"CREATE TABLE {table} ({', '.join(c + ' TEXT' for c in cols)})")
            con.executemany(f"INSERT INTO {table} VALUES ({','.join('?' * len(cols))})",
                            [[r[c] for c in cols] for r in rows])

        con.execute("CREATE TABLE typology_evidence (typology_id TEXT, entity_type TEXT, entity_id TEXT, role TEXT, bank_id TEXT)")
        con.executemany("INSERT INTO typology_evidence VALUES (?,?,?,?,?)", EVIDENCE_ROWS)

        # SQLite dialect of 02_clean_room.sql + 05_regulatory_twin.sql
        con.executescript(f"""
CREATE VIEW bank_identifier_exposure AS
  SELECT c.bank_id, 'national_id' AS identifier_type, c.national_id_hash AS identifier_hash, a.account_id
    FROM customers c JOIN accounts a ON a.customer_id = c.customer_id
  UNION ALL
  SELECT c.bank_id, 'phone', c.phone_hash, a.account_id
    FROM customers c JOIN accounts a ON a.customer_id = c.customer_id
  UNION ALL
  SELECT bank_id, 'device', device_hash, account_id FROM device_logins
  UNION ALL
  SELECT bank_id, 'counterparty_iban', argus_hash(counterparty_iban), account_id FROM transactions
   WHERE counterparty_bank IN {BANKS} AND counterparty_bank <> bank_id;

CREATE VIEW shared_bad_actor_signal AS
  SELECT identifier_hash, identifier_type,
         COUNT(DISTINCT bank_id)         AS contributing_bank_count,
         group_concat(DISTINCT bank_id)  AS banks,
         COUNT(DISTINCT account_id)      AS linked_accounts,
         (CASE identifier_type WHEN 'national_id' THEN 1.0 WHEN 'device' THEN 0.9
               WHEN 'counterparty_iban' THEN 0.8 ELSE 0.6 END) * (COUNT(DISTINCT bank_id) - 1) AS risk_weight
    FROM bank_identifier_exposure
   WHERE identifier_hash IS NOT NULL AND identifier_hash <> ''
   GROUP BY identifier_hash, identifier_type
  HAVING COUNT(DISTINCT bank_id) > 1;

CREATE VIEW _control_gap_base AS
  SELECT o.obligation_id, o.obligation_text, o.required_scope, cl.article_ref, r.regulator,
         SUM(CASE WHEN c.status = 'active'
                   AND (o.required_scope = 'single_bank' OR c.coverage_scope = 'cross_bank')
                  THEN 1 ELSE 0 END) = 0 AS is_gap,
         group_concat(c.control_id || ' (' || c.coverage_scope || ', ' || c.status || ')', '; ') AS mapped_controls
    FROM obligation o
    JOIN clause cl    ON cl.clause_id = o.clause_id
    JOIN regulation r ON r.regulation_id = cl.regulation_id
    LEFT JOIN control_obligation co ON co.obligation_id = o.obligation_id
    LEFT JOIN control c             ON c.control_id = co.control_id
   GROUP BY o.obligation_id;

CREATE VIEW control_gap AS
  SELECT *,
         CASE WHEN is_gap THEN (CASE WHEN required_scope = 'cross_bank' THEN 'HIGH' ELSE 'MEDIUM' END)
              ELSE 'NONE' END AS severity,
         CASE WHEN is_gap THEN 'No active control with ' || required_scope || ' coverage. Mapped: '
                               || COALESCE(mapped_controls, 'none')
              ELSE 'Covered by an active, adequately-scoped control.' END AS rationale
    FROM _control_gap_base;

CREATE VIEW typology_exposure AS
  SELECT t.typology_id, g.obligation_id, g.obligation_text, g.regulator, g.article_ref,
         g.is_gap, g.severity, g.rationale
    FROM typology_obligation t JOIN control_gap g ON g.obligation_id = t.obligation_id;
""")

    def run(self, qid, **params):
        cur = self.con.execute(self.Q[qid], params)
        cols = [d[0].lower() for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    def account_ids(self):
        return [a for (a,) in self.con.execute("SELECT account_id FROM accounts ORDER BY account_id")]


# =========================================================================== #
# Backend 2 — Snowflake (runs the real verified-query SQL from the YAML)
# =========================================================================== #
class SnowflakeBackend:
    SAFE = re.compile(r"^[A-Za-z0-9_-]+$")   # placeholder values are internal IDs only

    def __init__(self, connection_name):
        import snowflake.connector, yaml
        self.name = f"snowflake (connection '{connection_name}')"
        spec = yaml.safe_load(open(YAML_PATH, encoding="utf-8"))
        self.Q = {v["name"].split("_")[0].upper(): v["sql"] for v in spec["verified_queries"]}
        self.con = snowflake.connector.connect(connection_name=connection_name)
        self.cur = self.con.cursor(snowflake.connector.DictCursor)
        # Session-scoped stand-in; hides the (empty) permanent table for this session only.
        self.cur.execute("CREATE TEMPORARY TABLE ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                         "(typology_id STRING, entity_type STRING, entity_id STRING, role STRING, bank_id STRING)")
        self.cur.executemany("INSERT INTO ARGUS.GOVERNED.TYPOLOGY_EVIDENCE VALUES (%s,%s,%s,%s,%s)", EVIDENCE_ROWS)

    def run(self, qid, **params):
        sql = self.Q[qid]
        for k, v in params.items():
            if not self.SAFE.match(v):
                raise ValueError(f"unsafe placeholder value for {k}: {v!r}")
            sql = sql.replace("{" + k + "}", v)
        self.cur.execute(sql)
        return [{k.lower(): v for k, v in row.items()} for row in self.cur.fetchall()]

    def account_ids(self):
        self.cur.execute("SELECT account_id FROM ARGUS.RAW.accounts ORDER BY account_id")
        return [r["ACCOUNT_ID"] for r in self.cur.fetchall()]


B = SqliteBackend() if args.backend == "sqlite" else SnowflakeBackend(args.connection)

# Preview of the Verifier agent's escalation rule (built fully in Week 3):
# strong evidence (cross-bank flows, near-CTR structuring, shared national ID)
# escalates; a shared device ALONE is weak and must be corroborated.
STRONG = {"cross_bank_inflow", "cross_bank_outflow", "near_ctr_cash_deposit", "shared_identifier_national_id"}
def verifier_decision(evidence_rows):
    types = {r["evidence_type"] for r in evidence_rows}
    if types & STRONG:
        return "ESCALATE"
    if types:
        return "MONITOR (weak signal only - needs corroboration)"
    return "NO BASIS TO FILE"

# =========================================================================== #
# Checks against ground truth (backend-agnostic)
# =========================================================================== #
results = []
def check(qid, question, passed, detail):
    results.append((qid, question, passed, detail))

def members(tid, roles=None):
    return {m["entity_id"] for m in rings[tid]["members"]
            if m["entity_type"] == "account" and (roles is None or m["role"] in roles)}

def aed(x):
    return f"AED {float(x):,.0f}"

# Q1 — consolidation hubs of both mule rings, and precision
got = {r["account_id"] for r in B.run("Q1")}
want = members("RING-001", {"consolidation"}) | members("RING-005", {"consolidation"})
fp = got - {m for t in rings for m in members(t)}
check("Q1", "Show me emerging cross-bank fraud we were exposed to in September 2026.",
      want <= got and not fp,
      f"returned {len(got)} account(s); expected hubs {sorted(want)} -> "
      f"{'all found' if want <= got else 'MISSING ' + str(sorted(want - got))}; false positives: {len(fp)}")

# Q2 — evidence bundle + verifier decision on ring, benign, and clean accounts
ring_hubs = sorted(members("RING-001", {"funnel", "consolidation"}))
struct_acc = sorted(members("RING-003"))[0]
ident_acc = sorted(members("RING-002"))[0]
benign_acc = benign[0]["members"][0]["entity_id"] if benign else None
all_flagged = {m for t in rings for m in members(t)} | {m["entity_id"] for b in benign for m in b["members"]}
clean_acc = next(a for a in B.account_ids() if a not in all_flagged)
cases = [(ring_hubs[0], "ESCALATE", "RING-001 hub"), (struct_acc, "ESCALATE", "RING-003 structuring"),
         (ident_acc, "ESCALATE", "RING-002 shared identity"),
         (benign_acc, "MONITOR", "BENIGN-001 household device"), (clean_acc, "NO BASIS", "clean account")]
q2_ok, q2_detail = True, []
for acc, expect, label in cases:
    ev = B.run("Q2", account_id=acc); dec = verifier_decision(ev)
    ok = dec.startswith(expect); q2_ok &= ok
    q2_detail.append(f"{label} {acc}: {len(ev)} evidence row(s) -> {dec} {'✓' if ok else '✗ expected ' + expect}")
check("Q2", "Why was account {account_id} flagged, and should we file?", q2_ok, " | ".join(q2_detail))

# Q3 — clean-room signal: RING-002 strong, BENIGN-001 weak
r3 = B.run("Q3")
nid = rings["RING-002"]["shared_national_id_hash"]; dev = rings["RING-002"]["shared_device_hash"]
row_nid = next((r for r in r3 if r["identifier_hash"] == nid), None)
row_dev = next((r for r in r3 if r["identifier_hash"] == dev), None)
row_ben = next((r for r in r3 if benign and r["identifier_hash"] == benign[0]["shared_device_hash"]), None)
q3_ok = bool(row_nid and row_nid["contributing_bank_count"] == 3 and row_dev and row_ben
             and row_nid["risk_weight"] > row_ben["risk_weight"])
check("Q3", "Which accounts share a device or national ID across more than one bank?", q3_ok,
      f"{len(r3)} shared identifier(s). RING-002 national_id at "
      f"{row_nid['contributing_bank_count'] if row_nid else 0} banks (w={row_nid['risk_weight'] if row_nid else '-'}), "
      f"device {'found' if row_dev else 'MISSING'}; BENIGN-001 device "
      f"{'found at w=' + str(row_ben['risk_weight']) + ' (ranked below RING-002)' if row_ben else 'MISSING'}")

# Q4 — structuring account, precision
r4 = B.run("Q4"); got4 = {r["account_id"] for r in r4}; want4 = members("RING-003")
check("Q4", "List cash deposits just under the reporting threshold in September 2026.",
      got4 == want4,
      f"returned {sorted(got4)}; expected {sorted(want4)}"
      + (f"; {r4[0]['near_threshold_deposits']} deposits totalling {aed(r4[0]['total_amount'])}" if r4 else ""))

# Q5 — correlation loop: mule ring has HIGH gaps, structuring is covered
r5a = B.run("Q5", typology_id="RING-001"); r5b = B.run("Q5", typology_id="RING-003")
q5_ok = any(r["is_gap"] and r["severity"] == "HIGH" for r in r5a) and not any(r["is_gap"] for r in r5b)
check("Q5", "Which regulatory obligations does this typology touch, and are our controls adequate?", q5_ok,
      "RING-001 -> " + "; ".join(f"{r['obligation_id']} {r['regulator']} {r['article_ref']} gap={bool(r['is_gap'])}/{r['severity']}" for r in r5a)
      + " | RING-003 -> " + "; ".join(f"{r['obligation_id']} gap={bool(r['is_gap'])}" for r in r5b))

# Q6 — value through ring hubs
r6 = B.run("Q6", typology_id="RING-001") + B.run("Q6", typology_id="RING-005")
q6_ok = len(r6) == 2 and all(r["value_through_hubs"] > 0 for r in r6)
check("Q6", "What is the total value moving through the funnel accounts of this ring?", q6_ok,
      "; ".join(f"{r['typology_id']}: {r['hub_accounts']} hubs, {aed(r['value_through_hubs'])}" for r in r6))

# Coverage parity: every verified query in the YAML has a check here
yaml_names = re.findall(r"^\s*-\s*name:\s*(q\d)_", open(YAML_PATH, encoding="utf-8").read(), re.M)
parity_ok = sorted(n.upper() for n in yaml_names) == sorted(r[0] for r in results)

# =========================================================================== #
# Report
# =========================================================================== #
passed = sum(1 for r in results if r[2])
print(f"\nARGUS Week 2 validation [{B.name}] — {passed}/{len(results)} NL questions pass"
      f" | YAML<->harness parity: {'OK' if parity_ok else 'MISMATCH'}\n")
for qid, question, ok, detail in results:
    print(f"[{'PASS' if ok else 'FAIL'}] {qid}: {question}\n        {detail}\n")

# Honest known limitation, surfaced rather than hidden
src = members("RING-001", {"source_mule"})
src_hits = sum(1 for a in src if verifier_decision(B.run("Q2", account_id=a)) == "ESCALATE")
limitation = (f"RING-001 source mules escalated by per-account evidence alone: {src_hits}/{len(src)}. "
              "Source mules only move money inside their own bank, so they are invisible to per-account "
              "rules — they must be reached by graph expansion from the hub (Week 3 Typology agent).")
print("Known limitation:", limitation)

suffix = "" if args.backend == "sqlite" else "_snowflake"
with open(os.path.join(ROOT, "validation", f"week2_validation_report{suffix}.md"), "w", encoding="utf-8") as f:
    f.write(f"# ARGUS — Week 2 Validation Report ({B.name})\n\n")
    f.write("*Semantic layer validated against the ontology's natural-language questions. "
            f"Generated by `validation/validate_week2.py --backend {args.backend}`.*\n\n")
    f.write(f"**Result: {passed}/{len(results)} questions pass** · verified-query parity: "
            f"{'OK' if parity_ok else 'MISMATCH'}\n\n| # | Question | Result | Evidence |\n|---|---|---|---|\n")
    for qid, question, ok, detail in results:
        f.write(f"| {qid} | {question} | {'✅ PASS' if ok else '❌ FAIL'} | {detail.replace('|', '/')} |\n")
    f.write(f"\n## Known limitation (by design)\n\n{limitation}\n")

sys.exit(0 if passed == len(results) and parity_ok else 1)
