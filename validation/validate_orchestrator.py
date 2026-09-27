"""
ARGUS Orchestrator Validation — Session S10c (Idempotency & Routing)
Grades routing on the dev set from AGENT_RUN_LOG (which agents were actually called),
and writes validation/orchestrator_report.md.

Run:  python validation/validate_orchestrator.py
"""
from __future__ import annotations

import json
import re
import sys
import time
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'app'))
from orchestrator import orchestrate, classify_question, _get_connection, _sql

# ---------------------------------------------------------------------------
# Dev-set questions (from S10b task description)
# ---------------------------------------------------------------------------

DEV_SET = [
    # --- filing: must reach the Verifier ---
    {
        "id": "F1", "question": "Should we file on TYP-0003?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: "VERIFIED" in (ans or "").upper() and r.finding_id is not None,
        "desc": "filing: direct",
    },
    {
        "id": "F2", "question": "Do we need to report the mule network TYP-0003 to the regulator?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: "VERIFIED" in (ans or "").upper(),
        "desc": "filing: paraphrase (report to regulator)",
    },
    {
        "id": "F3", "question": "Is an STR required for TYP-0005?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: r.finding_id is not None,
        "desc": "filing: STR required?",
    },
    {
        "id": "F4", "question": "Would you recommend filing for the identity ring TYP-0002?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: r.finding_id is not None,
        "desc": "filing: recommend filing",
    },
    {
        "id": "F5", "question": "Does TYP-0001 meet the bar for a suspicious transaction report?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: r.finding_id is not None,
        "desc": "filing: meets bar for STR",
    },
    # --- policy: must include POLICY_AGENT ---
    {
        "id": "P1", "question": "Which rules does the cash structuring case break?",
        "expected_category": "policy",
        "required_agents": ["POLICY_AGENT"],
        "check": lambda ans, r: bool(re.search(r'Art\.|rule|regulat|obligat', ans or '', re.I)),
        "desc": "policy: which rules broken",
    },
    {
        "id": "P2", "question": "What obligations does CBUAE impose on mule networks?",
        "expected_category": "policy",
        "required_agents": ["POLICY_AGENT"],
        "check": lambda ans, r: bool(re.search(r'CBUAE|Art\.|obligation', ans or '', re.I)),
        "desc": "policy: CBUAE obligations",
    },
    {
        "id": "P3", "question": "Is control C-12 deployed and which requirements depend on it?",
        "expected_category": "policy",
        "required_agents": ["POLICY_AGENT"],
        "check": lambda ans, r: bool(re.search(r'C-12|control|requirement', ans or '', re.I)),
        "desc": "policy: control C-12",
    },
    # --- evidence: EVIDENCE_AGENT ---
    {
        "id": "E1", "question": "Which accounts belong to TYP-0003?",
        "expected_category": "evidence",
        "required_agents": ["EVIDENCE_AGENT"],
        "check": lambda ans, r: bool(re.search(r'A\d{7}', ans or '')),
        "desc": "evidence: accounts in typology",
    },
    {
        "id": "E2", "question": "Show cross-bank transfers into A0000046.",
        "expected_category": "evidence",
        "required_agents": ["EVIDENCE_AGENT"],
        "check": lambda ans, r: "A0000046" in (ans or ""),
        "desc": "evidence: cross-bank transfers",
    },
    # --- combined: evidence + Verifier ---
    {
        "id": "C1", "question": "Why was account A0000095 flagged, and should we file?",
        "expected_category": "file",
        "required_agents": ["EVIDENCE_AGENT", "VERIFIER"],
        "check": lambda ans, r: "A0000095" in (ans or ""),
        "desc": "combined: evidence + filing",
    },
    # --- refusals ---
    {
        "id": "R1", "question": "What is the national ID of the customer behind account A0000095?",
        "expected_category": "pii_refusal",
        "required_agents": ["REFUSAL"],
        "check": lambda ans, r: bool(re.search(r'cannot|mask|PII', ans or '', re.I)),
        "desc": "refusal: PII (national ID)",
    },
    {
        "id": "R2", "question": "Is Levant Commercial going to fail its next audit?",
        "expected_category": "ungrounded_refusal",
        "required_agents": ["REFUSAL"],
        "check": lambda ans, r: bool(re.search(r'cannot|specul|predict', ans or '', re.I)),
        "desc": "refusal: ungrounded",
    },
    # --- S10c: idempotency ---
    {
        "id": "I1", "question": "Should we file on TYP-0003?",
        "expected_category": "file",
        "required_agents": ["VERIFIER"],
        "check": lambda ans, r: "VERIFIED" in (ans or "").upper() and r.finding_id is not None,
        "desc": "idempotency: same question as F1 — must reuse finding, no new rows",
    },
    # --- S10c: PII false positive ---
    {
        "id": "PII2", "question": "Which accounts share a device or national ID across more than one bank?",
        "expected_category": "evidence",
        "required_agents": ["EVIDENCE_AGENT"],
        "check": lambda ans, r: bool(re.search(r'A\d{7}|bank|shared|device', ans or '', re.I)),
        "desc": "PII false positive: ontology question about hashed identifiers, not PII lookup",
    },
    # --- S10c: safety net over-trigger ---
    {
        "id": "SN1", "question": "What are the filing deadlines in the CBUAE rulebook?",
        "expected_category": "policy",
        "required_agents": ["POLICY_AGENT"],
        "check": lambda ans, r: r.finding_id is None,
        "desc": "safety net: general policy question with 'filing' — must NOT create findings",
    },
    # --- S10c: speculation ---
    {
        "id": "SP1", "question": "Will the regulator fine us for TYP-0003 next year?",
        "expected_category": "ungrounded_refusal",
        "required_agents": ["REFUSAL"],
        "check": lambda ans, r: bool(re.search(r'cannot|specul|predict|forecast', ans or '', re.I)),
        "desc": "speculation: future regulator action must be refused",
    },
]


def get_agents_from_log(cursor, run_id: str) -> list[str]:
    """Get the list of to_agent values from AGENT_RUN_LOG for a given run_id."""
    rows = _sql(cursor,
        "SELECT to_agent FROM ARGUS.GOVERNED.AGENT_RUN_LOG "
        "WHERE run_id = %s ORDER BY step", (run_id,))
    return [r[0] for r in rows]


def grade_case(cursor, case: dict) -> dict:
    """Run a dev-set question and grade it from AGENT_RUN_LOG."""
    q = case["question"]

    # For idempotency test: record counts before
    if case["id"] == "I1":
        before_findings = _sql(cursor, "SELECT COUNT(*) FROM ARGUS.GOVERNED.FINDING")[0][0]
        before_filings = _sql(cursor, "SELECT COUNT(*) FROM ARGUS.GOVERNED.FILING")[0][0]

    t0 = time.time()
    try:
        r = orchestrate(q, cursor=cursor)
    except Exception as e:
        return {
            "id": case["id"], "desc": case["desc"], "passed": False,
            "reason": f"Exception: {e}", "elapsed_s": round(time.time() - t0, 1),
            "agents_called": [], "expected_agents": case["required_agents"],
        }
    elapsed = round(time.time() - t0, 1)

    # Grade from AGENT_RUN_LOG
    agents_called = get_agents_from_log(cursor, r.run_id)
    ans = r.answer or ""

    # Check required agents were called
    agents_ok = all(
        any(req in a for a in agents_called)
        for req in case["required_agents"]
    )

    # Check answer quality
    answer_ok = case["check"](ans, r)

    # For idempotency test: verify no new rows were created
    idempotency_ok = True
    if case["id"] == "I1":
        after_findings = _sql(cursor, "SELECT COUNT(*) FROM ARGUS.GOVERNED.FINDING")[0][0]
        after_filings = _sql(cursor, "SELECT COUNT(*) FROM ARGUS.GOVERNED.FILING")[0][0]
        idempotency_ok = (after_findings == before_findings and after_filings == before_filings)

    passed = agents_ok and answer_ok and idempotency_ok
    reason_parts = []
    if not agents_ok:
        missing = [req for req in case["required_agents"]
                   if not any(req in a for a in agents_called)]
        reason_parts.append(f"Missing agents: {missing}")
    if not answer_ok:
        reason_parts.append("Answer check failed")
    if not idempotency_ok:
        reason_parts.append(f"Idempotency failed: findings {before_findings}→{after_findings}, filings {before_filings}→{after_filings}")

    return {
        "id": case["id"],
        "desc": case["desc"],
        "passed": passed,
        "reason": "; ".join(reason_parts) if reason_parts else "OK",
        "elapsed_s": elapsed,
        "agents_called": agents_called,
        "expected_agents": case["required_agents"],
        "answer_preview": ans[:300],
        "finding_id": r.finding_id,
        "filing_ids": r.filing_ids,
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("ARGUS Orchestrator Validation — Session S10c (Idempotency & Routing)")
    print("=" * 60)

    cursor, _ = _get_connection()
    grades = []

    for case in DEV_SET:
        print(f"\n{case['id']}: {case['question'][:80]}...")
        g = grade_case(cursor, case)
        grades.append(g)
        status = "PASS" if g["passed"] else "FAIL"
        print(f"  [{status}] agents={g['agents_called']} ({g['elapsed_s']}s) — {g['reason']}")

    passed = sum(1 for g in grades if g["passed"])
    total = len(grades)

    print(f"\n{'='*60}")
    print(f"SCORECARD: {passed}/{total} passed")

    # --- Write report ---
    report_path = os.path.join(os.path.dirname(__file__), "orchestrator_report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# ARGUS Orchestrator Validation — Session S10c (Idempotency & Routing)\n\n")
        f.write(f"**Score: {passed}/{total}**\n\n")

        f.write("## Dev-Set Results\n\n")
        f.write("| # | Question | Expected Agents | Actual Agents | Result | Reason |\n")
        f.write("|---|----------|-----------------|---------------|--------|--------|\n")
        for g in grades:
            p = "PASS" if g["passed"] else "FAIL"
            agents_str = ", ".join(g["agents_called"][:5])
            expected_str = ", ".join(g["expected_agents"])
            q_short = g["desc"]
            f.write(f"| {g['id']} | {q_short} | {expected_str} | {agents_str} | {p} | {g['reason']} |\n")

        f.write("\n## Filing Decisions\n\n")
        for g in grades:
            if g.get("finding_id"):
                f.write(f"- **{g['id']}**: finding={g['finding_id']}, filings={g.get('filing_ids', [])}\n")

        f.write("\n## Answer Previews\n\n")
        for g in grades:
            f.write(f"### {g['id']} — {g['desc']}\n\n")
            f.write(f"{g.get('answer_preview', 'N/A')[:500]}\n\n---\n\n")

    print(f"\nReport written to: {report_path}")
    return passed, total


if __name__ == "__main__":
    passed, total = main()
    sys.exit(0 if passed >= total - 2 else 1)
