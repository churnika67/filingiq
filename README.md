# FilingIQ

I built FilingIQ to answer a question that kept bugging me while reading 10-Ks for class: why is finding one number in an annual report always this annoying? So I built a pipeline that ingests 10-K PDFs into Snowflake automatically, and put a chatbot on top of it so I could actually ask questions instead of ctrl-F-ing through 150 pages.

This is a **data engineering** project first. The chatbot is the fun demo, but the actual work is in the pipeline underneath it — detecting new files, parsing and chunking them, catching bad data, logging everything, and never doing the same work twice.

> **Heads up if you're setting this up on your own trial account:** I originally planned to build this entirely on Snowflake Cortex (`PARSE_DOCUMENT`, `SPLIT_TEXT_RECURSIVE_CHARACTER`, Cortex Search, `COMPLETE`). When I actually tested it, every single Cortex/AI function came back blocked:
> ```
> SNOWFLAKE.CORTEX.COMPLETE is not available on this account. New accounts
> are blocked from using legacy SNOWFLAKE.CORTEX functions. Please migrate
> to AI Functions and use AI_COMPLETE instead.
> AI function _AI_PARSE_DOCUMENT is not available for trial accounts.
> AI function EMBED_TEXT_768 is not available for trial accounts.
> ```
> Turns out AI Functions need a payment method on file, and I wasn't about to add one for a class project. So everything below is the version I actually got working without Cortex: PDF parsing and chunking as plain Python UDFs, retrieval as a hand-rolled TF-IDF SQL function, and answer generation on Groq's free tier instead of `COMPLETE`. If you've got a Snowflake account with AI Functions turned on, I left notes throughout on exactly where you'd swap Cortex back in.

## The problem

If you want to know something specific from a 10-K — say, how a company's data center revenue changed year over year — you're stuck downloading a PDF and searching through it by hand, every single time, for every filing. FilingIQ automates the part nobody wants to do manually: new filing shows up, it gets parsed, chunked, deduplicated, and indexed automatically, with a log telling you exactly what happened to it. Then whatever's querying that data — in this case, a chat app — always has a clean, current, filterable set of chunks to search.

## How it's wired together

```mermaid
flowchart LR
    A[I upload a PDF<br/>TICKER_YEAR_10K.pdf] --> B[RAW_DOCS internal stage<br/>directory table enabled]
    B -->|ALTER STAGE REFRESH| C[DOCS_STREAM<br/>CDC on directory table]
    C -->|WHEN SYSTEM$STREAM_HAS_DATA| D[INGEST_TASK<br/>hourly schedule]
    D --> E[PROCESS_NEW_DOCS&#40;&#41;<br/>stored procedure]
    E -->|PDF_TO_TEXT Python UDF| F[PARSED_DOCS]
    F -->|CHUNK_TEXT Python UDF<br/>+ SHA2 dedup| G[DOC_CHUNKS]
    E -->|per-file status| H[INGESTION_LOG]
    G --> I[SEARCH_CHUNKS<br/>TF-IDF SQL UDTF]
    I --> J[Local Streamlit app]
    J -->|Groq, grounded prompt| K[Answer + cited sources]
    H --> L[Pipeline status tab]
    G -. chunking configs .-> M[Local Jupyter notebook<br/>TruLens evaluation]
```

## What's actually running

| Layer | Technology |
|---|---|
| Storage / CDC | Snowflake internal stage (directory table) + STREAM |
| Orchestration | Snowflake TASK, scheduled hourly but gated so it skips hours with nothing new |
| Processing | Snowflake Scripting stored procedure |
| Document parsing | `PDF_TO_TEXT` — a Python UDF using `pypdf` (my stand-in for `PARSE_DOCUMENT`) |
| Chunking | `CHUNK_TEXT` — a Python UDF I wrote by hand, recursive-character splitting (stand-in for `SPLIT_TEXT_RECURSIVE_CHARACTER`) |
| Retrieval | `SEARCH_CHUNKS` — a SQL table function doing TF-IDF keyword search (stand-in for Cortex Search) |
| Generation | Groq's free tier (`openai/gpt-oss-120b` / `openai/gpt-oss-20b`) instead of `COMPLETE` |
| App | A local Streamlit app, talking to Snowflake over `snowflake-connector-python` and to Groq over plain `requests` |
| Evaluation | A local Jupyter notebook running TruLens (its Snowflake connector for storage, a Groq-backed provider for scoring) |
| Compute | One X-Small warehouse, auto-suspends after 60 seconds idle |

## Folder structure

```
filingiq/
  sql/
    01_setup.sql              database, warehouse, stage, core tables
    02_stream.sql              CDC stream on the stage
    03_process_procedure.sql   PDF_TO_TEXT / CHUNK_TEXT UDFs + PROCESS_NEW_DOCS() procedure
    04_task.sql                hourly task + incremental-load test queries
    05_search_service.sql      SEARCH_CHUNKS TF-IDF table function + tests
    99_teardown.sql            drop everything
  app/
    streamlit_app.py           chat UI + pipeline status dashboard (local app)
    requirements.txt            pip dependencies
    .env.example                Snowflake + Groq credentials template
  eval/
    eval_notebook.ipynb         chunking evaluation (local, TruLens)
    questions.csv               30-question eval set
    QUESTION_GUIDE.md           how I wrote the eval questions
    requirements.txt            pip dependencies
    .env.example                Snowflake + Groq credentials template
    results/                    eval output (CSVs, chart) lands here
  docs/
    INTERVIEW_NOTES.md
    DEMO_SCRIPT.md
    RESUME.md
    screenshots/
  README.md
  RUNBOOK.md
```

## Setting it up

1. Spin up a Snowflake trial account — any region works, since this version doesn't touch Cortex at all.
2. In a Snowsight worksheet, run `sql/01_setup.sql` through `sql/05_search_service.sql` in order. `RUNBOOK.md` has the expected output and common error fixes for each step.
3. Grab 10-K PDFs from each company's investor relations page, rename them to `TICKER_YEAR_10K.pdf`, and upload them to the `RAW_DOCS` stage in Snowsight.
4. Get a free Groq key — no card needed: [console.groq.com/keys](https://console.groq.com/keys).
5. `cd app/`, `pip install -r requirements.txt`, `cp .env.example .env` and fill it in, then `streamlit run streamlit_app.py`.
6. `cd eval/`, fill in `expected_answer` in `questions.csv`, `pip install -r requirements.txt`, set up `.env`, and run `eval_notebook.ipynb` in Jupyter.

## Why I built the pipeline the way I did

**Idempotency mattered a lot to me here.** If I re-upload the same file, I don't want duplicate chunks sitting around. `PROCESS_NEW_DOCS()` always deletes any existing rows for that file path before reprocessing, so a re-upload is a true replace. I also hash every chunk with `SHA2` and drop exact duplicates within a file — useful since PDF parsers love repeating headers and footers as if they were real content.

**It only does work when there's actually new work.** A stream on the stage plus a task gated on `SYSTEM$STREAM_HAS_DATA` means uploading 20 files and then 4 more only ever reprocesses the 4 — I checked this directly against `INGESTION_LOG` rather than just assuming it (see `sql/04_task.sql`).

**One bad PDF can't take down the whole batch.** Each file gets parsed and chunked inside its own nested `BEGIN...EXCEPTION...END` block, so if one file is malformed, it gets logged as `FAILED` and everything else keeps going.

**The log tells you something is actually wrong, not just that something happened.** Every file gets logged as `OK`, `WARN` (fewer than 5 chunks — probably a scanned, mostly-image filing), or `FAILED` (empty text or a real error). That turns "did ingestion work?" into one query instead of scrolling through logs.

**I kept an eye on cost the whole time.** One X-Small warehouse, 60-second auto-suspend, an hourly task that skips itself when there's nothing new, and a search function with no standing index to keep warm — there's basically nothing running when nobody's using it.

**Honestly, the Cortex-to-no-Cortex pivot is the part I'm proudest of.** Finding out midway through that the whole plan wouldn't work on a free account, and rebuilding parsing, chunking, and retrieval around that constraint instead of giving up, taught me more than if Cortex had just worked on the first try.

## Evaluation results

I ran this live on 2026-11-12, against the production chunking config (1800/300) over my real 8-company, 12-filing corpus, using all 30 questions in `questions.csv`.

| Metric | Score | Sample |
|---|---|---|
| Groundedness | 0.64 | 11 questions |
| Context relevance | 0.81 | 12 questions |
| Answer relevance | 0.75 | 12 questions |
| Accuracy (LLM-judge vs. my own written answers) | 0.33 | 12 questions |
| Refusal rate (unanswerable questions) | **not measured** | 0 of 6 |

I want to be upfront about why the sample sizes are 11-12 instead of 30, and why refusal rate is blank instead of a number: Groq's free tier has a tight per-minute token cap, and my key ran out of room partway through the run (this notebook makes up to 4 Groq calls per question, so it adds up fast). The 6 unanswerable questions happened to sit near the end of my CSV, and every one of them failed before getting a real answer — so refusal rate has literally zero data points behind it, not a real `0%`. Reporting it as `0%` would wrongly suggest the model never refuses, when really it was just never successfully asked. The other four numbers are genuine measurements from the questions that did go through.

If I get a fresh key or wait out the quota, re-running `eval/eval_notebook.ipynb` should get through all 30 — the pacing and retry logic are already built to survive a full run as long as the quota holds. I also only ran one chunk-size config instead of the three I originally planned (1000/200, 1800/300, 3000/500) to keep the run short enough to actually finish; the other two are still in the notebook's `CONFIGS` dict, just commented out of this run.

## Screenshots

*(Still need to grab these from the live app.)*

- `docs/screenshots/chat_tab.png` — chat tab with a grounded answer and cited sources
- `docs/screenshots/pipeline_status_tab.png` — pipeline status dashboard
- `docs/screenshots/ingestion_log.png` — `INGESTION_LOG` after an incremental run
- `docs/screenshots/eval_chart.png` — chunking configuration comparison chart

## Cost

- Everything in Snowflake runs on one X-Small warehouse that suspends after 60 seconds idle — I'm only billed while something's actually running.
- The hourly task checks `SYSTEM$STREAM_HAS_DATA` before it even spins up a warehouse, so most hours cost nothing at all.
- `SEARCH_CHUNKS` doesn't maintain any kind of index — it just queries `DOC_CHUNKS` directly, so there's no background re-indexing cost like a Cortex Search Service would have.
- Groq's free tier has no card requirement, but the rate limit is real — the eval notebook paces its requests and retries on a 429 to try to stay under it.
- Even without touching metered AI Functions, Python UDFs and warehouse compute still use trial credits, so I kept an eye on the Snowsight billing page.

## What I had to work around on a trial account

Here's every place I couldn't use the "real" Cortex feature and what I used instead:

| Cortex feature | Why it's blocked | What I used instead |
|---|---|---|
| `SNOWFLAKE.CORTEX.PARSE_DOCUMENT` / `AI_PARSE_DOCUMENT` | Not available on trial accounts | `PDF_TO_TEXT` Python UDF (`pypdf`) — `sql/03_process_procedure.sql` |
| `SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER` | Same restriction | `CHUNK_TEXT` Python UDF, a splitter I wrote by hand — `sql/03_process_procedure.sql` |
| Cortex Search Service | Calls `EMBED_TEXT_768` under the hood, which is also blocked | `SEARCH_CHUNKS`, a SQL table function doing TF-IDF scoring — `sql/05_search_service.sql` |
| `SNOWFLAKE.CORTEX.COMPLETE` / `AI_COMPLETE` | Needs a payment method on file | Groq's free API, called from the local app/notebook |
| Streamlit in Snowflake / Snowflake Notebooks | Can't make outbound calls to Groq without extra network setup | App and notebook both run locally instead |
| TruLens's Cortex feedback provider | Needs `COMPLETE` under the hood | TruLens's `LiteLLM` provider pointed at Groq, still using its Snowflake connector for storage |

If you're running this on an account that *does* have AI Functions turned on, every row above is a drop-in swap — point `PDF_TO_TEXT`/`CHUNK_TEXT` at the real Cortex functions, turn `SEARCH_CHUNKS` into an actual Cortex Search Service, and swap the Groq calls for `AI_COMPLETE`. At that point you could probably move the app back into Streamlit in Snowflake too.

A few spots in the SQL are marked `-- VERIFY` where I wasn't 100% sure the exact syntax would hold up over time (Groq's model list and TruLens's packaging both move around) — worth a quick check before you rely on them.

## What I'd do next if I kept going

- Wrap the whole RAG pipeline in a proper TruLens `App`/`TruCustomApp` recorder instead of scoring things manually, so it's continuous monitoring and not just a one-off eval run.
- Fire off an alert (probably `SYSTEM$SEND_EMAIL`) when `INGESTION_LOG` logs a `FAILED` row, instead of relying on me remembering to check the dashboard.
- Support other filing types (10-Q, 8-K, earnings call transcripts) by generalizing the filename parsing instead of hardcoding `SPLIT_PART` logic for one pattern.
- Swap `SEARCH_CHUNKS`'s TF-IDF scoring for real embedding-based search if I ever get AI Functions enabled — this is honestly the biggest quality ceiling in the whole project right now. TF-IDF just can't tell that "headcount" and "employees" mean the same thing.
- Add row-level access policies on `DOC_CHUNKS` if this ever needed to be multi-tenant.
- Finish the full 3-config eval comparison and actually re-point the production table at whichever config wins, instead of just assuming 1800/300 is good enough.
