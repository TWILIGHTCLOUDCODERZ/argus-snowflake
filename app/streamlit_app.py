"""
ARGUS Investigator — Streamlit in Snowflake
Compliance analyst workbench: signal → evidence → finding → filing + Ask ARGUS.
Owned by ARGUS_ANALYST; PII masked via tag-based masking policies.
"""
import streamlit as st
import pandas as pd
import json

st.set_page_config(page_title="ARGUS Investigator", page_icon="🛡️", layout="wide")

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
conn = st.connection("snowflake")

def run_query(sql):
    return conn.query(sql, ttl=0)

def run_query_cached(sql, ttl=60):
    return conn.query(sql, ttl=ttl)

def run_proc(sql):
    return conn.query(sql, ttl=0)

# ---------------------------------------------------------------------------
# Sidebar navigation
# ---------------------------------------------------------------------------
page = st.sidebar.radio(
    "Navigation",
    ["Overview", "Typologies", "Finding", "Filing Review", "Ask ARGUS"],
    index=0,
)

st.sidebar.markdown("---")
st.sidebar.caption("ARGUS · TCC · CoCo Hack GCC Edition")


# =========================================================================
# PAGE 1: OVERVIEW
# =========================================================================
if page == "Overview":
    st.title("ARGUS — Investigator Dashboard")

    # -- KPIs --
    col1, col2, col3 = st.columns(3)

    typo_df = run_query_cached(
        "SELECT typology_class, COUNT(*) AS cnt "
        "FROM ARGUS.GOVERNED.TYPOLOGY WHERE status='DISCOVERED' "
        "GROUP BY typology_class ORDER BY cnt DESC"
    )
    with col1:
        st.metric("Discovered Typologies", int(typo_df["CNT"].sum()) if len(typo_df) > 0 else 0)
        if len(typo_df) > 0:
            for _, r in typo_df.iterrows():
                st.caption(f"{r['TYPOLOGY_CLASS']}: {int(r['CNT'])}")

    alerts_df = run_query_cached(
        "SELECT COUNT(*) AS cnt FROM ARGUS.GOVERNED.LIVE_ALERTS WHERE status='OPEN'"
    )
    with col2:
        alert_count = int(alerts_df.iloc[0]["CNT"]) if len(alerts_df) > 0 else 0
        st.metric("Open Live Alerts", alert_count)

    gaps_df = run_query_cached(
        "SELECT regulator, COUNT_IF(is_gap) AS gaps "
        "FROM ARGUS.GOVERNED.CONTROL_GAP GROUP BY regulator ORDER BY regulator"
    )
    with col3:
        total_gaps = int(gaps_df["GAPS"].sum()) if len(gaps_df) > 0 else 0
        st.metric("Open Control Gaps", total_gaps)
        if len(gaps_df) > 0:
            for _, r in gaps_df.iterrows():
                st.caption(f"{r['REGULATOR']}: {int(r['GAPS'])}")

    st.markdown("---")

    # -- Live Feed Panel --
    st.subheader("Live Feed Control")

    batch_df = run_query(
        "SELECT COUNT_IF(delivered_at IS NOT NULL) AS delivered, "
        "COUNT(*) AS total, COUNT(DISTINCT batch_no) AS batches "
        "FROM ARGUS.RAW.TXN_LIVE_QUEUE"
    )
    delivered = int(batch_df.iloc[0]["DELIVERED"]) if len(batch_df) > 0 else 0
    total = int(batch_df.iloc[0]["TOTAL"]) if len(batch_df) > 0 else 0

    live_txn_df = run_query(
        "SELECT COUNT_IF(txn_id LIKE 'LV%') AS live_rows FROM ARGUS.RAW.TRANSACTIONS"
    )
    live_rows = int(live_txn_df.iloc[0]["LIVE_ROWS"]) if len(live_txn_df) > 0 else 0

    bcol1, bcol2, bcol3 = st.columns(3)
    bcol1.metric("Queue Delivered", f"{delivered}/{total}")
    bcol2.metric("Live Rows in Transactions", live_rows)
    bcol3.metric("Open Alerts", alert_count)

    btn_col1, btn_col2 = st.columns(2)
    with btn_col1:
        if st.button("Deliver Next Batch", type="primary"):
            result = run_proc("CALL ARGUS.GOVERNED.SP_DEMO_NEXT_BATCH()")
            st.success(result.iloc[0][0])
            st.rerun()
    with btn_col2:
        if st.button("Reset Demo", type="secondary"):
            with st.spinner("Resetting demo (includes rediscovery)..."):
                result = run_proc("CALL ARGUS.GOVERNED.SP_DEMO_RESET()")
            st.success(result.iloc[0][0])
            st.rerun()

    # -- Live Alerts Table --
    if alert_count > 0:
        st.subheader("Live Alerts")
        alerts_detail = run_query(
            "SELECT alert_id, alert_type, account_id, bank_id, "
            "source_banks, inbound_amount, raised_at "
            "FROM ARGUS.GOVERNED.LIVE_ALERTS WHERE status='OPEN' "
            "ORDER BY raised_at DESC"
        )
        st.dataframe(alerts_detail, use_container_width=True)


# =========================================================================
# PAGE 2: TYPOLOGIES
# =========================================================================
elif page == "Typologies":
    st.title("Discovered Typologies")

    typo_list = run_query_cached(
        "SELECT typology_id, typology_class, name, "
        "ARRAY_TO_STRING(banks_involved, ', ') AS banks, "
        "member_count, total_value, first_seen, last_seen, confidence "
        "FROM ARGUS.GOVERNED.TYPOLOGY WHERE status='DISCOVERED' "
        "ORDER BY typology_id"
    )
    if len(typo_list) == 0:
        st.info("No discovered typologies yet. Deliver batches and run rediscovery.")
    else:
        st.dataframe(
            typo_list[["TYPOLOGY_ID", "TYPOLOGY_CLASS", "BANKS",
                        "MEMBER_COUNT", "TOTAL_VALUE", "CONFIDENCE"]],
            use_container_width=True, hide_index=True,
        )

        selected_typ = st.selectbox(
            "Select a typology for details",
            typo_list["TYPOLOGY_ID"].tolist()
        )

        if selected_typ:
            typ_row = typo_list[typo_list["TYPOLOGY_ID"] == selected_typ].iloc[0]

            # Card
            card_df = run_query_cached(
                f"SELECT card_md FROM ARGUS.GOVERNED.TYPOLOGY "
                f"WHERE typology_id = '{selected_typ}'"
            )
            if len(card_df) > 0 and card_df.iloc[0]["CARD_MD"]:
                st.markdown(card_df.iloc[0]["CARD_MD"])

            # Members
            members_df = run_query_cached(
                f"SELECT entity_id AS account_id, role, bank_id "
                f"FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                f"WHERE typology_id = '{selected_typ}' AND entity_type = 'account' "
                f"ORDER BY role, entity_id"
            )

            mcol1, mcol2 = st.columns([1, 1])
            with mcol1:
                st.subheader("Members")
                st.dataframe(members_df, use_container_width=True, hide_index=True)

            # Ring diagram with graphviz
            with mcol2:
                st.subheader("Ring Diagram")
                bank_colors = {
                    "BANK_A": "#4285F4", "BANK_B": "#EA4335", "BANK_C": "#34A853"
                }
                dot_lines = ["digraph ring {", "  rankdir=LR;",
                             "  node [style=filled, fontsize=10];"]
                for _, m in members_df.iterrows():
                    color = bank_colors.get(m["BANK_ID"], "#999999")
                    shape = "box" if m["ROLE"] == "consolidation" else \
                            "diamond" if m["ROLE"] == "funnel" else \
                            "ellipse"
                    label = f"{m['ACCOUNT_ID']}\\n{m['ROLE']}"
                    dot_lines.append(
                        f'  "{m["ACCOUNT_ID"]}" '
                        f'[label="{label}", fillcolor="{color}", '
                        f'fontcolor="white", shape={shape}];'
                    )

                # Add edges from transfer data
                edges_df = run_query_cached(
                    f"SELECT DISTINCT e.from_account, e.to_account "
                    f"FROM ARGUS.CURATED.DT_CROSS_BANK_EDGES e "
                    f"WHERE e.from_account IN "
                    f"(SELECT entity_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                    f" WHERE typology_id = '{selected_typ}') "
                    f"AND e.to_account IN "
                    f"(SELECT entity_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                    f" WHERE typology_id = '{selected_typ}')"
                )
                # Also same-bank edges
                sb_edges_df = run_query_cached(
                    f"SELECT DISTINCT t.account_id AS from_account, "
                    f"a.account_id AS to_account "
                    f"FROM ARGUS.RAW.TRANSACTIONS t "
                    f"JOIN ARGUS.RAW.ACCOUNTS a ON a.iban = t.counterparty_iban "
                    f"WHERE t.direction = 'debit' AND t.amount >= 10000 "
                    f"AND t.account_id IN "
                    f"(SELECT entity_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                    f" WHERE typology_id = '{selected_typ}') "
                    f"AND a.account_id IN "
                    f"(SELECT entity_id FROM ARGUS.GOVERNED.TYPOLOGY_EVIDENCE "
                    f" WHERE typology_id = '{selected_typ}') "
                    f"AND t.bank_id = t.counterparty_bank"
                )
                all_edges = pd.concat([edges_df, sb_edges_df], ignore_index=True) \
                    if len(sb_edges_df) > 0 else edges_df
                for _, e in all_edges.iterrows():
                    dot_lines.append(
                        f'  "{e["FROM_ACCOUNT"]}" -> "{e["TO_ACCOUNT"]}";'
                    )
                dot_lines.append("}")
                st.graphviz_chart("\n".join(dot_lines))

            # Detection SQL
            with st.expander("Detection SQL"):
                det_df = run_query_cached(
                    f"SELECT detection_sql FROM ARGUS.GOVERNED.TYPOLOGY "
                    f"WHERE typology_id = '{selected_typ}'"
                )
                if len(det_df) > 0:
                    st.code(det_df.iloc[0]["DETECTION_SQL"], language="sql")

            # Rediscover button
            if st.button("Run Rediscovery"):
                with st.spinner("Running typology discovery..."):
                    result = run_proc("CALL ARGUS.GOVERNED.SP_DEMO_REDISCOVER()")
                st.success(result.iloc[0][0])
                st.rerun()


# =========================================================================
# PAGE 3: FINDING
# =========================================================================
elif page == "Finding":
    st.title("Findings & Evidence")

    findings_df = run_query(
        "SELECT finding_id, typology_id, typology_class, title, "
        "total_value, confidence, status, verifier_reason "
        "FROM ARGUS.GOVERNED.FINDING ORDER BY created_at DESC"
    )

    if len(findings_df) == 0:
        st.info("No findings yet. Build a finding from the Typologies page or Ask ARGUS.")
    else:
        selected_fnd = st.selectbox(
            "Select a finding",
            findings_df["FINDING_ID"].tolist(),
            format_func=lambda x: f"{x} — {findings_df[findings_df['FINDING_ID']==x].iloc[0]['TITLE']}"
        )

        if selected_fnd:
            fnd_row = findings_df[findings_df["FINDING_ID"] == selected_fnd].iloc[0]

            # Status banner
            status = fnd_row["STATUS"]
            if status == "VERIFIED":
                st.success(f"**{status}** — {fnd_row['VERIFIER_REASON']}")
            elif status == "REJECTED":
                st.error(f"**{status}** — {fnd_row['VERIFIER_REASON']}")
            else:
                st.warning(f"**{status}** — {fnd_row['VERIFIER_REASON'] or 'Pending verification'}")

            st.markdown(
                f"**Typology:** {fnd_row['TYPOLOGY_ID']} · "
                f"**Class:** {fnd_row['TYPOLOGY_CLASS']} · "
                f"**Value:** AED {fnd_row['TOTAL_VALUE']:,.2f} · "
                f"**Confidence:** {fnd_row['CONFIDENCE']}"
            )

            # Claims table
            st.subheader("Claims")
            claims_df = run_query(
                f"SELECT claim_id, claim_type, claim_text, confidence, "
                f"verified, verification_note "
                f"FROM ARGUS.GOVERNED.FINDING_CLAIM "
                f"WHERE finding_id = '{selected_fnd}' ORDER BY claim_seq"
            )

            if len(claims_df) > 0:
                st.dataframe(
                    claims_df[["CLAIM_ID", "CLAIM_TYPE", "CLAIM_TEXT",
                               "CONFIDENCE", "VERIFIED", "VERIFICATION_NOTE"]],
                    use_container_width=True, hide_index=True,
                )

                # Drill into a claim
                selected_claim = st.selectbox(
                    "Select a claim for cited evidence",
                    claims_df["CLAIM_ID"].tolist()
                )
                if selected_claim:
                    claim_row_df = run_query(
                        f"SELECT structured_refs, clause_refs "
                        f"FROM ARGUS.GOVERNED.FINDING_CLAIM "
                        f"WHERE claim_id = '{selected_claim}'"
                    )
                    if len(claim_row_df) > 0:
                        cr = claim_row_df.iloc[0]
                        txn_refs = json.loads(cr["STRUCTURED_REFS"]) \
                            if isinstance(cr["STRUCTURED_REFS"], str) else cr["STRUCTURED_REFS"]
                        clause_refs = json.loads(cr["CLAUSE_REFS"]) \
                            if isinstance(cr["CLAUSE_REFS"], str) else cr["CLAUSE_REFS"]

                        tcol1, tcol2 = st.columns(2)
                        with tcol1:
                            st.markdown("**Cited Transactions** (PII masked)")
                            if txn_refs and len(txn_refs) > 0:
                                ref_list = ", ".join(f"'{r}'" for r in txn_refs)
                                txn_df = run_query(
                                    f"SELECT txn_id, bank_id, account_id, direction, "
                                    f"amount, currency, ts "
                                    f"FROM ARGUS.RAW.TRANSACTIONS "
                                    f"WHERE txn_id IN ({ref_list})"
                                )
                                st.dataframe(txn_df, use_container_width=True,
                                             hide_index=True)
                            else:
                                st.caption("No transaction refs")
                        with tcol2:
                            st.markdown("**Cited Clauses**")
                            if clause_refs and len(clause_refs) > 0:
                                cl_list = ", ".join(f"'{c}'" for c in clause_refs)
                                clause_df = run_query(
                                    f"SELECT cl.clause_id, cl.article_ref, "
                                    f"r.regulator, cl.clause_text "
                                    f"FROM ARGUS.GOVERNED.CLAUSE cl "
                                    f"JOIN ARGUS.GOVERNED.REGULATION r "
                                    f"ON r.regulation_id = cl.regulation_id "
                                    f"WHERE cl.clause_id IN ({cl_list})"
                                )
                                st.dataframe(clause_df,
                                             use_container_width=True,
                                             hide_index=True)
                            else:
                                st.caption("No clause refs")
            else:
                st.info("No claims for this finding.")


# =========================================================================
# PAGE 4: FILING REVIEW
# =========================================================================
elif page == "Filing Review":
    st.title("Filing Review")

    filings_df = run_query(
        "SELECT f.filing_id, f.finding_id, f.filing_type, f.bank_id, "
        "f.regulator, f.status, f.approved_by, "
        "f.grounding_check:grounding_passed::BOOLEAN AS grounding_passed, "
        "LENGTH(f.narrative_md) AS narr_len "
        "FROM ARGUS.GOVERNED.FILING f ORDER BY f.finding_id, f.filing_type"
    )

    if len(filings_df) == 0:
        st.info("No filing drafts yet. Build and verify a finding first.")
    else:
        # Group by finding
        finding_ids = filings_df["FINDING_ID"].unique().tolist()
        selected_finding = st.selectbox("Select Finding", finding_ids)

        finding_filings = filings_df[filings_df["FINDING_ID"] == selected_finding]

        st.dataframe(
            finding_filings[["FILING_ID", "FILING_TYPE", "BANK_ID",
                             "REGULATOR", "STATUS", "GROUNDING_PASSED"]],
            use_container_width=True, hide_index=True,
        )

        # Select a filing to read
        selected_filing = st.selectbox(
            "Select a filing to review",
            finding_filings["FILING_ID"].tolist()
        )

        if selected_filing:
            filing_detail = run_query(
                f"SELECT narrative_md, grounding_check, status, approved_by "
                f"FROM ARGUS.GOVERNED.FILING "
                f"WHERE filing_id = '{selected_filing}'"
            )
            if len(filing_detail) > 0:
                fd = filing_detail.iloc[0]

                # Status
                if fd["STATUS"] == "APPROVED":
                    st.success(f"Approved by {fd['APPROVED_BY']}")
                else:
                    st.warning(f"Status: {fd['STATUS']}")

                # Grounding check
                gc = fd["GROUNDING_CHECK"]
                if gc:
                    gc_data = json.loads(gc) if isinstance(gc, str) else gc
                    passed = gc_data.get("grounding_passed", False)
                    if passed:
                        st.success("Grounding check: PASSED")
                    else:
                        st.error(f"Grounding check: FAILED — {gc_data.get('reason', '')}")
                    with st.expander("Grounding Details"):
                        st.json(gc_data)

                # Narrative
                st.subheader("Draft Narrative")
                st.markdown(fd["NARRATIVE_MD"])

                # Approve button
                # Only drafts awaiting review can be approved; approval goes through
                # SP_APPROVE_FILING (the analyst role has no UPDATE on FILING).
                if fd["STATUS"] == "DRAFT_PENDING_HUMAN":
                    if st.button(f"Approve Draft: {selected_filing}", type="primary"):
                        viewer = (getattr(getattr(st, "user", None), "user_name", None)
                                  or getattr(getattr(st, "experimental_user", None), "user_name", None)
                                  or "unknown")
                        msg = conn.session().call("ARGUS.GOVERNED.SP_APPROVE_FILING",
                                                  selected_filing, str(viewer))
                        if str(msg).startswith("APPROVED"):
                            st.success(f"{msg} — delivery comes in Week 4 as a Gmail draft.")
                            st.rerun()
                        else:
                            st.error(str(msg))
                elif fd["STATUS"] != "APPROVED":
                    st.info("This draft cannot be approved — it did not pass the grounding check.")


# =========================================================================
# PAGE 5: ASK ARGUS
# =========================================================================
elif page == "Ask ARGUS":
    st.title("Ask ARGUS")
    st.caption("Chat with the multi-agent orchestrator. "
               "Evidence, policy, and filing questions are routed to specialists.")

    # Session state for chat history
    if "messages" not in st.session_state:
        st.session_state.messages = []

    # Display chat history
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if "run_id" in msg:
                with st.expander("Handoff Trace"):
                    st.dataframe(msg["trace_df"], use_container_width=True,
                                 hide_index=True)

    # Chat input
    if prompt := st.chat_input("Ask ARGUS a question..."):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            with st.spinner("ARGUS is thinking..."):
                try:
                    from orchestrator import orchestrate
                    result = orchestrate(prompt)
                    answer = result.answer
                    run_id = result.run_id

                    # Fetch handoff trace
                    trace_df = run_query(
                        f"SELECT step, from_agent, to_agent, "
                        f"input_summary, output_summary, duration_ms "
                        f"FROM ARGUS.GOVERNED.AGENT_RUN_LOG "
                        f"WHERE run_id = '{run_id}' ORDER BY step"
                    )

                    st.markdown(answer)

                    if len(result.citations) > 0:
                        st.caption("Citations: " + ", ".join(result.citations))

                    if len(trace_df) > 0:
                        with st.expander("Handoff Trace"):
                            st.dataframe(trace_df, use_container_width=True,
                                         hide_index=True)

                    st.session_state.messages.append({
                        "role": "assistant",
                        "content": answer,
                        "run_id": run_id,
                        "trace_df": trace_df,
                    })
                except Exception as e:
                    error_msg = f"Error: {str(e)}"
                    st.error(error_msg)
                    st.session_state.messages.append({
                        "role": "assistant",
                        "content": error_msg,
                    })
