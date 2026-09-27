# CoCo session S10b — ROBUST ROUTING for the orchestrator (filing intent must reach the Verifier)

Project: **ARGUS** (team TCC). `app/orchestrator.py` (session S10) routes questions with
keyword regexes (`classify_question`). An end-to-end evaluation
(`validation/validate_orchestrator_e2e.py`, 10/12) found two routing misses:
- "Do we need to report the mule network TYP-0003 to the regulator?" → routed `combined`;
  the Verifier was NOT called. The Evidence agent correctly refused to decide ("filing
  decisions are made by the Verifier"), so no LLM opinion leaked — but the user never got
  the decision. **Any filing/reporting intent must always reach the deterministic Verifier.**
- "Which rules does the cash structuring case break?" → the Policy agent was not asked;
  the answer covered detection rules but not the regulations (CBUAE Art. 15 / SAMA Art. 12).

## Change
1. Keep the deterministic **refusal gates first** (PII, ungrounded speculation), and make
   PII detection broader: national ID, passport, phone, email, date of birth, customer
   name/identity of the holder.
2. Replace keyword routing with an **intent classifier** using
   `AI_COMPLETE('claude-sonnet-4-5', ..., response_format => <JSON schema>)` returning
   `{intents: [evidence|policy|filing_decision], typology_ids: [], account_ids: []}`.
   Fall back to the regex classifier only if the call fails.
3. **Hard safety rule** (deterministic, after classification): route to the Verifier path
   if `filing_decision` is an intent, OR the question contains reporting vocabulary
   (file, filing, report, reportable, STR, SAR, FIU, GDFI, goAML, notify, disclose to
   regulator), OR any specialist's answer defers the decision to the Verifier.
   Questions about rules/regulations/obligations/requirements/law/"break"/"violate" must
   include the Policy agent.
4. Log the classifier result as its own handoff step (`from_agent = ORCHESTRATOR`,
   `to_agent = CLASSIFIER`, output = the intents JSON).

## Dev set (tune on these; a separate hold-out set will be used for final grading)
- filing: "Should we file on TYP-0003?", "Do we need to report the mule network TYP-0003 to
  the regulator?", "Is an STR required for TYP-0005?", "Would you recommend filing for the
  identity ring TYP-0002?", "Does TYP-0001 meet the bar for a suspicious transaction report?"
- policy: "Which rules does the cash structuring case break?", "What obligations does CBUAE
  impose on mule networks?", "Is control C-12 deployed and which requirements depend on it?"
- evidence: "Which accounts belong to TYP-0003?", "Show cross-bank transfers into A0000046."
- combined: "Why was account A0000095 flagged, and should we file?" (evidence + Verifier)
- refusals: "What is the national ID of the customer behind account A0000095?",
  "Is Levant Commercial going to fail its next audit?"

## Verify
- Update `validation/validate_orchestrator.py` to grade routing on the dev set **from
  `AGENT_RUN_LOG`** (which agents were actually called), and write
  `validation/orchestrator_report.md` (the S10 report that was missing).
- Re-run `validation/validate_orchestrator_e2e.py` (must stay ≥ 10/12; do not edit it).
- Write `evidence/coco_s10b_routing.md` (before/after routing, dev-set results).

Rules: don't change the Verifier/Narrative procedures or the agents' specs unless needed
for routing; drafts only; role checks start with `USE SECONDARY ROLES NONE;`.
