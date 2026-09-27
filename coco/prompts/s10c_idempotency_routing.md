# CoCo session S10c — IDEMPOTENT FILING PATH + PRECISE ROUTING GATES

Project: **ARGUS** (team TCC). S10b (interrupted by a network error after the code change)
added an LLM intent classifier and a reporting-vocabulary safety net to
`app/orchestrator.py`. Filing intents now reliably reach the Verifier, but an independent
evaluation found four problems:

1. **Duplicates on every filing question.** Each filing-intent question calls
   `SP_BUILD_FINDING` + `SP_DRAFT_FILING` again: TYP-0003 now has 12 VERIFIED findings;
   `FILING` has 68 drafts (several `REJECTED_GROUNDING`). An analyst would see a dozen copies
   of one case, and each costs AI calls.
2. **Over-broad PII gate.** "Which accounts share a device or national ID across more than
   one bank?" (an ontology question about HASHED shared identifiers) is now refused because
   it mentions "national ID". Block requests FOR a person's value (e.g. "what is the
   national ID of…", "give me the phone number of…", "who is the holder of…"), not
   mentions of identifier types or hashes.
3. **Safety net over-triggers and has side effects.** A general policy question that merely
   contains "filing" (e.g. about filing deadlines in a rulebook, no specific case) ran the
   Verifier AND drafted STRs. Apply the reporting-vocabulary rule only when the question
   references a specific case (typology/finding/account ID, or "this case/ring/network").
   Running the Verifier must never draft filings as a side effect.
4. **Speculation not refused.** Questions predicting future regulator actions (fines,
   sanctions, audit outcomes, "next year") must be refused as ungrounded. Add a
   `speculative` intent to the classifier AND keep a deterministic regex gate.

## Change
- **Idempotent Verifier path**: before building, look up the latest VERIFIED (or REJECTED)
  finding for the typology whose claims are still valid (typology evidence unchanged since
  `created_at`); reuse it. Build only when none exists or the evidence changed.
- **Drafting only on request**: the filing path reports the Verifier decision and lists
  EXISTING drafts; it calls `SP_DRAFT_FILING` only if the user asks to prepare/draft a report
  AND no pending drafts exist for that finding.
- **Retry on grounding rejection**: in `SP_DRAFT_FILING` (`sql/12_findings.sql`), regenerate
  a draft up to 2 more times when it fails the grounding/leak check before storing
  `REJECTED_GROUNDING`. Keep procedures fully schema-qualified.
- **Clean up evaluation artefacts**: keep ONE finding per typology — the earliest VERIFIED
  one (FND-0007…FND-0011) — and its drafts; delete the other duplicate findings, their
  claims and filings, and all `ADHOC` test findings. Report counts before/after.

## Verify
- Update `validation/validate_orchestrator.py` (dev set from `coco/prompts/s10b_robust_routing.md`
  plus the four problem classes above, in your own wording) and write
  `validation/orchestrator_report.md`. Asking the same filing question twice must create
  NO new finding and NO new filing.
- Re-run `validation/validate_orchestrator_e2e.py` (do not edit it): target 12/12.
- Re-run `validation/validate_findings.py` (must stay all-pass).
Write `evidence/coco_s10c_idempotency.md` (before/after counts, routing results).

Rules: drafts only; nothing is sent. Role checks start with `USE SECONDARY ROLES NONE;`.
