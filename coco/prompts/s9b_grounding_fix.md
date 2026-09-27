# CoCo session S9b — MAKE THE GROUNDING CHECK REAL (+ explicit weak-signal reason)

Project: **ARGUS** (team TCC). Session S9 built findings, the Verifier and filing drafts
(`sql/12_findings.sql`). An independent review found:

1. **`SP_DRAFT_FILING`'s grounding check does not check numbers.** It stores
   `grounding_passed: true` after only counting cited claim markers and other-bank account
   leaks; for CONTROL_GAP_MEMO it is hard-coded `TRUE`. The brief required: every number in
   the narrative must appear in a cited claim.
2. Consequences observed: the ring total "AED 372,968.44" appears in all three FND-0003
   STRs but in no cited claim; the memos cite no claims at all (`[Cn]` markers missing).
   Note: stored `cited_claims` use local ids (`C01`) while `FINDING_CLAIM.claim_id` is
   `FND-0005-C01` — map correctly.
3. **Weak-signal rule not explicit.** `SP_BUILD_FINDING_ADHOC(['A0000004'])` →
   REJECTED "Confidence 0.5 below 0.70 threshold". The brief asked for the explicit reason
   "insufficient evidence — weak signal only" when the only evidence is a shared device
   (no flows, no national-ID link, no structuring). Keep the confidence rule too.

## Fix (edit `sql/12_findings.sql`; tables use IF NOT EXISTS — do not drop data)
- `SP_BUILD_FINDING`: add a **SUMMARY** claim with the finding's total value, time window,
  banks and member counts (so totals are citable).
- A reusable grounding function/procedure (e.g. `ARGUS.GOVERNED.FN_GROUNDING_CHECK`):
  extract numbers from the narrative, ignoring ID tokens (A0000xxx, TXxxxxxxxx, FND-, TYP-,
  OB-, CL-, C-xx, STR-yyyy-nnnn), article references (e.g. "16.4", "FC-6.1", "Art. 12") and
  dates/years; normalise (remove thousands separators, compare numerically so 27139.8 ==
  27139.80); each remaining number must appear in the text or refs of a CITED claim
  (mapping local `Cnn` → `<finding_id>-Cnn`). Return `{numbers_checked, violations[],
  passed}`.
- `SP_DRAFT_FILING`: memos must cite claims with `[Cnn]` too; run the check on every STR and
  memo; on violations set status `REJECTED_GROUNDING` and store the violations. Instruct
  the model to cite the SUMMARY claim for totals.
- `SP_VERIFY_FINDING`: explicit weak-signal rule with the reason text above.
- Fully qualify every object reference inside procedure bodies (`ARGUS.GOVERNED.…`,
  `ARGUS.RAW.…`), including temp tables — procedures must work from a session with no
  current schema. Test by calling them from a fresh connection without `USE SCHEMA`.

## Verify (update `validation/validate_findings.py` + `validation/findings_report.md`)
- **Negative tests of the check itself**: a narrative with a fabricated amount (e.g. "AED
  999,999.99") fails; a correct narrative passes; an article ref like "16.4" is ignored.
- Delete the existing FND-0003 and FND-0005 drafts, re-draft, and show each filing's
  `numbers_checked` and `violations` (must be 0) and status `DRAFT_PENDING_HUMAN`.
- `SP_BUILD_FINDING_ADHOC(['A0000004'])` → REJECTED with the explicit weak-signal reason;
  delete that test finding afterwards.
- Re-run the S9 suite (RING-001/RING-003 findings, tamper test, refusals) — all pass.
Write `evidence/coco_s9b_grounding_fix.md` (before/after, negative-test results).

Rules: drafts only. Grants: re-grant USAGE/SELECT to ARGUS_ANALYST for anything you
CREATE OR REPLACE that it used. Delete any test findings you create.
