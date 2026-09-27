# CoCo S7 — Google Drive → Snowflake Document Ingestion

**Session**: S7 · ARGUS (team TCC)
**Date**: 2026-09-27
**Objective**: Make Google Drive the source for the document pipeline, using the
`google-workspace` MCP server to read from the `ARGUS Policy Corpus` Drive folder.

---

## Drive Folder Contents

| # | File Name | Drive ID | Type | MD5 | Action |
|---|-----------|----------|------|-----|--------|
| 1 | CBB_FC_MODULE_2024.pdf | `1ikHeKOEDW33B2pKxuRkio-iWKzxmlZtg` | circular | `a6440822a8783d9dc2a4d8af5260dfbb` | UNCHANGED |
| 2 | CBUAE_AML_2024.pdf | `1wOgtcd_OiEOYzJ4O54hceI8f_VvfDyKM` | circular | `dda91f9fc07a047ce8ea0250d28af9bc` | UNCHANGED |
| 3 | FATF_R16_WIRE.pdf | `1asAgwHwex7u7V-46HW3A04KhTh7YQZUr` | circular | `fb6f0466d560b7915f11fcd977ff4f13` | UNCHANGED |
| 4 | SAMA_AMLCTF_2023.pdf | `1Ematx7AubEK8IXfFHL7LQ1KZIOFz6k3p` | circular | `d47d07b9ce677248002fe4d2bb309472` | UNCHANGED |
| 5 | STR-2026-0412_BANK_A.pdf | `1jH6uyp54nqKOIDhBclQbE3NX5n0DHq_B` | filing | `bbe7f92a843a0a2b8087aedeb7a505bb` | UNCHANGED |
| 6 | STR-2026-0588_BANK_B.pdf | `1NLOg_l0XcyClGSGYIesm2zOQFdiapPEq` | filing | `597c18cabaad01500cd2a6bae92d2c29` | UNCHANGED |
| 7 | STR-2025-1190_BANK_C.pdf | `1rpIyg9wMDnhhP0lAdSIfyjml0m2FnXgn` | filing | `3b1a0f4215e6135c70ae3d58c8c7279a` | UNCHANGED |

**Summary**: 7 files found, 7 unchanged (MD5 match between Drive download and `@DOCS_STAGE`), 0 ingested, 0 updated. No re-upload or re-parse was needed.

---

## Verification Results

### 1. DOC_INGEST_LOG — 7 rows, all UNCHANGED
```
FILE_NAME                     | DOC_TYPE | ACTION    | MD5
CBB_FC_MODULE_2024.pdf        | circular | UNCHANGED | a6440822...
CBUAE_AML_2024.pdf            | circular | UNCHANGED | dda91f9f...
FATF_R16_WIRE.pdf             | circular | UNCHANGED | fb6f0466...
SAMA_AMLCTF_2023.pdf          | circular | UNCHANGED | d47d07b9...
STR-2025-1190_BANK_C.pdf      | filing   | UNCHANGED | 3b1a0f42...
STR-2026-0412_BANK_A.pdf      | filing   | UNCHANGED | bbe7f92a...
STR-2026-0588_BANK_B.pdf      | filing   | UNCHANGED | 597c18ca...
```

### 2. DOCUMENTS — all 7 rows have drive_file_id and source_uri
```
RELATIVE_PATH                          | DRIVE_FILE_ID                          | SOURCE_URI
circulars/CBB_FC_MODULE_2024.pdf       | 1ikHeKOEDW33B2pKxuRkio-iWKzxmlZtg    | gdrive://ARGUS Policy Corpus/CBB_FC_MODULE_2024.pdf
circulars/CBUAE_AML_2024.pdf           | 1wOgtcd_OiEOYzJ4O54hceI8f_VvfDyKM    | gdrive://ARGUS Policy Corpus/CBUAE_AML_2024.pdf
circulars/FATF_R16_WIRE.pdf            | 1asAgwHwex7u7V-46HW3A04KhTh7YQZUr    | gdrive://ARGUS Policy Corpus/FATF_R16_WIRE.pdf
circulars/SAMA_AMLCTF_2023.pdf         | 1Ematx7AubEK8IXfFHL7LQ1KZIOFz6k3p    | gdrive://ARGUS Policy Corpus/SAMA_AMLCTF_2023.pdf
filings/STR-2025-1190_BANK_C.pdf       | 1rpIyg9wMDnhhP0lAdSIfyjml0m2FnXgn    | gdrive://ARGUS Policy Corpus/STR-2025-1190_BANK_C.pdf
filings/STR-2026-0412_BANK_A.pdf       | 1jH6uyp54nqKOIDhBclQbE3NX5n0DHq_B    | gdrive://ARGUS Policy Corpus/STR-2026-0412_BANK_A.pdf
filings/STR-2026-0588_BANK_B.pdf       | 1NLOg_l0XcyClGSGYIesm2zOQFdiapPEq    | gdrive://ARGUS Policy Corpus/STR-2026-0588_BANK_B.pdf
```

### 3. Cortex Search — "mule accounts fed from multiple institutions" (regulator = SAMA)
Top result: **SAMA Art. 8 — Money Mule and Pass-Through Accounts** from `circulars/SAMA_AMLCTF_2023.pdf`

> "Banks shall implement monitoring that identifies accounts used as money mules, including accounts that receive funds from multiple unrelated parties or from multiple financial institutions and rapidly consolidate or forward those funds. Because such networks deliberately span several institutions, monitoring limited to a single bank's own customers is not sufficient to meet this Article."

Cortex Search continues to function correctly after the Drive-sourced ingestion.

---

## Snowflake Objects Created / Modified

| Object | Action |
|--------|--------|
| `ARGUS.GOVERNED.DOC_INGEST_LOG` | **Created** — tracks each Drive sync run |
| `ARGUS.GOVERNED.DOCUMENTS.drive_file_id` | **Added** — nullable STRING column |
| `ARGUS.GOVERNED.DOCUMENTS.source_uri` | **Added** — nullable STRING column |
| `sql/09_drive_ingestion.sql` | **Created** — reusable DDL, lineage update, and re-parse templates |

---

## How a New Circular Flows In

When a new regulatory circular (e.g. `DFSA_AML_2026.pdf`) is added to the
**ARGUS Policy Corpus** Google Drive folder, the ingestion pipeline works as follows:

1. **Discovery** — The `google-workspace` MCP `list_drive_items` call enumerates
   the folder. The new file appears with a Drive file ID and modification timestamp.

2. **Download** — `get_drive_file_download_url` saves the PDF to a local temp path.

3. **Change Detection** — Compute the local file's MD5 hash. Compare it against
   `LIST @ARGUS.GOVERNED.DOCS_STAGE` output. Since the file is new, no match is found.

4. **Stage Upload** — Upload via CLI:
   ```
   snow stage copy "<local_path>" @ARGUS.GOVERNED.DOCS_STAGE/circulars/ -c argus --overwrite
   ALTER STAGE DOCS_STAGE REFRESH;
   ```

5. **Parse** — Insert into `DOCUMENTS` using `AI_PARSE_DOCUMENT` with LAYOUT mode:
   ```sql
   INSERT INTO DOCUMENTS (relative_path, doc_type, content, parsed_at)
   SELECT 'circulars/DFSA_AML_2026.pdf', 'circular',
          AI_PARSE_DOCUMENT(TO_FILE('@DOCS_STAGE', 'circulars/DFSA_AML_2026.pdf'),
                            {'mode': 'LAYOUT'}):content::STRING,
          CURRENT_TIMESTAMP();
   ```

6. **Chunk** — Split the parsed content into 800-character chunks with 100-character
   overlap using `SPLIT_TEXT_RECURSIVE_CHARACTER`, insert into `DOCUMENT_CHUNKS`.

7. **Cortex Search** — The `POLICY_SEARCH` service (target lag = 1 day) automatically
   picks up the new chunks on its next refresh. No manual rebuild needed.

8. **Lineage** — Stamp `drive_file_id` and `source_uri` on the `DOCUMENTS` row so
   every chunk and search result traces back to its Drive original.

9. **Log** — Insert a row into `DOC_INGEST_LOG` with action = `INGESTED`, the MD5,
   and the Drive metadata.

10. **Cleanup** — Delete the local temp copy of the PDF.

The full re-parse template SQL is in `sql/09_drive_ingestion.sql` (section 4).
