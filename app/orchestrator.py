"""
ARGUS Orchestrator — multi-agent routing with handoff logging.

Splits a user question into sub-tasks, routes each to the right specialist
(Evidence Agent, Policy Agent, Verifier procedures, Narrative procedures),
passes shared context (typology/finding IDs) between them, and composes a
single answer with citations.

Runs identically from:
  - CLI via snowflake-connector-python (conn from `argus` connection)
  - Streamlit in Snowflake (conn from snowflake.snowpark.context)
"""
from __future__ import annotations

import json
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Connection helpers — work from both CLI and Streamlit in Snowflake
# ---------------------------------------------------------------------------

def _get_connection():
    """Return a live Snowflake cursor. Tries Streamlit session first."""
    try:
        from snowflake.snowpark.context import get_active_session
        session = get_active_session()
        return session.connection.cursor(), session
    except Exception:
        pass
    try:
        import snowflake.connector
        conn = snowflake.connector.connect(connection_name="argus")
        return conn.cursor(), None
    except Exception:
        raise RuntimeError("No Snowflake connection available")


def _sql(cursor, query: str, params=None):
    """Execute SQL, return list of rows (tuples)."""
    if params:
        cursor.execute(query, params)
    else:
        cursor.execute(query)
    return cursor.fetchall()


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class HandoffStep:
    step: int
    from_agent: str
    to_agent: str
    input_summary: str
    output_summary: str = ""
    refs: list = field(default_factory=list)
    started_at: float = 0.0
    duration_ms: int = 0


@dataclass
class OrchestratorResult:
    run_id: str
    question: str
    answer: str
    citations: list = field(default_factory=list)
    steps: list[HandoffStep] = field(default_factory=list)
    finding_id: Optional[str] = None
    filing_ids: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Agent callers
# ---------------------------------------------------------------------------

def call_agent(cursor, agent_fqn: str, question: str) -> dict:
    """Call a Cortex Agent via DATA_AGENT_RUN and return the parsed response."""
    payload = json.dumps({
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]
    })
    rows = _sql(cursor,
        f"SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('{agent_fqn}', %s, TRUE)",
        (payload,))
    raw = rows[0][0] if rows else "{}"
    return json.loads(raw) if isinstance(raw, str) else raw


def extract_agent_text(response: dict) -> str:
    """Pull the text content from an agent response."""
    parts = []
    for item in response.get("content", []):
        if item.get("type") == "text":
            parts.append(item["text"])
        elif item.get("type") == "table":
            tbl = item.get("table", item)
            rs = tbl.get("result_set", {})
            meta = rs.get("resultSetMetaData", {})
            cols = [c["name"] for c in meta.get("rowType", [])]
            data = rs.get("data", [])
            if cols and data:
                header = " | ".join(cols)
                sep = " | ".join(["---"] * len(cols))
                rows = [" | ".join(str(v) for v in r) for r in data]
                parts.append(f"\n{header}\n{sep}\n" + "\n".join(rows) + "\n")
    return "\n".join(parts).strip()


def extract_refs(response: dict) -> list:
    """Extract citation references (query_ids, tool names) from agent response."""
    refs = []
    for item in response.get("content", []):
        if item.get("type") == "tool_result":
            tr = item.get("tool_result", item)
            qid = None
            for c in tr.get("content", []):
                j = c.get("json", {})
                if "query_id" in j:
                    qid = j["query_id"]
            if qid:
                refs.append(qid)
        elif item.get("type") == "table":
            tbl = item.get("table", item)
            qid = tbl.get("query_id")
            if qid:
                refs.append(qid)
    return refs


# ---------------------------------------------------------------------------
# Procedure callers
# ---------------------------------------------------------------------------

def call_build_finding(cursor, typology_id: str) -> str:
    rows = _sql(cursor, f"CALL ARGUS.GOVERNED.SP_BUILD_FINDING('{typology_id}')")
    return rows[0][0] if rows else ""


def call_build_finding_adhoc(cursor, account_ids: list) -> str:
    arr = ", ".join(f"'{a}'" for a in account_ids)
    rows = _sql(cursor, f"CALL ARGUS.GOVERNED.SP_BUILD_FINDING_ADHOC(ARRAY_CONSTRUCT({arr}))")
    return rows[0][0] if rows else ""


def call_verify_finding(cursor, finding_id: str) -> str:
    rows = _sql(cursor, f"CALL ARGUS.GOVERNED.SP_VERIFY_FINDING('{finding_id}')")
    return rows[0][0] if rows else ""


def call_draft_filing(cursor, finding_id: str) -> str:
    rows = _sql(cursor, f"CALL ARGUS.GOVERNED.SP_DRAFT_FILING('{finding_id}')")
    return rows[0][0] if rows else ""


def check_shared_typology(cursor, account_ids: list) -> Optional[str]:
    """Check if all accounts share a common typology. Returns typology_id or None."""
    if len(account_ids) < 2:
        return None
    arr = ", ".join(f"'{a}'" for a in account_ids)
    rows = _sql(cursor,
        f"SELECT typology_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
        f"WHERE entity_id IN ({arr}) AND entity_type = 'account' "
        f"GROUP BY typology_id HAVING COUNT(DISTINCT entity_id) = {len(account_ids)}")
    return rows[0][0] if rows else None


def check_any_typology(cursor, account_ids: list) -> dict:
    """Check which accounts are in any typology. Returns {account_id: [typology_ids]}."""
    arr = ", ".join(f"'{a}'" for a in account_ids)
    rows = _sql(cursor,
        f"SELECT entity_id, ARRAY_AGG(DISTINCT typology_id) "
        f"FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
        f"WHERE entity_id IN ({arr}) AND entity_type = 'account' "
        f"GROUP BY entity_id")
    return {r[0]: r[1] for r in rows}


def get_finding_status(cursor, finding_id: str) -> dict:
    rows = _sql(cursor,
        f"SELECT finding_id, status, verifier_reason FROM ARGUS.GOVERNED.FINDING WHERE finding_id = '{finding_id}'")
    if rows:
        return {"finding_id": rows[0][0], "status": rows[0][1], "reason": rows[0][2]}
    return {}


def get_filings_for_finding(cursor, finding_id: str) -> list:
    rows = _sql(cursor,
        f"SELECT filing_id, filing_type, bank_id, regulator, status "
        f"FROM ARGUS.GOVERNED.FILING WHERE finding_id = '{finding_id}'")
    return [{"filing_id": r[0], "type": r[1], "bank": r[2], "regulator": r[3], "status": r[4]}
            for r in rows]


def find_existing_finding(cursor, typology_id: str) -> dict | None:
    """Return the best VERIFIED or REJECTED finding for a typology, or None.
    Prefers findings that already have filing drafts, then newest."""
    rows = _sql(cursor,
        f"SELECT f.finding_id, f.status, f.verifier_reason, "
        f"  (SELECT COUNT(*) FROM ARGUS.GOVERNED.FILING fl WHERE fl.finding_id = f.finding_id) as filing_count "
        f"FROM ARGUS.GOVERNED.FINDING f "
        f"WHERE f.typology_id = '{typology_id}' AND f.status IN ('VERIFIED', 'REJECTED') "
        f"ORDER BY filing_count DESC, f.created_at DESC LIMIT 1")
    if rows:
        return {"finding_id": rows[0][0], "status": rows[0][1], "reason": rows[0][2]}
    return None


# ---------------------------------------------------------------------------
# Handoff logger
# ---------------------------------------------------------------------------

def log_handoff(cursor, run_id: str, step: HandoffStep):
    refs_json = json.dumps(step.refs)
    _sql(cursor,
        "INSERT INTO ARGUS.GOVERNED.AGENT_RUN_LOG "
        "(run_id, step, from_agent, to_agent, input_summary, output_summary, refs, duration_ms) "
        "SELECT %s, %s, %s, %s, %s, %s, PARSE_JSON(%s), %s",
        (run_id, step.step, step.from_agent, step.to_agent,
         step.input_summary, step.output_summary[:2000], refs_json, step.duration_ms))


# ---------------------------------------------------------------------------
# Question classifier
# ---------------------------------------------------------------------------

# Patterns for routing
_FILE_PATTERN = re.compile(
    r'\b(should\s+we\s+file|file\s+on|filing\s+decision|should\s+.*\s+be\s+filed|STR\s+for)\b', re.I)
_PII_LOOKUP_PATTERN = re.compile(
    r'(?:what\s+is\s+the|give\s+me\s+the|show\s+me\s+the|reveal\s+the|tell\s+me\s+the|'
    r'provide\s+the|look\s*up\s+the|who\s+is\s+the)\s+'
    r'(?:national\s+id|passport(?:\s+(?:number|id))?|phone(?:\s+number)?|'
    r'email(?:\s+address)?|date\s+of\s+birth|dob|full\s+name|customer\s+name|'
    r'name|identity|social\s+security)', re.I)
_PII_OF_PATTERN = re.compile(
    r'\b(?:national\s+id|passport|phone\s+number|email|full\s+name|name|dob|'
    r'date\s+of\s+birth|social\s+security|identity)\s+'
    r'(?:of\s+the\s+(?:customer|account|person|holder|individual|client|user)|'
    r'of\s+account|behind\s+account|for\s+(?:customer|account))', re.I)
# Asking WHO a person is ("who is the account holder behind A0000095", "who owns
# A0000343") is an identity lookup even without naming a PII field.
_PII_WHO_PATTERN = re.compile(
    r'\bwho\s+(?:is|are|owns|holds|controls)\b.*\b(?:holder|owner|behind|customer|'
    r'person|individual|beneficial|A\d{7})', re.I)
_UNGROUNDED_PATTERN = re.compile(
    r'\b(going\s+to\s+fail|going\s+to\s+be\s+penali[sz]ed|predict|forecast|'
    r'will\s+.*\s+pass|will\s+the\s+regulator|next\s+audit|next\s+year|'
    r'future\s+(?:audit|fine|sanction|penalt|regulator)|what\s+fine)\b', re.I)
_POLICY_PATTERN = re.compile(
    r'(?:\bregulat\w*|\bobligat\w*|\bcontrol\s+gap|\bclause|\barticle\b|\bcircular\b|'
    r'\bCBUAE\b|\bSAMA\b|\bFATF\b|\bCBB\b|\bcompliance\b|\bpolicy\b|\bwhich\s+rules)', re.I)
_EVIDENCE_PATTERN = re.compile(
    r'\b(flagged|evidence|transaction|account|hub|structuring|shared\s+identity|'
    r'shared\s+device|ring|typology|mule|funnel|consolidation|cross-bank\s+fraud|'
    r'emerging|what\s+happened|why\s+was)\b', re.I)
_TYPOLOGY_ID_PATTERN = re.compile(r'TYP-\d{4}', re.I)
_ACCOUNT_ID_PATTERN = re.compile(r'A\d{7}', re.I)

# Hard safety-rule patterns (deterministic, applied AFTER LLM classification)
_REPORTING_VOCAB = re.compile(
    r'\b(file|filing|report(?:able)?|STR|SAR|FIU|GDFI|goAML|notify|disclose\s+to\s+regulator)\b', re.I)
_CASE_REFERENCE = re.compile(
    r'(?:TYP-\d{4}|FND-\d{4}|A\d{7}|\bthis\s+(?:case|ring|network|finding|typology)\b'
    r'|\bthe\s+(?:mule|structuring|identity|fraud)\s+(?:case|ring|network)\b)', re.I)
_POLICY_VOCAB = re.compile(
    r'\b(rules?|regulat\w*|obligat\w*|requirement|law|break|violat\w*)\b', re.I)
_DRAFT_REQUEST = re.compile(
    r'\b(draft|prepare|generate\s+.*(?:STR|SAR|report|filing)|create\s+.*(?:STR|SAR|report|filing))\b', re.I)

_CLASSIFIER_PROMPT = """\
You are a routing classifier for an AML (anti-money-laundering) analyst platform.
Given a user question, return the set of intents that apply.

Intents (one or more may apply):
- evidence: the user wants transaction data, account details, typology evidence, who/what/where facts
- policy: the user asks about regulations, rules, obligations, controls, compliance, what law applies, what a case breaks or violates
- filing_decision: the user asks whether to file/report, whether an STR/SAR is required, whether to notify the regulator, or any question whose answer is a filing recommendation
- speculative: the user asks about future regulator actions, predictions of fines, sanctions, audit outcomes, or what will happen next year — anything requiring speculation beyond current data

Also extract any typology IDs (TYP-NNNN) and account IDs (ANNNNNNN) mentioned.

Question: {question}
"""

_CLASSIFIER_SCHEMA = {
    'type': 'json',
    'schema': {
        'type': 'object',
        'properties': {
            'intents': {
                'type': 'array',
                'items': {'type': 'string', 'enum': ['evidence', 'policy', 'filing_decision', 'speculative']}
            },
            'typology_ids': {'type': 'array', 'items': {'type': 'string'}},
            'account_ids': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['intents', 'typology_ids', 'account_ids'],
    },
}


def classify_question_llm(cursor, question: str) -> dict | None:
    """Call AI_COMPLETE to classify intents. Returns dict or None on failure."""
    prompt = _CLASSIFIER_PROMPT.format(question=question)
    try:
        rows = _sql(cursor,
            "SELECT SNOWFLAKE.CORTEX.AI_COMPLETE("
            "  'claude-sonnet-4-5',"
            "  %s,"
            "  PARSE_JSON(%s)"
            ") AS result",
            (prompt, json.dumps({'response_format': _CLASSIFIER_SCHEMA})))
        raw = rows[0][0] if rows else None
        if raw is None:
            return None
        parsed = json.loads(raw) if isinstance(raw, str) else raw
        # AI_COMPLETE may wrap in an outer object with a "choices" key or return directly
        if isinstance(parsed, dict) and "intents" in parsed:
            return parsed
        # Sometimes the response is a JSON string inside the result
        if isinstance(parsed, str):
            return json.loads(parsed)
        return None
    except Exception:
        return None


def _classify_question_regex(question: str) -> str:
    """Legacy regex-based classifier (fallback)."""
    if _REPORTING_VOCAB.search(question) and _CASE_REFERENCE.search(question):
        return "file"
    if _FILE_PATTERN.search(question):
        return "file"
    has_policy = bool(_POLICY_PATTERN.search(question))
    has_evidence = bool(_EVIDENCE_PATTERN.search(question))
    if has_policy and has_evidence:
        return "combined"
    if has_policy:
        return "policy"
    return "evidence"


def classify_question(question: str, cursor=None) -> str:
    """Return one of: evidence, policy, file, pii_refusal, ungrounded_refusal, combined.

    Uses LLM intent classification with deterministic safety overrides.
    Falls back to regex if the LLM call fails.
    """
    # --- Deterministic refusal gates (always first) ---
    if (_PII_LOOKUP_PATTERN.search(question) or _PII_OF_PATTERN.search(question)
            or _PII_WHO_PATTERN.search(question)):
        return "pii_refusal"
    if _UNGROUNDED_PATTERN.search(question):
        return "ungrounded_refusal"

    # --- LLM classification ---
    llm_result = None
    if cursor is not None:
        llm_result = classify_question_llm(cursor, question)

    if llm_result is not None:
        intents = set(llm_result.get("intents", []))
    else:
        # Fallback to regex
        return _classify_question_regex(question)

    # --- Speculative intent (from LLM) ---
    if "speculative" in intents:
        return "ungrounded_refusal"

    # --- Hard safety rules (deterministic, post-LLM) ---
    # Filing/reporting intent must always reach the Verifier — but ONLY when
    # the question references a specific case (typology, finding, account, or
    # deictic like "this case / the mule network").
    if _REPORTING_VOCAB.search(question) and _CASE_REFERENCE.search(question):
        intents.add("filing_decision")
    # Questions about rules/regulations must include Policy
    if _POLICY_VOCAB.search(question):
        intents.add("policy")

    # --- Map intents to routing category ---
    if "filing_decision" in intents:
        return "file"
    has_policy = "policy" in intents
    has_evidence = "evidence" in intents
    if has_policy and has_evidence:
        return "combined"
    if has_policy:
        return "policy"
    return "evidence"


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

def orchestrate(question: str, cursor=None) -> OrchestratorResult:
    """Main entry point: classify, route, compose."""
    if cursor is None:
        cursor, _ = _get_connection()

    run_id = str(uuid.uuid4())[:12]
    result = OrchestratorResult(run_id=run_id, question=question, answer="")
    step_num = 0

    # Classify with LLM (cursor enables the LLM path; without it, falls back to regex)
    t0 = time.time()
    category = classify_question(question, cursor=cursor)

    # Log classifier result as a handoff step
    step_num += 1
    classifier_step = HandoffStep(
        step=step_num, from_agent="ORCHESTRATOR", to_agent="CLASSIFIER",
        input_summary=question[:200],
        output_summary=json.dumps({"category": category}),
        duration_ms=int((time.time() - t0) * 1000))
    result.steps.append(classifier_step)
    log_handoff(cursor, run_id, classifier_step)

    # --- PII refusal ---
    if category == "pii_refusal":
        result.answer = (
            "I cannot provide personally identifiable information such as national IDs, "
            "phone numbers, or full names. The ARGUS platform masks all PII. "
            "I can help with hashed identifiers, risk ratings, and transaction patterns."
        )
        step_num += 1
        step = HandoffStep(step=step_num, from_agent="orchestrator", to_agent="REFUSAL",
                           input_summary=question[:200], output_summary="PII request refused")
        result.steps.append(step)
        log_handoff(cursor, run_id, step)
        return result

    # --- Ungrounded refusal ---
    if category == "ungrounded_refusal":
        result.answer = (
            "I cannot answer this question because it requires speculation or prediction "
            "beyond what the data supports. ARGUS provides evidence-backed analysis of "
            "detected fraud typologies and regulatory obligations — not forecasts."
        )
        step_num += 1
        step = HandoffStep(step=step_num, from_agent="orchestrator", to_agent="REFUSAL",
                           input_summary=question[:200], output_summary="Ungrounded question refused")
        result.steps.append(step)
        log_handoff(cursor, run_id, step)
        return result

    # --- Filing decision path ---
    if category == "file":
        typology_ids = _TYPOLOGY_ID_PATTERN.findall(question)
        account_ids = _ACCOUNT_ID_PATTERN.findall(question)

        # Pre-check: if accounts are given but no typology, check if they share one.
        if not typology_ids and account_ids and len(account_ids) >= 2:
            shared_typ = check_shared_typology(cursor, account_ids)
            if shared_typ is None:
                memberships = check_any_typology(cursor, account_ids)
                not_in = [a for a in account_ids if a not in memberships]

                step_num += 1
                t0 = time.time()
                ev_q = f"What signals link accounts {', '.join(account_ids)}? Check shared devices, shared national IDs, and typology evidence."
                ev_resp = call_agent(cursor, "ARGUS.GOVERNED.EVIDENCE_AGENT", ev_q)
                ev_text = extract_agent_text(ev_resp)
                step = HandoffStep(step=step_num, from_agent="orchestrator",
                                   to_agent="EVIDENCE_AGENT", input_summary=ev_q[:200],
                                   output_summary=ev_text[:500], refs=extract_refs(ev_resp),
                                   duration_ms=int((time.time() - t0) * 1000))
                result.steps.append(step)
                log_handoff(cursor, run_id, step)

                step_num += 1
                reject_reason = (
                    f"Accounts {', '.join(account_ids)} do not share a common typology. "
                    f"{'Account(s) ' + ', '.join(not_in) + ' are not in any detected fraud ring. ' if not_in else ''}"
                    f"The link between them (shared device/identifier) is a weak signal "
                    f"insufficient for a filing recommendation."
                )
                step = HandoffStep(step=step_num, from_agent="orchestrator",
                                   to_agent="VERIFIER:WEAK_SIGNAL_REJECT",
                                   input_summary=f"accounts={account_ids}, shared_typology=None",
                                   output_summary="REJECTED: weak signal only",
                                   refs=account_ids, duration_ms=0)
                result.steps.append(step)
                log_handoff(cursor, run_id, step)

                result.answer = (
                    f"## Filing Decision: **REJECTED**\n\n"
                    f"**Reason:** {reject_reason}\n\n"
                    f"### Evidence\n{ev_text[:1000]}\n\n"
                    f"No STR drafts have been generated. The shared device/identifier link "
                    f"alone does not meet the evidentiary threshold for filing."
                )
                result.citations = extract_refs(ev_resp) + account_ids
                return result

        # Step 1: Get evidence from Evidence Agent
        step_num += 1
        t0 = time.time()
        evidence_q = question
        if not typology_ids and account_ids:
            evidence_q = f"What suspicious activity is linked to accounts {', '.join(account_ids)}?"
        elif typology_ids:
            evidence_q = f"Summarize the evidence for typology {typology_ids[0]} including member accounts, roles, transactions, and total value."

        ev_resp = call_agent(cursor, "ARGUS.GOVERNED.EVIDENCE_AGENT", evidence_q)
        ev_text = extract_agent_text(ev_resp)
        ev_refs = extract_refs(ev_resp)
        step = HandoffStep(step=step_num, from_agent="orchestrator",
                           to_agent="EVIDENCE_AGENT", input_summary=evidence_q[:200],
                           output_summary=ev_text[:500], refs=ev_refs,
                           duration_ms=int((time.time() - t0) * 1000))
        result.steps.append(step)
        log_handoff(cursor, run_id, step)

        # Step 2: Idempotent Verifier — reuse existing finding if available
        finding_id = None
        status = None
        reason = ""
        reused = False
        resolved_typology = typology_ids[0].upper() if typology_ids else None

        # If we only have account IDs, resolve their shared typology for idempotency
        if not resolved_typology and account_ids:
            shared_typ = check_shared_typology(cursor, account_ids)
            if shared_typ:
                resolved_typology = shared_typ
            elif len(account_ids) == 1:
                memberships = check_any_typology(cursor, account_ids)
                typs = memberships.get(account_ids[0], [])
                if typs:
                    resolved_typology = typs[0] if isinstance(typs[0], str) else str(typs[0])

        if resolved_typology:
            existing = find_existing_finding(cursor, resolved_typology)
            if existing:
                finding_id = existing["finding_id"]
                status = existing["status"]
                reason = existing["reason"] or ""
                reused = True
                step_num += 1
                step = HandoffStep(step=step_num, from_agent="orchestrator",
                                   to_agent="VERIFIER:REUSE_FINDING",
                                   input_summary=f"typology={resolved_typology}",
                                   output_summary=f"Reusing {finding_id} (status={status})",
                                   refs=[finding_id], duration_ms=0)
                result.steps.append(step)
                log_handoff(cursor, run_id, step)

        if not reused:
            step_num += 1
            t0 = time.time()
            if resolved_typology:
                build_result = call_build_finding(cursor, resolved_typology)
            elif account_ids:
                build_result = call_build_finding_adhoc(cursor, account_ids)
            else:
                build_result = "ERROR: No typology or account IDs found in the question."

            step = HandoffStep(step=step_num, from_agent="orchestrator",
                               to_agent="VERIFIER:SP_BUILD_FINDING",
                               input_summary=f"typology={typology_ids or account_ids}",
                               output_summary=build_result[:500],
                               duration_ms=int((time.time() - t0) * 1000))
            result.steps.append(step)
            log_handoff(cursor, run_id, step)

            fid_match = re.search(r'(FND-\d{4})', build_result)
            if fid_match:
                finding_id = fid_match.group(1)
            else:
                rows = _sql(cursor,
                    "SELECT finding_id FROM ARGUS.GOVERNED.FINDING ORDER BY created_at DESC LIMIT 1")
                finding_id = rows[0][0] if rows else None

            if not finding_id:
                result.answer = f"Could not build a finding. {build_result}"
                return result

            # Verify
            step_num += 1
            t0 = time.time()
            verify_result = call_verify_finding(cursor, finding_id)
            finding_status = get_finding_status(cursor, finding_id)
            step = HandoffStep(step=step_num, from_agent="orchestrator",
                               to_agent="VERIFIER:SP_VERIFY_FINDING",
                               input_summary=f"finding_id={finding_id}",
                               output_summary=f"{verify_result[:300]} | status={finding_status.get('status')}",
                               refs=[finding_id],
                               duration_ms=int((time.time() - t0) * 1000))
            result.steps.append(step)
            log_handoff(cursor, run_id, step)

            status = finding_status.get("status", "UNKNOWN")
            reason = finding_status.get("reason", "")

        result.finding_id = finding_id

        if status == "VERIFIED":
            # Check for existing filings before deciding whether to draft
            filings = get_filings_for_finding(cursor, finding_id)
            user_wants_draft = bool(_DRAFT_REQUEST.search(question))

            if not filings and user_wants_draft:
                step_num += 1
                t0 = time.time()
                draft_result = call_draft_filing(cursor, finding_id)
                filings = get_filings_for_finding(cursor, finding_id)
                step = HandoffStep(step=step_num, from_agent="orchestrator",
                                   to_agent="NARRATIVE:SP_DRAFT_FILING",
                                   input_summary=f"finding_id={finding_id}",
                                   output_summary=draft_result[:500],
                                   refs=[f["filing_id"] for f in filings],
                                   duration_ms=int((time.time() - t0) * 1000))
                result.steps.append(step)
                log_handoff(cursor, run_id, step)

            result.filing_ids = [f["filing_id"] for f in filings]

            # Policy context
            step_num += 1
            t0 = time.time()
            policy_q = f"Which regulatory obligations are touched by typology {typology_ids[0] if typology_ids else 'this network'} and are there control gaps?"
            pol_resp = call_agent(cursor, "ARGUS.GOVERNED.POLICY_AGENT", policy_q)
            pol_text = extract_agent_text(pol_resp)
            pol_refs = extract_refs(pol_resp)
            step = HandoffStep(step=step_num, from_agent="orchestrator",
                               to_agent="POLICY_AGENT", input_summary=policy_q[:200],
                               output_summary=pol_text[:500], refs=pol_refs,
                               duration_ms=int((time.time() - t0) * 1000))
            result.steps.append(step)
            log_handoff(cursor, run_id, step)

            filing_summary = "\n".join(
                f"  - **{f['filing_id']}** ({f['type']}) for {f['bank'] or 'all banks'} "
                f"→ {f['regulator'] or 'N/A'} — status: {f['status']}"
                for f in filings
            ) if filings else "  No STR drafts generated yet. Ask me to draft/prepare them if needed."

            result.answer = (
                f"## Filing Decision: **{status}**\n\n"
                f"**Finding:** {finding_id}{' (reused)' if reused else ''} | **Reason:** {reason}\n\n"
                f"### Evidence Summary\n{ev_text[:1000]}\n\n"
                f"### STR Drafts\n{filing_summary}\n\n"
                f"### Regulatory Context\n{pol_text[:1000]}\n"
            )
        else:
            result.answer = (
                f"## Filing Decision: **{status}**\n\n"
                f"**Finding:** {finding_id}{' (reused)' if reused else ''}\n"
                f"**Reason:** {reason}\n\n"
                f"### Evidence Summary\n{ev_text[:1000]}\n\n"
                f"The Verifier determined there is insufficient evidence to file. "
                f"No STR drafts have been generated."
            )

        result.citations = ev_refs + [finding_id] + result.filing_ids
        return result

    # --- Evidence-only path ---
    if category == "evidence":
        step_num += 1
        t0 = time.time()
        ev_resp = call_agent(cursor, "ARGUS.GOVERNED.EVIDENCE_AGENT", question)
        ev_text = extract_agent_text(ev_resp)
        ev_refs = extract_refs(ev_resp)
        step = HandoffStep(step=step_num, from_agent="orchestrator",
                           to_agent="EVIDENCE_AGENT", input_summary=question[:200],
                           output_summary=ev_text[:500], refs=ev_refs,
                           duration_ms=int((time.time() - t0) * 1000))
        result.steps.append(step)
        log_handoff(cursor, run_id, step)
        result.answer = ev_text
        result.citations = ev_refs
        return result

    # --- Policy-only path ---
    if category == "policy":
        step_num += 1
        t0 = time.time()
        pol_resp = call_agent(cursor, "ARGUS.GOVERNED.POLICY_AGENT", question)
        pol_text = extract_agent_text(pol_resp)
        pol_refs = extract_refs(pol_resp)
        step = HandoffStep(step=step_num, from_agent="orchestrator",
                           to_agent="POLICY_AGENT", input_summary=question[:200],
                           output_summary=pol_text[:500], refs=pol_refs,
                           duration_ms=int((time.time() - t0) * 1000))
        result.steps.append(step)
        log_handoff(cursor, run_id, step)
        result.answer = pol_text
        result.citations = pol_refs
        return result

    # --- Combined (evidence + policy) ---
    if category == "combined":
        # Evidence first
        step_num += 1
        t0 = time.time()
        ev_resp = call_agent(cursor, "ARGUS.GOVERNED.EVIDENCE_AGENT", question)
        ev_text = extract_agent_text(ev_resp)
        ev_refs = extract_refs(ev_resp)
        step = HandoffStep(step=step_num, from_agent="orchestrator",
                           to_agent="EVIDENCE_AGENT", input_summary=question[:200],
                           output_summary=ev_text[:500], refs=ev_refs,
                           duration_ms=int((time.time() - t0) * 1000))
        result.steps.append(step)
        log_handoff(cursor, run_id, step)

        # Policy second
        step_num += 1
        t0 = time.time()
        pol_resp = call_agent(cursor, "ARGUS.GOVERNED.POLICY_AGENT", question)
        pol_text = extract_agent_text(pol_resp)
        pol_refs = extract_refs(pol_resp)
        step = HandoffStep(step=step_num, from_agent="orchestrator",
                           to_agent="POLICY_AGENT", input_summary=question[:200],
                           output_summary=pol_text[:500], refs=pol_refs,
                           duration_ms=int((time.time() - t0) * 1000))
        result.steps.append(step)
        log_handoff(cursor, run_id, step)

        # Safety net: if any agent defers filing to the Verifier, escalate
        _DEFER_RE = re.compile(
            r'(filing\s+decision.*verifier|cannot\s+recommend\s+filing|'
            r'verifier\s+should\s+decide|refer.*to.*verifier|'
            r'not\s+authorized\s+to.*fil)', re.I)
        combined_text = ev_text + "\n" + pol_text
        if _DEFER_RE.search(combined_text):
            typology_ids = _TYPOLOGY_ID_PATTERN.findall(question) or _TYPOLOGY_ID_PATTERN.findall(combined_text)
            if typology_ids:
                resolved_typ = typology_ids[0].upper()
                # Idempotent: reuse existing finding
                existing = find_existing_finding(cursor, resolved_typ)
                if existing:
                    finding_id = existing["finding_id"]
                    status = existing["status"]
                    step_num += 1
                    step = HandoffStep(step=step_num, from_agent="orchestrator",
                                       to_agent="VERIFIER:REUSE_FINDING",
                                       input_summary=f"typology={resolved_typ} (escalated from combined)",
                                       output_summary=f"Reusing {finding_id} (status={status})",
                                       refs=[finding_id], duration_ms=0)
                    result.steps.append(step)
                    log_handoff(cursor, run_id, step)
                else:
                    step_num += 1
                    t0 = time.time()
                    build_result = call_build_finding(cursor, resolved_typ)
                    step = HandoffStep(step=step_num, from_agent="orchestrator",
                                       to_agent="VERIFIER:SP_BUILD_FINDING",
                                       input_summary=f"typology={resolved_typ} (escalated from combined)",
                                       output_summary=build_result[:500],
                                       duration_ms=int((time.time() - t0) * 1000))
                    result.steps.append(step)
                    log_handoff(cursor, run_id, step)

                    fid_match = re.search(r'(FND-\d{4})', build_result)
                    finding_id = fid_match.group(1) if fid_match else None
                    if finding_id:
                        step_num += 1
                        t0 = time.time()
                        call_verify_finding(cursor, finding_id)
                        finding_status = get_finding_status(cursor, finding_id)
                        status = finding_status.get("status", "UNKNOWN")
                        step = HandoffStep(step=step_num, from_agent="orchestrator",
                                           to_agent="VERIFIER:SP_VERIFY_FINDING",
                                           input_summary=f"finding_id={finding_id}",
                                           output_summary=f"status={status}",
                                           refs=[finding_id],
                                           duration_ms=int((time.time() - t0) * 1000))
                        result.steps.append(step)
                        log_handoff(cursor, run_id, step)

                if finding_id:
                    result.finding_id = finding_id
                    # Report existing filings but never auto-draft from combined path
                    filings = get_filings_for_finding(cursor, finding_id)
                    result.filing_ids = [f["filing_id"] for f in filings]

                    result.answer = (
                        f"### Evidence\n{ev_text[:1000]}\n\n"
                        f"### Regulatory Context\n{pol_text[:1000]}\n\n"
                        f"### Filing Decision: **{status}**\n"
                        f"Finding: {finding_id}\n"
                    )
                    result.citations = ev_refs + pol_refs + [finding_id]
                    return result

        result.answer = (
            f"### Evidence\n{ev_text[:1500]}\n\n"
            f"### Regulatory Context\n{pol_text[:1500]}"
        )
        result.citations = ev_refs + pol_refs
        return result

    # Fallback
    result.answer = "I could not determine how to route this question."
    return result


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import sys
    question = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else \
        "Show me emerging cross-bank fraud we were exposed to in September 2026."
    r = orchestrate(question)
    print(f"\n{'='*72}")
    print(f"Run ID: {r.run_id}")
    print(f"Question: {r.question}")
    print(f"Category: {classify_question(r.question, cursor=None)}")
    print(f"Steps: {len(r.steps)}")
    for s in r.steps:
        print(f"  {s.step}. {s.from_agent} → {s.to_agent} ({s.duration_ms}ms)")
    if r.finding_id:
        print(f"Finding: {r.finding_id}")
    if r.filing_ids:
        print(f"Filings: {r.filing_ids}")
    print(f"{'='*72}")
    print(r.answer)
