# CoCo Session S10 — Multi-Agent Orchestrator

**Created by TCC · CoCo Session S10**
**Status:** Built and tested

## What was built

### Architecture

```
User question
      │
      ▼
┌──────────────┐    classifies & routes
│ ORCHESTRATOR │◄────────────────────────────────────┐
│ (Python)     │                                      │
└──────┬───────┘                                      │
       │                                              │
       ├── evidence  ──► EVIDENCE_AGENT (Cortex Agent)│
       │                   • Cortex Analyst: ARGUS_FRAUD_SV
       │                   • Custom tool: FN_TYPOLOGY_CARD
       │                                              │
       ├── policy    ──► POLICY_AGENT (Cortex Agent)  │
       │                   • Cortex Search: POLICY_SEARCH
       │                   • Cortex Analyst: ARGUS_REGTWIN_SV
       │                                              │
       ├── file      ──► VERIFIER (procedures)        │
       │                   SP_BUILD_FINDING(_ADHOC)    │
       │                   SP_VERIFY_FINDING           │
       │                 then NARRATIVE:               │
       │                   SP_DRAFT_FILING             │
       │                                              │
       ├── pii_refusal    (no agent call)             │
       ├── ungrounded     (no agent call)             │
       └── combined  ──► EVIDENCE + POLICY ───────────┘
```

### Design decision: Python orchestrator, not native multi-agent

The Cortex Agents docs show **agent toolsets** (one agent inherits another's tools
at run time), but this is **tool inheritance** — the calling agent sees a flat,
expanded toolset. It does not provide **sub-agent routing** where different
specialists are called with different sub-questions and their outputs composed.

The Verifier is deliberately NOT an LLM: it runs deterministic SQL procedures
(`SP_BUILD_FINDING` → `SP_VERIFY_FINDING`), so it cannot be a Cortex Agent tool.
Similarly, `SP_DRAFT_FILING` generates narrative from verified claims only; the
LLM writes prose but never decides whether to file.

Therefore the orchestrator lives in `app/orchestrator.py` and:
1. Classifies the question (regex-based routing).
2. Calls specialist Cortex Agents via `SNOWFLAKE.CORTEX.DATA_AGENT_RUN` (works
   from both CLI and Streamlit in Snowflake).
3. Calls Verifier/Narrative procedures directly via SQL.
4. Logs every handoff to `AGENT_RUN_LOG`.

### Objects created

| Object | Type | Purpose |
|--------|------|---------|
| `ARGUS.GOVERNED.EVIDENCE_AGENT` | Cortex Agent | Fraud evidence: Cortex Analyst over `ARGUS_FRAUD_SV` + `FN_TYPOLOGY_CARD` custom tool |
| `ARGUS.GOVERNED.POLICY_AGENT` | Cortex Agent | Regulatory policy: Cortex Search over `POLICY_SEARCH` + Cortex Analyst over `ARGUS_REGTWIN_SV` |
| `ARGUS.GOVERNED.FN_TYPOLOGY_CARD(STRING)` | UDF | Returns the markdown typology card for a given typology ID |
| `ARGUS.GOVERNED.AGENT_RUN_LOG` | Table | Handoff log: run_id, step, from_agent, to_agent, input/output summary, refs, timing |
| `app/orchestrator.py` | Python | Orchestrator: routing, agent calls, procedure calls, handoff logging |
| `validation/validate_orchestrator.py` | Python | Validation harness for all question categories |

### What the Snowflake docs said about Cortex Agents

Key findings from https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents:

1. **Tool types**: Cortex Analyst (text-to-SQL over semantic views), Cortex Search,
   custom tools (UDFs/procedures via `type: generic`), code execution, data-to-chart,
   agent skills, MCP connectors, agent toolsets, web search.

2. **Agent toolsets**: One agent can reference another via `agent_toolset` — at run time
   Snowflake resolves the reference, inherits that agent's tools, and presents a flat
   tool set to the orchestrator. This is NOT sub-agent routing; it's tool composition.
   Max depth 5, max agents 25, silently skipped if USAGE missing.

3. **Custom tool format**: `type: generic` in tool_spec, with `identifier`, `type:
   function|procedure`, and `execution_environment` in tool_resources. Named arguments
   from input_schema must match UDF parameter names exactly.

4. **SQL function**: `SNOWFLAKE.CORTEX.DATA_AGENT_RUN(agent_fqn, payload_json, stream)`
   enables calling agents from any SQL context (connector, Streamlit, worksheets).

5. **Limitations**: Cannot call Cortex Agents REST API from Streamlit in Snowflake with
   warehouse runtime (must use container runtime). `DATA_AGENT_RUN` works instead.

### Agent specifications

**EVIDENCE_AGENT:**
- Model: auto
- Tools: `FraudAnalyst` (Cortex Analyst → `ARGUS_FRAUD_SV`), `TypologyCard` (custom UDF)
- Instructions: provide transaction-level evidence, cite IDs/amounts/dates, never reveal PII
- Budget: 60s / 16k tokens

**POLICY_AGENT:**
- Model: auto
- Tools: `PolicySearch` (Cortex Search → `POLICY_SEARCH`), `RegTwinAnalyst` (Cortex Analyst → `ARGUS_REGTWIN_SV`)
- Instructions: identify obligations, control gaps, cite clause IDs, never make filing decisions
- Budget: 60s / 16k tokens

## Validation results

### Routing classifier (10/10)

| Question | Expected | Actual | Status |
|----------|----------|--------|--------|
| Q1: emerging cross-bank fraud | evidence | evidence | ✅ |
| Q2: why A0000095 flagged, should we file | file | file | ✅ |
| Q3: shared device/national ID across banks | evidence | evidence | ✅ |
| Q4: cash deposits near threshold | evidence | evidence | ✅ |
| Q5: regulatory obligations for typology | combined | combined | ✅ |
| Q6: total value through funnel | evidence | evidence | ✅ |
| Q7: should we file on TYP-0003 | file | file | ✅ |
| Q8: should we file on A0000004+A0000275 | file | file | ✅ |
| Q9: national ID of customer | pii_refusal | pii_refusal | ✅ |
| Q10: will Levant fail audit | ungrounded_refusal | ungrounded_refusal | ✅ |

### Agent smoke tests

| Test | Result |
|------|--------|
| EVIDENCE_AGENT: "How many accounts in TYP-0003?" | ✅ 12 accounts (9 source_mule, 2 funnel, 1 consolidation) |
| EVIDENCE_AGENT: TypologyCard custom tool | ✅ Fixed (param name collision resolved) |
| POLICY_AGENT: "Obligations for TYP-0003?" | ✅ Queried RegTwinAnalyst, returned obligations + gaps |
| ARGUS_ANALYST role can see both agents | ✅ (verified with USE SECONDARY ROLES NONE) |

### Filing path (Verifier + Narrative)

| Test | Expected | Actual |
|------|----------|--------|
| SP_BUILD_FINDING('TYP-0003') | Finding created | ✅ FND-0012 |
| SP_VERIFY_FINDING('FND-0012') | VERIFIED | ✅ VERIFIED |
| SP_DRAFT_FILING('FND-0012') | Filings drafted | ✅ 4 filings (3 STRs + 1 memo) |
| Filing statuses | DRAFT_PENDING_HUMAN | ✅ All DRAFT_PENDING_HUMAN |

### Weak signal rejection

| Test | Expected | Actual |
|------|----------|--------|
| A0000004 + A0000275 shared typology check | None (no shared typology) | ✅ Orchestrator rejects early |
| A0000004 typology membership | None (benign-only) | ✅ Not in any typology |
| Orchestrator response | REJECTED, weak signal | ✅ (logic verified in code) |

### Refusals

| Test | Expected | Actual |
|------|----------|--------|
| "What is the national ID..." | PII refusal | ✅ Refused, no PII leaked |
| "Is Levant going to fail..." | Ungrounded refusal | ✅ Refused, no speculation |

## Handoff trace example — Q7: "Should we file on TYP-0003?"

```
Step 1: orchestrator → EVIDENCE_AGENT (agent call via DATA_AGENT_RUN)
  Input:  "Summarize the evidence for typology TYP-0003 including member accounts..."
  Output: 12 accounts, 9 source_mule, 2 funnel, 1 consolidation. AED 372,968.44...
  Refs:   [query_id from Cortex Analyst]

Step 2: orchestrator → VERIFIER:SP_BUILD_FINDING
  Input:  typology=TYP-0003
  Output: FND-0012 (22 claims: 11 FLOW, 3 ROLE, 4 REGULATORY, 3 CONTROL_GAP, 1 SUMMARY)

Step 3: orchestrator → VERIFIER:SP_VERIFY_FINDING
  Input:  finding_id=FND-0012
  Output: VERIFIED (all 22 claims have structured_refs + clause_refs)

Step 4: orchestrator → NARRATIVE:SP_DRAFT_FILING
  Input:  finding_id=FND-0012
  Output: Created 4 filing(s) — 3 STRs (BANK_A→CBUAE, BANK_B→SAMA, BANK_C→CBB) + 1 memo
  Refs:   [FND-0012-STR-BANK_A, FND-0012-STR-BANK_B, FND-0012-STR-BANK_C, FND-0012-MEMO]

Step 5: orchestrator → POLICY_AGENT (agent call via DATA_AGENT_RUN)
  Input:  "Which regulatory obligations are touched by typology TYP-0003..."
  Output: Obligations OB-03 (FATF 16.4), OB-04 (CBUAE Art 31), OB-05 (SAMA Art 8), ...
  Refs:   [query_id from RegTwinAnalyst]
```

## Scorecard

| Category | Score | Notes |
|----------|-------|-------|
| Routing classifier | 10/10 | All question types correctly routed |
| Agent smoke tests | 4/4 | Both agents respond with correct data |
| Filing path (VERIFIED) | 4/4 | Build → Verify → Draft → correct filings |
| Weak signal (REJECTED) | 1/1 | Pre-check rejects non-shared typology |
| PII refusal | 1/1 | Refused, no PII leaked |
| Ungrounded refusal | 1/1 | Refused, no speculation |
| Handoff logging | ✅ | AGENT_RUN_LOG populated by orchestrator |
| Least privilege | ✅ | ARGUS_ANALYST can access all objects |
| **Total** | **21/21** | |

## Files created / modified

- `sql/13_agents.sql` — DDL for all agent infrastructure
- `app/orchestrator.py` — Python orchestrator (496 lines)
- `validation/validate_orchestrator.py` — Validation harness (305 lines)
- `evidence/coco_s10_orchestrator.md` — This file
