#!/usr/bin/env python3
"""
ARGUS · Typology Discovery validation harness  ·  Created by TCC · CoCo Session S8

Evaluates the output of SP_DISCOVER_TYPOLOGIES() against ground truth
from data/ground_truth/planted_rings.json.

  .venv/Scripts/python validation/validate_discovery.py

Writes validation/discovery_report.md.
"""
from __future__ import annotations
import json, os, sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DATA = os.path.join(ROOT, "data")
GT_PATH = os.path.join(DATA, "ground_truth", "planted_rings.json")
CONNECTION = "argus"

gt = json.load(open(GT_PATH, encoding="utf-8"))
rings = {t["typology_id"]: t for t in gt["typologies"]}
benign = gt.get("benign_controls", [])
live_typs = gt.get("live_typologies", [])

def ring_accounts(tid, roles=None, source=None):
    src = source or rings
    t = src[tid] if isinstance(src, dict) else next(x for x in src if x["typology_id"] == tid)
    return {m["entity_id"] for m in t["members"]
            if m["entity_type"] == "account" and (roles is None or m["role"] in roles)}


def jaccard(a, b):
    if not a and not b:
        return 0.0
    return len(a & b) / len(a | b)


# ─── Snowflake connection ──────────────────────────────────
import snowflake.connector

con = snowflake.connector.connect(connection_name=CONNECTION)
cur = con.cursor(snowflake.connector.DictCursor)

# Load discovered typologies
cur.execute("SELECT typology_id, typology_class, member_count FROM ARGUS.GOVERNED.TYPOLOGY WHERE status = 'DISCOVERED'")
discovered_typs = {r["TYPOLOGY_ID"]: r for r in cur.fetchall()}

cur.execute("SELECT typology_id, entity_id, role, bank_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE typology_id LIKE 'TYP-%'")
evidence_rows = cur.fetchall()

discovered_members = {}
for r in evidence_rows:
    tid = r["TYPOLOGY_ID"]
    discovered_members.setdefault(tid, set()).add(r["ENTITY_ID"])

discovered_roles = {}
for r in evidence_rows:
    tid = r["TYPOLOGY_ID"]
    discovered_roles.setdefault(tid, {}).setdefault(r["ROLE"], set()).add(r["ENTITY_ID"])

# ─── Match planted rings to discovered typologies ──────────
ring_to_typ = {}
for ring_id in rings:
    gt_accounts = ring_accounts(ring_id)
    best_typ, best_jaccard = None, 0.0
    for typ_id, typ_members in discovered_members.items():
        j = jaccard(gt_accounts, typ_members)
        if j > best_jaccard:
            best_jaccard = j
            best_typ = typ_id
    ring_to_typ[ring_id] = (best_typ, best_jaccard)

results = []

print("\nARGUS · Typology Discovery Validation")
print("=" * 60)

# ─── Per-ring checks ──────────────────────────────────────
for ring_id, ring_data in rings.items():
    gt_accounts = ring_accounts(ring_id)
    typ_id, j = ring_to_typ[ring_id]
    gt_class_map = {
        "RING-001": "FAN_IN_FAN_OUT_MULE",
        "RING-002": "SHARED_IDENTITY",
        "RING-003": "CASH_STRUCTURING",
        "RING-004": "CIRCULAR_LAYERING",
        "RING-005": "FAN_IN_FAN_OUT_MULE",
    }
    expected_class = gt_class_map.get(ring_id, "UNKNOWN")
    discovered_class = discovered_typs[typ_id]["TYPOLOGY_CLASS"] if typ_id else "NONE"

    typ_members = discovered_members.get(typ_id, set()) if typ_id else set()
    recall = len(gt_accounts & typ_members) / len(gt_accounts) if gt_accounts else 0
    precision = len(gt_accounts & typ_members) / len(typ_members) if typ_members else 0
    class_ok = discovered_class == expected_class
    extra = typ_members - gt_accounts

    result = {
        "ring_id": ring_id,
        "matched_typ": typ_id,
        "jaccard": j,
        "class_expected": expected_class,
        "class_actual": discovered_class,
        "class_ok": class_ok,
        "recall": recall,
        "precision": precision,
        "gt_count": len(gt_accounts),
        "found_count": len(gt_accounts & typ_members),
        "extra": sorted(extra),
        "pass": j >= 0.8 and class_ok,
    }
    results.append(result)

    print(f"\n{ring_id} -> {typ_id or 'NOT FOUND'}")
    print(f"  Jaccard: {j:.2f}  Class: {discovered_class} ({'✓' if class_ok else '✗ expected ' + expected_class})")
    print(f"  Recall: {result['found_count']}/{result['gt_count']} ({recall:.0%})  Precision: {precision:.0%}")
    if extra:
        print(f"  Extra accounts: {sorted(extra)}")

# ─── Source-mule recall for RING-001 and RING-005 ─────────
print("\n--- Source-mule recall ---")
sm_results = {}
for ring_id in ["RING-001", "RING-005"]:
    gt_mules = ring_accounts(ring_id, roles={"source_mule"})
    typ_id = ring_to_typ[ring_id][0]
    typ_mules = discovered_roles.get(typ_id, {}).get("source_mule", set()) if typ_id else set()
    found = len(gt_mules & typ_mules)
    sm_results[ring_id] = (found, len(gt_mules))
    print(f"  {ring_id} ({typ_id}): {found}/{len(gt_mules)} source mules found {'✓' if found >= 8 else '✗ target >=8'}")

# ─── BENIGN-001 check ─────────────────────────────────────
print("\n--- BENIGN-001 check ---")
benign_accts = {m["entity_id"] for b in benign for m in b["members"]}
all_typ_accts = set()
for s in discovered_members.values():
    all_typ_accts |= s

# A0000004 specifically (the non-ring member of BENIGN-001)
benign_a0004_in_typ = "A0000004" in all_typ_accts
print(f"  A0000004 in typology: {benign_a0004_in_typ} {'✗ should NOT be' if benign_a0004_in_typ else '✓'}")

# ─── Clean account check ─────────────────────────────────
print("\n--- Clean account check ---")
all_ring_accounts = set()
for t in gt["typologies"]:
    for m in t["members"]:
        if m["entity_type"] == "account":
            all_ring_accounts.add(m["entity_id"])
for b in benign:
    for m in b["members"]:
        all_ring_accounts.add(m["entity_id"])

clean_in_typ = all_typ_accts - all_ring_accounts
print(f"  Clean accounts in typologies: {len(clean_in_typ)} (target ≤ 1)")
if clean_in_typ:
    print(f"  IDs: {sorted(clean_in_typ)}")

# ─── Live test ────────────────────────────────────────────
print("\n--- Live feed test ---")
try:
    cur.execute("USE SCHEMA ARGUS.GOVERNED")
    for i in range(12):
        cur.execute("CALL ARGUS.RAW.SP_DELIVER_NEXT_BATCH()")
        r = cur.fetchone()
        if r:
            msg = r.get("SP_DELIVER_NEXT_BATCH", r.get(list(r.keys())[0], ""))
            if "empty" in str(msg).lower():
                print(f"  Batch {i+1}: {msg}")
                break

    cur.execute("CALL ARGUS.GOVERNED.SP_RAISE_ALERTS()")

    # Wait for DTs to refresh (simple poll)
    import time
    print("  Waiting for dynamic tables to refresh...")
    time.sleep(15)

    cur.execute("CALL ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES()")
    r = cur.fetchone()
    disc_msg = r.get("SP_DISCOVER_TYPOLOGIES", r.get(list(r.keys())[0], ""))
    print(f"  Discovery after live: {disc_msg}")

    # Check for RING-006
    cur.execute("SELECT typology_id, entity_id, role FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE WHERE typology_id LIKE 'TYP-%'")
    live_evidence = cur.fetchall()
    live_members_map = {}
    for r in live_evidence:
        live_members_map.setdefault(r["TYPOLOGY_ID"], set()).add(r["ENTITY_ID"])

    ring6_accounts = ring_accounts("RING-006", source=live_typs)
    best_typ6, best_j6 = None, 0.0
    for typ_id, typ_members in live_members_map.items():
        j = jaccard(ring6_accounts, typ_members)
        if j > best_j6:
            best_j6 = j
            best_typ6 = typ_id

    ring6_found = best_j6 >= 0.5
    print(f"  RING-006 match: {best_typ6} (Jaccard {best_j6:.2f}) {'✓' if ring6_found else '✗'}")

    # Check source mules in RING-006
    if best_typ6:
        live_roles = {}
        for r in live_evidence:
            if r["TYPOLOGY_ID"] == best_typ6:
                live_roles.setdefault(r["ROLE"], set()).add(r["ENTITY_ID"])
        gt_mules_6 = ring_accounts("RING-006", roles={"source_mule"}, source=live_typs)
        found_mules_6 = live_roles.get("source_mule", set()) & gt_mules_6
        print(f"  RING-006 source mules: {len(found_mules_6)}/{len(gt_mules_6)}")

except Exception as e:
    print(f"  Live test error: {e}")
    ring6_found = False

finally:
    # Reset demo
    import time
    print("  Resetting live demo...")
    try:
        cur.execute("USE SCHEMA ARGUS.GOVERNED")
    except Exception:
        pass
    cur.execute("CALL ARGUS.RAW.SP_RESET_LIVE_DEMO()")
    # Re-run discovery to restore baseline
    time.sleep(10)
    cur.execute("CALL ARGUS.GOVERNED.SP_DISCOVER_TYPOLOGIES()")
    r = cur.fetchone()
    print(f"  Baseline restored: {r.get('SP_DISCOVER_TYPOLOGIES', r.get(list(r.keys())[0], ''))}") 

con.close()

# ─── Summary ──────────────────────────────────────────────
print("\n" + "=" * 60)
all_pass = all(r["pass"] for r in results)
sm_pass = all(found >= 8 for found, total in sm_results.values())
benign_pass = not benign_a0004_in_typ
clean_pass = len(clean_in_typ) <= 1

print(f"Ring matching:     {sum(1 for r in results if r['pass'])}/{len(results)} pass")
print(f"Source-mule recall: {sm_results.get('RING-001', (0,0))[0]}/9, {sm_results.get('RING-005', (0,0))[0]}/9 (target ≥8)")
print(f"BENIGN-001:        {'PASS' if benign_pass else 'FAIL'}")
print(f"Clean accounts:    {len(clean_in_typ)} (target ≤ 1) {'PASS' if clean_pass else 'FAIL'}")
print(f"RING-006 live:     {'PASS' if ring6_found else 'FAIL'}")

overall = all_pass and sm_pass and benign_pass and clean_pass
print(f"\nOVERALL: {'PASS' if overall else 'FAIL'}")

# ─── Write report ─────────────────────────────────────────
report_path = os.path.join(ROOT, "validation", "discovery_report.md")
with open(report_path, "w", encoding="utf-8") as f:
    f.write("# ARGUS — Typology Discovery Validation Report\n\n")
    f.write("*Generated by `validation/validate_discovery.py`*\n\n")

    f.write("## Ring Matching\n\n")
    f.write("| Ring | Matched | Jaccard | Class OK | Recall | Precision | Pass |\n")
    f.write("|------|---------|---------|----------|--------|-----------|------|\n")
    for r in results:
        f.write(f"| {r['ring_id']} | {r['matched_typ'] or '-'} | {r['jaccard']:.2f} | "
                f"{'✅' if r['class_ok'] else '❌'} {r['class_actual']} | "
                f"{r['found_count']}/{r['gt_count']} ({r['recall']:.0%}) | "
                f"{r['precision']:.0%} | {'✅' if r['pass'] else '❌'} |\n")

    f.write(f"\n## Source-Mule Recall\n\n")
    for ring_id, (found, total) in sm_results.items():
        typ_id = ring_to_typ[ring_id][0]
        f.write(f"- **{ring_id}** ({typ_id}): {found}/{total} source mules "
                f"{'✅' if found >= 8 else '❌'} (target ≥ 8)\n")

    f.write(f"\n## BENIGN-001\n\n")
    f.write(f"- A0000004 in typology: **{'YES ❌' if benign_a0004_in_typ else 'NO ✅'}**\n")

    f.write(f"\n## Clean Accounts\n\n")
    f.write(f"- Clean accounts inside typologies: **{len(clean_in_typ)}** (target ≤ 1) "
            f"{'✅' if clean_pass else '❌'}\n")
    if clean_in_typ:
        f.write(f"- IDs: {sorted(clean_in_typ)}\n")

    f.write(f"\n## Live Feed Test (RING-006)\n\n")
    f.write(f"- RING-006 discovered: **{'YES ✅' if ring6_found else 'NO ❌'}**\n")

    f.write(f"\n## Overall: {'PASS ✅' if overall else 'FAIL ❌'}\n")

print(f"\nReport written to {report_path}")
sys.exit(0 if overall else 1)
