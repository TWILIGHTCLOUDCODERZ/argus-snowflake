# CoCo session S9 — FINDINGS, EVIDENCE LEDGER, VERIFIER GUARDRAIL, FILING DRAFTS

Project: **ARGUS** (team TCC). Read `docs/WEEK3_PLAN.md`. Session S8 built
`ARGUS.GOVERNED.TYPOLOGY` + `TYPOLOGY_EVIDENCE` (discovered typologies, roles, cards) and
class-based `TYPOLOGY_EXPOSURE` (typology → obligation → gap). The twin has `CLAUSE`,
`OBLIGATION`, `CONTROL`, `CONTROL_GAP`; documents are searchable via Cortex Search
`ARGUS.GOVERNED.POLICY_SEARCH`; past STRs are in `PAST_FILINGS` / `DOCUMENTS`.

Principle: **claims are facts computed by SQL; the LLM only writes prose from verified
claims.** Nothing is filed automatically — every filing is a draft awaiting a human.

## Build (all SQL in `sql/12_findings.sql`)
1. **Tables** (GOVERNED):
   - `FINDING` (finding_id `FND-0001`…, typology_id, typology_class, title, banks_involved,
     total_value, confidence, status DRAFT|VERIFIED|REJECTED, verifier_reason,
     created_at, verified_at)
   - `FINDING_CLAIM` (claim_id, finding_id, claim_seq, claim_type
     FLOW|ROLE|IDENTITY|STRUCTURING|REGULATORY|CONTROL_GAP, claim_text, bank_id,
     structured_refs ARRAY (txn_ids / account_ids / signal hashes), clause_refs ARRAY
     (clause_ids), confidence, verified BOOLEAN, verification_note)
   - `FILING` (filing_id, finding_id, filing_type STR|CONTROL_GAP_MEMO, bank_id,
     regulator, fiu, narrative_md, cited_claims ARRAY, status DRAFT_PENDING_HUMAN,
     grounding_check VARIANT, created_at, approved_by NULL)
2. **`SP_BUILD_FINDING(typology_id)`** — builds claims deterministically from data:
   flow claims (who sent what to whom, totals, windows — with the txn_ids), role claims,
   identity/structuring claims where relevant, REGULATORY claims from
   `TYPOLOGY_EXPOSURE` (obligation + clause_id, with the clause text retrieved via
   `POLICY_SEARCH` filtered to `doc_type = 'circular'` and the right regulator), and
   CONTROL_GAP claims from `CONTROL_GAP` (e.g. C-12 not deployed). Each FLOW/ROLE claim
   must also cite the clause of the obligation it evidences. Claim text is templated
   from the SQL facts — no LLM here.
3. **`SP_BUILD_FINDING_ADHOC(account_ids ARRAY)`** — same, for an arbitrary set of
   accounts a user asks about (used by the Orchestrator for "why was X flagged?").
4. **`SP_VERIFY_FINDING(finding_id)`** — the guardrail. Re-check every ref against the
   data (never trust stored refs): each claim needs ≥1 structured ref that exists AND
   ≥1 clause ref that exists in `CLAUSE`. A finding is VERIFIED only if every claim
   passes and confidence ≥ 0.7; otherwise REJECTED with a specific reason. Weak-signal
   rule: evidence consisting only of a shared device (no flows, no national-ID link,
   no structuring) → REJECTED "insufficient evidence — weak signal only".
5. **`SP_DRAFT_FILING(finding_id)`** — refuses unless the finding is VERIFIED. Produces:
   - one **STR per involved bank**, addressed to that bank's FIU (CBUAE → UAE FIU
     goAML; SAMA → GDFI; CBB → Financial Intelligence Directorate), citing **only that
     bank's own transactions/accounts** plus an anonymised statement of the cross-bank
     signal (data minimisation — never another bank's txn/account IDs);
   - one **CONTROL_GAP_MEMO** for the board summarising obligations with gaps.
   Narratives via `AI_COMPLETE('claude-sonnet-4-5', ...)` from the verified claims ONLY
   (passed as JSON), citing claim ids like `[C3]`, styled after the past STRs.
   **Grounding check** after generation: every number in the narrative must appear in a
   cited claim, and every STR's cited txn/account IDs must belong to its bank. Store the
   check result; a failed check sets status `REJECTED_GROUNDING` instead of a draft.

## Verify — `validation/validate_findings.py` → `validation/findings_report.md`
Use the answer key only to pick which discovered typology to test (member overlap).
1. The typology matching RING-001: build → verify → **VERIFIED**; draft → **3 STRs**
   (BANK_A/B/C) + 1 memo; each STR cites only its own bank's IDs; grounding passes.
2. The typology matching RING-003 (structuring, single bank): VERIFIED → 1 STR + memo.
3. **Refusal**: `SP_BUILD_FINDING_ADHOC` on BENIGN-001's two accounts → **REJECTED**
   (weak signal only) and `SP_DRAFT_FILING` on it **refuses**.
4. **Tamper test**: insert a claim with a fabricated txn_id into a copy of a verified
   finding → verify → **REJECTED** naming that claim; then delete the test finding.
5. `SP_DRAFT_FILING` on a DRAFT (unverified) finding → refuses.
6. Build + verify findings for every discovered typology; report each status.
Include one full STR draft and the board memo in the report.

Write `evidence/coco_s9_findings.md` (objects, guardrail rules, test results, sample STR).

Rules: never auto-file or send anything; drafts only. Use session-TEMPORARY tables for
any test scaffolding; delete test findings you create. Grants: new GOVERNED tables are
covered by future grants; if you CREATE OR REPLACE an existing object, re-grant SELECT to
ARGUS_ANALYST. Role checks must start with `USE SECONDARY ROLES NONE;`.
