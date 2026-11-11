# FilingIQ — Runbook

Exact run order, expected output at each step, and fixes for the most
likely errors.

This reflects the trial-account-compatible version of the project: SQL
steps 1-6 run in a Snowsight SQL worksheet; steps 7-8 (the app and the
eval notebook) run **locally** on your machine, not inside Snowflake —
see README.md's "Trial-account note" for why.

## 0. Prerequisites

- Any Snowflake trial account (this version doesn't need a specific
  Cortex-supported region, since it doesn't use Cortex).
- A role with privileges to create databases/warehouses (e.g.
  `ACCOUNTADMIN` on a fresh trial, or ask your account admin for
  `CREATE DATABASE`/`CREATE WAREHOUSE` on your role).
- 10-K PDFs renamed to `TICKER_YEAR_10K.pdf` (e.g. `NVDA_2024_10K.pdf`),
  downloaded from each company's investor-relations site.
- Python 3.10+ and `pip` installed locally.
- A free Groq API key: [console.groq.com/keys](https://console.groq.com/keys)
  (no payment method required).

## 1. `sql/01_setup.sql`

**Run:** entire file, top to bottom.

**Expect:**
- `SHOW TABLES` at the bottom lists `PENDING_FILES`, `PARSED_DOCS`,
  `DOC_CHUNKS`, `INGESTION_LOG`.
- `SHOW STAGES` lists `RAW_DOCS` with `has_directory = Y`.
- `SHOW WAREHOUSES` lists `FILINGIQ_WH`, state `SUSPENDED` (expected —
  it auto-resumes on first query).

**Likely errors:**
- `Insufficient privileges to operate on account` — your role can't
  create databases/warehouses. Switch to `ACCOUNTADMIN` (top-right role
  switcher in Snowsight) or ask an admin to grant `CREATE DATABASE`/
  `CREATE WAREHOUSE` on your default role.
- `Object 'FILINGIQ_WH' already exists` on `CREATE WAREHOUSE IF NOT
  EXISTS` — harmless; the script is idempotent and will reuse it.

## 2. Upload PDFs

**Do:** Snowsight > Data > Databases > `FILINGIQ_DB` > `PUBLIC` > Stages >
`RAW_DOCS` > "+ Files" > select your `TICKER_YEAR_10K.pdf` files.

**Then run:**
```sql
ALTER STAGE FILINGIQ_DB.PUBLIC.RAW_DOCS REFRESH;
SELECT * FROM DIRECTORY(@FILINGIQ_DB.PUBLIC.RAW_DOCS);
```

**Expect:** one row per uploaded PDF.

**Likely errors:**
- Directory query returns 0 rows right after upload — you forgot the
  `ALTER STAGE ... REFRESH`; Snowsight uploads don't auto-refresh
  directory table metadata.
- Filename doesn't match `TICKER_YEAR_10K.pdf` — `PROCESS_NEW_DOCS()`
  will still parse the file but `company`/`fiscal_year` will be wrong
  (`SPLIT_PART` just splits on `_` positionally); rename and re-upload.

## 3. `sql/02_stream.sql`

**Run:** entire file.

**Expect:**
- `SYSTEM$STREAM_HAS_DATA('DOCS_STREAM')` returns `TRUE` if you uploaded
  + refreshed files in step 2, else `FALSE`.
- The `METADATA$ACTION = 'INSERT'` query lists your uploaded files.

**Likely errors:**
- `Stream on stage is not supported` / similar DDL error — your account
  edition doesn't support streams on stages. Fallback: poll
  `DIRECTORY(@RAW_DOCS)` for new files on a schedule instead of a
  stream, tracking "already processed" paths against `INGESTION_LOG`
  yourself.
- Stream query returns 0 rows even after refreshing — make sure you ran
  `ALTER STAGE RAW_DOCS REFRESH` *after* the upload (refresh is a
  stage-level operation, not session-scoped, so any session running it
  is fine).

## 4. `sql/03_process_procedure.sql`

**Run:** entire file (creates the `PDF_TO_TEXT` and `CHUNK_TEXT` UDFs and
defines the `PROCESS_NEW_DOCS()` procedure; doesn't execute it yet).

**Then run manually:**
```sql
CALL PROCESS_NEW_DOCS();
```

**Expect:** a return string like:
```
Processed 4 file(s): 4 OK, 0 WARN, 0 FAILED. Total chunks written: 1058.
```

**Likely errors:**
- `Package 'pypdf' is not supported` on `CREATE FUNCTION PDF_TO_TEXT` —
  run `SELECT * FROM INFORMATION_SCHEMA.PACKAGES WHERE PACKAGE_NAME ILIKE
  '%pdf%';` to see what's actually available in the Anaconda channel for
  your account, and swap the `PACKAGES` clause (e.g. to `'PyPDF2'`).
- `COMMENT` / `EXECUTE AS` ordering error on `CREATE PROCEDURE` — this
  file already orders `COMMENT` before `EXECUTE AS CALLER`, which is the
  order that worked when this was tested; if your release wants the
  opposite order, swap them.
- `invalid identifier` or cursor-related error on the `FOR file_record IN
  files_cursor DO` line — this file already uses an explicitly `DECLARE`d
  cursor (not an inline `SELECT` in the `FOR` clause), which is the form
  that worked when this was tested.
- All files come back `FAILED` with the same error message — query
  `SELECT error_message FROM INGESTION_LOG ORDER BY processed_at DESC
  LIMIT 5;` to see the actual error from `PDF_TO_TEXT`/`CHUNK_TEXT`.
- A specific file is `FAILED` with "Parsed text is empty." — likely a
  scanned/image-only PDF with no extractable text layer; `pypdf` (unlike
  Cortex's LAYOUT mode) does not OCR images. Try re-exporting that filing
  as a text-based PDF from the investor-relations site.
- Procedure call is slow on first run — large PDFs (100+ pages) take real
  time to parse in a Python UDF; this is expected, not a bug. Check
  `QUERY_HISTORY` in Snowsight to see it's still executing, not stuck.

## 5. `sql/04_task.sql`

**Run:** entire file (creates + resumes `INGEST_TASK`, runs it once via
`EXECUTE TASK`, then the validation queries at the bottom).

**Expect:**
- `SHOW TASKS` shows `INGEST_TASK`, state `started`.
- `TASK_HISTORY` shows a `SUCCEEDED` run.
- The "incremental-load validation" queries: after your first batch of
  files, `INGESTION_LOG` grouped by `file_name` with `COUNT(*) > 1`
  returns 0 rows (no duplicates).

**Then, to prove incrementality:** upload a few more PDFs (step 2),
refresh, run `EXECUTE TASK INGEST_TASK;` again, and re-run the validation
queries. `INGESTION_LOG`'s total row count should have grown by exactly
the number of new files, and the "duplicates" query should still return 0
rows.

**Likely errors:**
- `EXECUTE TASK` succeeds but `INGESTION_LOG` doesn't grow — the stream
  had no data (you forgot `ALTER STAGE REFRESH` after uploading, or the
  task's `WHEN` clause genuinely found nothing new — check
  `TASK_HISTORY`'s `STATE` column for `SKIPPED`).
- `CREATE TASK` fails on the `COMMENT`/`WHEN` ordering or the inline
  `BEGIN...END` body — this file already puts `COMMENT` before `WHEN`,
  which is the order that worked when this was tested. If multi-statement
  task bodies aren't supported on your release, move
  `ALTER STAGE RAW_DOCS REFRESH;` to the first line inside
  `PROCESS_NEW_DOCS()` and change the task body to just
  `CALL PROCESS_NEW_DOCS();`.

## 6. `sql/05_search_service.sql`

**Run:** entire file.

**Expect:**
- `SHOW FUNCTIONS LIKE 'SEARCH_CHUNKS'` lists it.
- The three smoke-test queries each return rows with `chunk`/`company`/
  `fiscal_year`/`relative_path`/`score`, highest score first.

**Likely errors:**
- Empty results on every query — `DOC_CHUNKS` has no rows yet; run step 4
  first.
- `Numeric value '...' is not recognized` or similar on the `%s::NUMBER`
  casts when calling from Python later (step 7/8) — make sure you're
  passing an actual Python `int`/`None` for the year filter, not a
  string like `"All"`.

## 7. Run the Streamlit app (locally)

**Do:**
```bash
cd app
python3.12 -m venv .venv && source .venv/bin/activate   # python3.12 recommended; very new Python versions may lack prebuilt wheels for some deps
pip install -r requirements.txt
cp .env.example .env     # fill in SNOWFLAKE_* and GROQ_API_KEY
streamlit run streamlit_app.py
```

**Expect:** a browser tab opens; sidebar populates with company/year
dropdowns from `DOC_CHUNKS`; asking a question returns a grounded answer
with an expander listing cited source filenames and TF-IDF scores;
"Pipeline status" tab shows your `INGESTION_LOG` counts and a chunks-per-
company chart.

**Likely errors:**
- `KeyError: 'SNOWFLAKE_ACCOUNT'` — `.env` wasn't created/filled in, or
  isn't being loaded (make sure you're running `streamlit run` from
  inside the `app/` directory so `.env` is found).
- Sidebar dropdowns are empty — `DOC_CHUNKS` has no rows yet; run step 4
  first.
- Login hangs waiting on a browser window — you left `SNOWFLAKE_PASSWORD`
  blank (which triggers `authenticator=externalbrowser`); complete the
  browser login, or set a password/PAT in `.env` instead.
- "GROQ_API_KEY is not set." in the chat answer — `.env` is missing the
  key or wasn't filled in.
- "Groq free-tier rate limit reached." — wait a minute; you're sending
  requests faster than the free tier allows.
- Chat returns "Not found in the filings." for everything — check the
  sidebar filters aren't accidentally narrowed to a company/year with no
  data, and that your question shares actual keywords with the filing
  text (TF-IDF search, unlike semantic search, needs real word overlap).

## 8. Run the evaluation notebook (locally)

**Do:**
1. Fill in `expected_answer` in `eval/questions.csv` (see
   `eval/QUESTION_GUIDE.md`).
2. ```bash
   cd eval
   python3.12 -m venv .venv && source .venv/bin/activate   # python3.12 recommended; very new Python versions may lack prebuilt wheels for some deps
   pip install -r requirements.txt
   pip install "snowflake-sqlalchemy==2.1.0"   # see requirements.txt "KNOWN ISSUE" comment — fixes a real import error
   cp .env.example .env   # fill in SNOWFLAKE_* and GROQ_API_KEY
   jupyter notebook eval_notebook.ipynb
   ```
3. Run all cells top to bottom.

**Expect:** `eval/results/raw_results.csv`, `comparison_summary.csv`, and
`comparison_chart.png` get written to disk; the final cell prints the
recommended chunking configuration. Expect this to take several minutes
(30 questions x 3 configs, with pacing delays to respect Groq's free-tier
rate limit).

**Likely errors:**
- `ModuleNotFoundError: trulens...` — package names changed since this
  was written; check `pypi.org/project/trulens-connectors-snowflake` for
  the current import path (see the `-- VERIFY` note in the notebook's
  setup cells) and adjust the import line.
- `FileNotFoundError: questions.csv` — run Jupyter from inside the
  `eval/` directory so the relative path resolves.
- TruLens / LiteLLM errors mentioning Groq auth — confirm `GROQ_API_KEY`
  is set in the environment (`.env` is loaded via `python-dotenv` at the
  top of the notebook); LiteLLM's `groq/<model>` provider reads this
  variable directly.
- Repeated 429s from Groq even with the built-in retry — the free tier's
  rate limit is tighter than this notebook assumes; increase the
  `time.sleep(1)` pacing delay in section 4, or split the run across
  configs into separate notebook sessions.

## 9. Teardown (optional)

**Run:** `sql/99_teardown.sql` to drop every Snowflake object and stop
all associated billing. This does **not** delete the local `app/` or
`eval/` folders (they're not Snowflake objects) — remove those yourself
if you want them gone too. This is irreversible — re-read the warning
comment at the top of that file before running it.
