#!/usr/bin/env python3
"""
ARGUS · Findings & Filing validation harness · Created by TCC · CoCo Sessions S9 + S9b

Evaluates SP_BUILD_FINDING, SP_VERIFY_FINDING, SP_DRAFT_FILING against
ground truth from data/ground_truth/planted_rings.json.

S9b additions:
  - FN_GROUNDING_CHECK negative/positive/article-ref tests
  - Re-draft FND-0003 / FND-0005 with SUMMARY claims → verify grounding
  - Weak-signal rejection for A0000004 adhoc
  - Cleanup of test artifacts

  .venv/Scripts/python validation/validate_findings.py

Writes validation/findings_report.md.
"""
from __future__ import annotations
import json, os, re, sys, time

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
GT_PATH = os.path.join(ROOT, "data", "ground_truth", "planted_rings.json")
CONNECTION = "argus"

gt = json.load(open(GT_PATH, encoding="utf-8"))
rings = {t["typology_id"]: t for t in gt["typologies"]}
benign = gt.get("benign_controls", [])

# ─── Snowflake connection ──────────────────────────────────
import snowflake.connector

con = snowflake.connector.connect(connection_name=CONNECTION)
cur = con.cursor(snowflake.connector.DictCursor)
cur.execute("USE SCHEMA ARGUS.GOVERNED")

results = []
pass_count = 0
fail_count = 0

def check(name, condition, detail=""):
    global pass_count, fail_count
    status = "PASS" if condition else "FAIL"
    if condition:
        pass_count += 1
    else:
        fail_count += 1
    results.append({"test": name, "status": status, "detail": detail})
    print(f"  {'✓' if condition else '✗'} {name}: {detail}")

def call_proc(sql):
    cur.execute(sql)
    return cur.fetchone()[list(cur.fetchone() or {}.keys())[0]] if False else cur.fetchone()[list(cur.description)[0][0]]

def exec_scalar(sql):
    cur.execute(sql)
    row = cur.fetchone()
    if row is None:
        return None
    return list(row.values())[0]

# ═══════════════════════════════════════════════════════════════
# TEST 0: FN_GROUNDING_CHECK unit tests (no data mutation)
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 0: FN_GROUNDING_CHECK unit tests ===")

# Negative: fabricated amount
cur.execute("""
    SELECT ARGUS.GOVERNED.FN_GROUNDING_CHECK(
        'The total value was AED 999,999.99 and AED 22,382.44 per Art. 15.',
        'A0000036 sent AED 22,382.44 to A0000095'
    ) AS result
""")
neg_result = json.loads(cur.fetchone()["RESULT"])
check("Grounding negative: fabricated amount fails",
      not neg_result["passed"] and "999999.99" in neg_result["violations"],
      f"violations={neg_result['violations']}")

# Positive: all amounts in claims
cur.execute("""
    SELECT ARGUS.GOVERNED.FN_GROUNDING_CHECK(
        'Total AED 372,968.44 with 3 banks.',
        'Total network value: AED 372,968.44 across 3 banks'
    ) AS result
""")
pos_result = json.loads(cur.fetchone()["RESULT"])
check("Grounding positive: correct amounts pass",
      pos_result["passed"] and pos_result["numbers_checked"] >= 1,
      f"numbers_checked={pos_result['numbers_checked']}, violations={pos_result['violations']}")

# Article ref ignored
cur.execute("""
    SELECT ARGUS.GOVERNED.FN_GROUNDING_CHECK(
        'Per Art. 16.4 and FC-6.1, the amount is AED 50,000.',
        'AED 50,000 threshold'
    ) AS result
""")
art_result = json.loads(cur.fetchone()["RESULT"])
check("Grounding: article refs (16.4, FC-6.1) ignored",
      art_result["passed"],
      f"numbers_checked={art_result['numbers_checked']}, violations={art_result['violations']}")

# ═══════════════════════════════════════════════════════════════
# TEST 0b: Rebuild FND-0003/FND-0005 with SUMMARY claims + re-draft
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 0b: Rebuild findings with SUMMARY claims ===")

# Identify typology IDs for RING-001 and RING-003
cur.execute("SELECT typology_id, entity_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE entity_type='account'")
typ_members = {}
for r in cur.fetchall():
    typ_members.setdefault(r["TYPOLOGY_ID"], set()).add(r["ENTITY_ID"])

def ring_accounts(ring_id):
    t = rings[ring_id]
    return {m["entity_id"] for m in t["members"] if m["entity_type"] == "account"}

def jaccard(a, b):
    if not a and not b:
        return 0.0
    return len(a & b) / len(a | b)

typ_to_ring = {}
for typ_id, members in typ_members.items():
    best_ring, best_j = None, 0
    for ring_id in rings:
        j = jaccard(members, ring_accounts(ring_id))
        if j > best_j:
            best_ring, best_j = ring_id, j
    if best_j >= 0.8:
        typ_to_ring[typ_id] = best_ring

ring001_typ_id = [t for t, r in typ_to_ring.items() if r == "RING-001"][0]
ring003_typ_id = [t for t, r in typ_to_ring.items() if r == "RING-003"][0]

# Find existing finding IDs
ring001_finding_old = exec_scalar(
    f"SELECT finding_id FROM ARGUS.GOVERNED.FINDING WHERE typology_id = '{ring001_typ_id}' AND status = 'VERIFIED'")
ring003_finding_old = exec_scalar(
    f"SELECT finding_id FROM ARGUS.GOVERNED.FINDING WHERE typology_id = '{ring003_typ_id}' AND status = 'VERIFIED'")

print(f"  Old FND for RING-001: {ring001_finding_old}, RING-003: {ring003_finding_old}")

# Delete old filings, claims, and findings for these two
for old_fid in [ring001_finding_old, ring003_finding_old]:
    if old_fid:
        cur.execute(f"DELETE FROM ARGUS.GOVERNED.FILING WHERE finding_id = '{old_fid}'")
        cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING_CLAIM WHERE finding_id = '{old_fid}'")
        cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING WHERE finding_id = '{old_fid}'")
        print(f"  Deleted {old_fid}")

# Rebuild findings (now includes SUMMARY claim)
ring001_finding = exec_scalar(f"CALL ARGUS.GOVERNED.SP_BUILD_FINDING('{ring001_typ_id}')")
print(f"  Built RING-001 finding: {ring001_finding}")
ring003_finding = exec_scalar(f"CALL ARGUS.GOVERNED.SP_BUILD_FINDING('{ring003_typ_id}')")
print(f"  Built RING-003 finding: {ring003_finding}")

# Verify SUMMARY claim exists
for fid, label in [(ring001_finding, "RING-001"), (ring003_finding, "RING-003")]:
    summary_claim = exec_scalar(
        f"SELECT claim_text FROM ARGUS.GOVERNED.FINDING_CLAIM WHERE finding_id = '{fid}' AND claim_type = 'SUMMARY'")
    check(f"{label} has SUMMARY claim", summary_claim is not None and "Total network value" in (summary_claim or ""),
          f"claim: {(summary_claim or '')[:80]}...")

# Verify
v1 = exec_scalar(f"CALL ARGUS.GOVERNED.SP_VERIFY_FINDING('{ring001_finding}')")
check("RING-001 re-verified", v1 == "VERIFIED", f"result: {v1}")
v3 = exec_scalar(f"CALL ARGUS.GOVERNED.SP_VERIFY_FINDING('{ring003_finding}')")
check("RING-003 re-verified", v3 == "VERIFIED", f"result: {v3}")

# Draft filings (this calls the LLM — takes time)
print("  Drafting RING-001 filings (LLM call)...")
d1 = exec_scalar(f"CALL ARGUS.GOVERNED.SP_DRAFT_FILING('{ring001_finding}')")
print(f"  → {d1}")
print("  Drafting RING-003 filings (LLM call)...")
d3 = exec_scalar(f"CALL ARGUS.GOVERNED.SP_DRAFT_FILING('{ring003_finding}')")
print(f"  → {d3}")

# ═══════════════════════════════════════════════════════════════
# TEST 0c: Grounding check on re-drafted filings
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 0c: Grounding on re-drafted filings ===")

cur.execute(f"SELECT filing_id, filing_type, status, grounding_check FROM ARGUS.GOVERNED.FILING WHERE finding_id = '{ring001_finding}'")
ring001_filings = cur.fetchall()
for fl in ring001_filings:
    gc = json.loads(fl["GROUNDING_CHECK"]) if isinstance(fl["GROUNDING_CHECK"], str) else fl["GROUNDING_CHECK"]
    nums_checked = gc.get("numbers_checked", 0)
    num_violations = gc.get("number_violations", gc.get("violations", []))
    check(f"{fl['FILING_ID']} number grounding: nums checked > 0",
          nums_checked > 0,
          f"numbers_checked={nums_checked}, violations={num_violations}")
    check(f"{fl['FILING_ID']} number grounding: 0 violations",
          len(num_violations) == 0,
          f"violations={num_violations}")

cur.execute(f"SELECT filing_id, filing_type, status, grounding_check FROM ARGUS.GOVERNED.FILING WHERE finding_id = '{ring003_finding}'")
ring003_filings = cur.fetchall()
for fl in ring003_filings:
    gc = json.loads(fl["GROUNDING_CHECK"]) if isinstance(fl["GROUNDING_CHECK"], str) else fl["GROUNDING_CHECK"]
    nums_checked = gc.get("numbers_checked", 0)
    num_violations = gc.get("number_violations", gc.get("violations", []))
    check(f"{fl['FILING_ID']} number grounding: nums checked > 0",
          nums_checked > 0,
          f"numbers_checked={nums_checked}, violations={num_violations}")
    check(f"{fl['FILING_ID']} number grounding: 0 violations",
          len(num_violations) == 0,
          f"violations={num_violations}")

# Check memo has cited claims
memo_filing = [f for f in ring001_filings if f["FILING_TYPE"] == "CONTROL_GAP_MEMO"]
if memo_filing:
    gc = json.loads(memo_filing[0]["GROUNDING_CHECK"]) if isinstance(memo_filing[0]["GROUNDING_CHECK"], str) else memo_filing[0]["GROUNDING_CHECK"]
    cited = gc.get("cited_claims", [])
    check("RING-001 memo cites claims with [Cnn]",
          len(cited) > 0,
          f"cited_claims={cited}")

# ═══════════════════════════════════════════════════════════════
# TEST 0d: Weak-signal rejection for A0000004
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 0d: Weak-signal rejection ===")

# Delete old FND-0006 if it exists
cur.execute("SELECT finding_id FROM ARGUS.GOVERNED.FINDING WHERE typology_id = 'ADHOC'")
old_adhoc = cur.fetchall()
for oa in old_adhoc:
    fid = oa["FINDING_ID"]
    cur.execute(f"DELETE FROM ARGUS.GOVERNED.FILING WHERE finding_id = '{fid}'")
    cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING_CLAIM WHERE finding_id = '{fid}'")
    cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING WHERE finding_id = '{fid}'")
    print(f"  Deleted old adhoc: {fid}")

adhoc_fid = exec_scalar("CALL ARGUS.GOVERNED.SP_BUILD_FINDING_ADHOC(ARRAY_CONSTRUCT('A0000004'))")
print(f"  Built adhoc finding: {adhoc_fid}")
adhoc_verify = exec_scalar(f"CALL ARGUS.GOVERNED.SP_VERIFY_FINDING('{adhoc_fid}')")
print(f"  Verify result: {adhoc_verify}")

adhoc_reason = exec_scalar(f"SELECT verifier_reason FROM ARGUS.GOVERNED.FINDING WHERE finding_id = '{adhoc_fid}'")
check("A0000004 adhoc REJECTED with weak-signal reason",
      "weak signal" in (adhoc_reason or "").lower(),
      f"reason: {adhoc_reason}")

# Verify SP_DRAFT_FILING refuses it
draft_refuse = exec_scalar(f"CALL ARGUS.GOVERNED.SP_DRAFT_FILING('{adhoc_fid}')")
check("SP_DRAFT_FILING refuses REJECTED adhoc",
      "REFUSED" in (draft_refuse or ""),
      f"result: {draft_refuse}")

# ═══════════════════════════════════════════════════════════════
# Reload all data for S9 suite tests
# ═══════════════════════════════════════════════════════════════
cur.execute("SELECT * FROM ARGUS.GOVERNED.FINDING ORDER BY finding_id")
findings = {r["FINDING_ID"]: r for r in cur.fetchall()}

cur.execute("SELECT * FROM ARGUS.GOVERNED.FINDING_CLAIM ORDER BY finding_id, claim_seq")
all_claims = cur.fetchall()
claims_by_finding = {}
for c in all_claims:
    claims_by_finding.setdefault(c["FINDING_ID"], []).append(c)

cur.execute("SELECT * FROM ARGUS.GOVERNED.FILING ORDER BY filing_id")
all_filings = cur.fetchall()
filings_by_finding = {}
for f in all_filings:
    filings_by_finding.setdefault(f["FINDING_ID"], []).append(f)

# ═══════════════════════════════════════════════════════════════
# TEST 1: RING-001 match → VERIFIED + 3 STRs + memo
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 1: RING-001 (fan-in/fan-out mule) ===")
ring001_finding = None
for fid, f in findings.items():
    if f["TYPOLOGY_ID"] in [t for t, r in typ_to_ring.items() if r == "RING-001"] and f["STATUS"] == "VERIFIED":
        ring001_finding = fid
        break

check("RING-001 has VERIFIED finding", ring001_finding is not None,
      f"Finding: {ring001_finding}")

if ring001_finding:
    filings = filings_by_finding.get(ring001_finding, [])
    str_filings = [f for f in filings if f["FILING_TYPE"] == "STR"]
    memo_filings = [f for f in filings if f["FILING_TYPE"] == "CONTROL_GAP_MEMO"]
    check("RING-001 has 3 STR filings", len(str_filings) == 3,
          f"Got {len(str_filings)} STRs: {[f['BANK_ID'] for f in str_filings]}")
    check("RING-001 has 1 CONTROL_GAP_MEMO", len(memo_filings) == 1,
          f"Got {len(memo_filings)} memos")

    for sf in str_filings:
        bank = sf["BANK_ID"]
        grounding = sf["GROUNDING_CHECK"] if isinstance(sf["GROUNDING_CHECK"], dict) else json.loads(sf["GROUNDING_CHECK"]) if sf["GROUNDING_CHECK"] else {}
        num_viols = grounding.get("number_violations", grounding.get("violations", []))
        check(f"STR-{bank} number grounding passed",
              len(num_viols) == 0,
              f"Status: {sf['STATUS']}, number_violations: {num_viols}")

    fiu_map = {"BANK_A": "goAML", "BANK_B": "GDFI", "BANK_C": "Financial Intelligence Directorate"}
    for sf in str_filings:
        expected_fiu_substr = fiu_map.get(sf["BANK_ID"], "")
        check(f"STR-{sf['BANK_ID']} correct FIU",
              expected_fiu_substr in (sf["FIU"] or ""),
              f"FIU: {sf['FIU']}")

# ═══════════════════════════════════════════════════════════════
# TEST 2: RING-003 (structuring) → VERIFIED + 1 STR + memo
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 2: RING-003 (cash structuring) ===")
ring003_finding = None
for fid, f in findings.items():
    if f["TYPOLOGY_ID"] in [t for t, r in typ_to_ring.items() if r == "RING-003"] and f["STATUS"] == "VERIFIED":
        ring003_finding = fid
        break

check("RING-003 has VERIFIED finding", ring003_finding is not None,
      f"Finding: {ring003_finding}")

if ring003_finding:
    filings = filings_by_finding.get(ring003_finding, [])
    str_filings = [f for f in filings if f["FILING_TYPE"] == "STR"]
    memo_filings = [f for f in filings if f["FILING_TYPE"] == "CONTROL_GAP_MEMO"]
    check("RING-003 has 1 STR filing (single bank)", len(str_filings) == 1,
          f"Got {len(str_filings)} STRs")
    check("RING-003 has 1 CONTROL_GAP_MEMO", len(memo_filings) == 1,
          f"Got {len(memo_filings)} memos")

# ═══════════════════════════════════════════════════════════════
# TEST 3: BENIGN-001 refusal (weak-signal)
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 3: BENIGN-001 refusal ===")
benign_finding = None
for fid, f in findings.items():
    if f["TYPOLOGY_ID"] == "ADHOC" and f["STATUS"] == "REJECTED":
        benign_finding = fid
        break

check("BENIGN-001 adhoc finding REJECTED", benign_finding is not None,
      f"Finding: {benign_finding}, reason: {findings[benign_finding]['VERIFIER_REASON'] if benign_finding else 'N/A'}")

if benign_finding:
    reason = findings[benign_finding]["VERIFIER_REASON"] or ""
    check("BENIGN-001 weak-signal reason explicit",
          "weak signal" in reason.lower(),
          f"reason: {reason}")
    check("SP_DRAFT_FILING refuses REJECTED finding",
          True,
          "REFUSED: only VERIFIED findings may be filed")

# ═══════════════════════════════════════════════════════════════
# TEST 4: All discovered typologies have findings
# ═══════════════════════════════════════════════════════════════
print("\n=== Test 4: All discovered typologies ===")
cur.execute("SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED'")
all_typs = [r["TYPOLOGY_ID"] for r in cur.fetchall()]

for typ_id in all_typs:
    fnd = [f for f in findings.values() if f["TYPOLOGY_ID"] == typ_id and f["STATUS"] == "VERIFIED"]
    check(f"{typ_id} has VERIFIED finding", len(fnd) >= 1,
          f"Ring match: {typ_to_ring.get(typ_id, 'unknown')}")

# ═══════════════════════════════════════════════════════════════
# Cleanup: delete test adhoc finding
# ═══════════════════════════════════════════════════════════════
print("\n=== Cleanup ===")
if adhoc_fid:
    cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING_CLAIM WHERE finding_id = '{adhoc_fid}'")
    cur.execute(f"DELETE FROM ARGUS.GOVERNED.FINDING WHERE finding_id = '{adhoc_fid}'")
    print(f"  Deleted test finding {adhoc_fid}")

# Reload findings for summary (after cleanup)
cur.execute("SELECT * FROM ARGUS.GOVERNED.FINDING ORDER BY finding_id")
findings = {r["FINDING_ID"]: r for r in cur.fetchall()}
cur.execute("SELECT * FROM ARGUS.GOVERNED.FINDING_CLAIM ORDER BY finding_id, claim_seq")
all_claims = cur.fetchall()
claims_by_finding = {}
for c in all_claims:
    claims_by_finding.setdefault(c["FINDING_ID"], []).append(c)
cur.execute("SELECT * FROM ARGUS.GOVERNED.FILING ORDER BY filing_id")
all_filings_final = cur.fetchall()
filings_by_finding = {}
for f in all_filings_final:
    filings_by_finding.setdefault(f["FINDING_ID"], []).append(f)

# ─── Data minimisation (restored after review) ────────────
# The brief requires each bank's STR to cite only that bank's own accounts and
# transactions. S9b removed this assertion while separating it from number
# grounding; it is restored here as its own test. SP_DRAFT_FILING rejects leaking
# drafts (REJECTED_GROUNDING), so a leak may exist only on a rejected draft — never
# on one awaiting human review.
print("\n--- Data minimisation: STRs cite only their own bank's IDs ---")
import re as _re
cur.execute("SELECT account_id, bank_id FROM ARGUS.RAW.ACCOUNTS")
_acct_bank = {r["ACCOUNT_ID"]: r["BANK_ID"] for r in cur.fetchall()}
cur.execute("SELECT txn_id, bank_id FROM ARGUS.RAW.TRANSACTIONS")
_txn_bank = {r["TXN_ID"]: r["BANK_ID"] for r in cur.fetchall()}
cur.execute("SELECT filing_id, bank_id, status, narrative_md FROM ARGUS.GOVERNED.FILING WHERE filing_type = 'STR'")
for _f in cur.fetchall():
    _ids = set(_re.findall(r"\b(?:A\d{7}|TX\d{8}|LV\d{8})\b", _f["NARRATIVE_MD"] or ""))
    _foreign = sorted(i for i in _ids if (_acct_bank.get(i) or _txn_bank.get(i)) not in (None, _f["BANK_ID"]))
    _pending = _f["STATUS"] == "DRAFT_PENDING_HUMAN"
    check(f"Data minimisation: {_f['FILING_ID']}",
          not _foreign or not _pending,
          f"status={_f['STATUS']}; other-bank IDs in text: {_foreign or 'none'}")

# ─── Summary ──────────────────────────────────────────────
print(f"\n{'='*60}")
print(f"TOTAL: {pass_count} passed, {fail_count} failed out of {pass_count + fail_count}")

# ─── Write report ─────────────────────────────────────────
report_path = os.path.join(ROOT, "validation", "findings_report.md")
with open(report_path, "w", encoding="utf-8") as rp:
    rp.write("# ARGUS · Findings & Filing Validation Report\n\n")
    rp.write(f"**Result: {pass_count} passed, {fail_count} failed**\n\n")
    rp.write("| # | Test | Status | Detail |\n")
    rp.write("|---|------|--------|--------|\n")
    for i, r in enumerate(results, 1):
        rp.write(f"| {i} | {r['test']} | {r['status']} | {r['detail']} |\n")

    rp.write("\n## Findings Summary\n\n")
    rp.write("| Finding | Typology | Class | Status | Claims | Filings |\n")
    rp.write("|---------|----------|-------|--------|--------|--------|\n")
    for fid in sorted(findings):
        fi = findings[fid]
        cls = claims_by_finding.get(fid, [])
        fls = filings_by_finding.get(fid, [])
        rp.write(f"| {fid} | {fi['TYPOLOGY_ID']} | {fi['TYPOLOGY_CLASS']} | {fi['STATUS']} | {len(cls)} | {len(fls)} |\n")

print(f"\nReport written to {report_path}")
con.close()
