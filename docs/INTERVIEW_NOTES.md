# FilingIQ — Interview Notes

Talking points per component, plus likely interview questions with
answers. Written for a Data Engineer interview where ML is secondary.

## 0. The Cortex/AI Functions pivot (this is itself a good story)

**Talking points:**
- The project was designed around Snowflake Cortex end-to-end
  (`PARSE_DOCUMENT`, `SPLIT_TEXT_RECURSIVE_CHARACTER`, Cortex Search,
  `COMPLETE`). Testing against the actual trial account surfaced that
  every Cortex/AI function — legacy `SNOWFLAKE.CORTEX.*` and the newer
  `AI_*` family alike — is blocked without a payment method on file. That's
  a real constraint, not a bug to work around quietly: I documented the
  exact error messages (README.md, top) and re-architected three
  components around it rather than stalling the project on an account
  upgrade.
- The replacements are deliberately *not* a downgrade-and-apologize story:
  `PDF_TO_TEXT`/`CHUNK_TEXT` (Python UDFs) and `SEARCH_CHUNKS` (a SQL
  TF-IDF table function) are fully functional, inside-Snowflake
  replacements with clearly understood tradeoffs (no OCR for scanned
  PDFs; lexical-only search, no semantic matching) — both documented and
  both reversible if AI Functions become available later (see README's
  "Trial-account notes" swap-in table).
- This is a genuinely good interview story: it demonstrates reading error
  messages carefully, not assuming a platform limitation means "stop,"
  and making an architecture decision that's honest about its own
  tradeoffs instead of hiding them.

**Likely questions:**
- *"Why not just add a payment method and use Cortex?"* — For a personal
  portfolio project exploring a free trial, that's a reasonable thing to
  avoid; more importantly, building the no-Cortex version is the more
  interesting engineering problem and the more honest demonstration of
  working within real constraints, which is what a production environment
  actually looks like far more often than "it's all available, just call
  the API."
- *"How confident are you these replacements are production-quality?"* —
  They're appropriately scoped for this project's size (a few dozen
  filings): `pypdf`-based extraction and TF-IDF both degrade gracefully
  (documented explicitly, not silently) at a scale or quality bar where
  managed Cortex services would pull ahead — I'd frame it as "right-sized
  for the constraint and corpus," not "equivalent to Cortex at any scale."

## 1. Stage + directory table + stream (change detection)

**Talking points:**
- Chose an internal stage with a directory table instead of writing a
  custom "list files and diff against a tracking table" job — Snowflake
  already maintains that metadata, so the stream *is* the diff, for free.
- A stream on a stage gives exactly the semantics an incremental pipeline
  needs: read-only peeking is non-destructive, and the offset only
  advances when a DML statement that consumes it actually commits — so a
  failed run doesn't silently "lose" files the way a naive
  "mark as processed" flag could if the write failed.
- Trade-off: streams require explicit `ALTER STAGE ... REFRESH` after an
  upload; Snowsight doesn't trigger that automatically. I handled this by
  refreshing both in the manual runbook step and as the first action of
  the scheduled task, so staleness is bounded by the task's schedule even
  if someone forgets to refresh manually.

**Likely questions:**
- *"Why not just query `DIRECTORY(@stage)` every run and diff against
  `INGESTION_LOG`?"* — You can, and it's the documented fallback for
  accounts without stream-on-stage support (see README). The tradeoff is
  that you're now responsible for the "what's new" logic and have to get
  the idempotency right yourself (e.g. handling a file that was deleted
  and re-added), whereas the stream's `METADATA$ACTION` encodes that for
  you.
- *"What happens if two runs overlap?"* — Tasks don't overlap by default
  (a scheduled run is skipped if the previous one is still executing), and
  I additionally only ever call `EXECUTE TASK` manually for testing, so in
  practice there's a single writer. If I needed true concurrent safety
  I'd add a lock table or rely on the stream's single-consumer-per-offset
  semantics plus table-level locking Snowflake already does on the
  `INSERT ... FROM stream`.

## 2. `PROCESS_NEW_DOCS()` stored procedure (idempotent processing)

**Talking points:**
- Idempotency is enforced at the data layer, not by "don't re-upload
  files": re-processing a path always deletes-then-inserts, so the
  pipeline is safe even if someone does re-upload a corrected filing.
- Per-file error isolation (`BEGIN...EXCEPTION...END` nested inside the
  `FOR` loop) was a deliberate choice over a single bulk
  `INSERT...SELECT` across all pending files — a bulk approach is fewer
  lines and faster, but one corrupt PDF would abort the entire batch. I
  traded a bit of throughput for resilience, which is the right trade for
  a pipeline ingesting hand-curated files that *will* occasionally be
  malformed.
- Dedup via `SHA2(chunk)` + `QUALIFY ROW_NUMBER()` catches the
  boring-but-real problem of PDF parsers emitting repeated
  header/footer text as its own "chunk" on every page.

**Likely questions:**
- *"Why Snowflake Scripting instead of a Python stored procedure /
  Snowpark?"* — The logic here is fundamentally a sequence of SQL
  DML/DDL statements with light control flow (loop, branch, try/catch);
  Snowflake Scripting keeps everything in one language and one object,
  with the `PDF_TO_TEXT`/`CHUNK_TEXT` UDFs called inline exactly as they
  would be in a plain SELECT. I'd reach for Python/Snowpark if I needed
  real general-purpose logic (complex string parsing beyond `SPLIT_PART`,
  calling an external API) that SQL scripting makes awkward — notice that
  the actual PDF-parsing/chunking logic itself *does* live in Python UDFs
  for exactly that reason; the orchestration around it stays in SQL
  scripting because that part is genuinely just DML plus control flow.
- *"How would you handle a 10-K with 500+ pages timing out?"* — Break
  `PDF_TO_TEXT` + chunking per file into its own transaction (already
  true here, since each file is a separate statement group) and increase
  the task's warehouse size temporarily, or move to a multi-cluster/
  larger warehouse just for ingestion if latency became a real SLA
  concern — this project optimizes for *cost* over *latency* since
  hourly freshness is more than enough for 10-Ks that are filed a few
  times a year.
- *"Why `WARN` at <5 chunks instead of just OK/FAILED?"* — Binary status
  hides a real signal: a file that parsed "successfully" but produced
  almost no text is probably a scanned/image-heavy filing that needs a
  different extraction path, not a bug in the pipeline. Surfacing it as
  `WARN` makes that visible without blocking the batch.

## 3. Task scheduling (orchestration)

**Talking points:**
- `WHEN SYSTEM$STREAM_HAS_DATA(...)` is the single most cost-relevant
  line in the project: it means the warehouse never spins up for an
  "hourly" check that finds nothing, which is the difference between
  "hourly" costing the same as "on-demand" vs. costing 24x more.
- Chose a stored procedure + task over an orchestrator-managed DAG (e.g.
  Airflow) because the entire pipeline lives inside one system (Snowflake)
  with no cross-system dependencies to coordinate — a task is the
  simplest tool that's still correct here. I'd reach for an external
  orchestrator if this needed to join with non-Snowflake systems or if
  the DAG had branching dependencies more complex than "parse then chunk."

**Likely questions:**
- *"How do you monitor task failures in production?"* — `TASK_HISTORY`
  plus `INGESTION_LOG`'s `FAILED` rows today; the natural next step
  (listed in README "Future improvements") is an alerting task or
  `SYSTEM$SEND_EMAIL` call triggered on a `FAILED` row rather than relying
  on someone opening the dashboard.
- *"Why hourly and not real-time?"* — 10-Ks are filed a handful of times
  a year per company; sub-hour freshness has no real-world value here and
  would only add indexing/compute cost. I size the schedule to the actual
  arrival rate of the data, not to an arbitrary "faster is better."

## 4. `SEARCH_CHUNKS` TF-IDF search function (retrieval)

**Talking points:**
- This was originally going to be a Cortex Search Service (managed hybrid
  vector + keyword search); testing showed Cortex Search's index build
  calls `EMBED_TEXT_768`, which is blocked on a no-payment-method trial
  account. Rather than stand up an external vector DB (which would have
  meant leaving Snowflake entirely for retrieval — a bigger architectural
  change than the constraint justified), I implemented TF-IDF scoring as
  a plain SQL table function over the existing `DOC_CHUNKS` table: term
  frequency (via a length/substring-count trick, so arbitrary query words
  never need regex escaping) weighted by inverse document frequency,
  scoped to whatever company/year filter is active.
- Doing this as a SQL UDTF rather than a Python UDTF keeps it index-free:
  every call reads `DOC_CHUNKS` directly, so there's no separate object
  to keep in sync (no `TARGET_LAG`, no re-embedding job) — results are
  exactly as fresh as the last committed chunk.
- `company`/`fiscal_year` are explicit function parameters (not a
  post-retrieval filter) — the WHERE clause narrows the candidate set
  *before* scoring, which is both cheaper and keeps the IDF calculation
  scoped to a sensible subset rather than the whole corpus.

**Likely questions:**
- *"Why not just fall back to an external vector DB when Cortex Search
  was blocked?"* — That would have reintroduced the exact thing using
  Cortex Search was meant to avoid: a second system with its own auth,
  networking, and sync-lag problem. TF-IDF in plain SQL stays inside
  Snowflake, costs nothing extra, and is honestly a better fit for a
  trial-account budget constraint than running an external service I'd
  also have to operate.
- *"What's the real quality cost of TF-IDF vs. semantic search?"* — TF-IDF
  can't match a synonym or a differently-worded question to the right
  chunk (e.g. "headcount" won't match a filing that only says "employees")
  — purely lexical overlap. That's the single biggest limitation of this
  version and the first thing I'd swap out (see README "Future
  improvements") if AI Functions became available.
- *"How would you scale this to thousands of filings?"* — The chunking/
  dedup/logging design doesn't change; what would change is
  partitioning ingestion (e.g. batching by company) so the hourly task
  doesn't serialize on one giant `FOR` loop, and possibly pre-computing
  document frequencies in a materialized table rather than recomputing
  them per query once the corpus is large enough for that to matter.

## 5. Streamlit app (demo layer)

**Talking points:**
- Query rewriting for follow-ups (using the last 3 turns to produce a
  standalone query before retrieval) exists because naive RAG chat bugs
  out exactly on "what about in 2023?" — the retrieval step has no memory,
  so without rewriting, that query alone retrieves nothing useful.
- The strict grounded prompt + explicit "Not found in the filings."
  fallback is the single most important prompt-engineering decision in
  the project — it's what turns this from "a chatbot that sounds
  confident" into "a chatbot whose wrong answers are rare and whose
  right answers are checkable," which is the only way a finance-adjacent
  tool like this is trustworthy.

**Likely questions:**
- *"How do you know the model isn't hallucinating despite the grounded
  prompt?"* — That's exactly what the evaluation notebook's groundedness
  score measures (via TruLens's LiteLLM-backed feedback provider) rather
  than trusting the prompt alone; a good system design treats
  "instructed the model to behave" and "verified the model behaved" as
  two separate steps.
- *"Why does this run as a local app instead of Streamlit in
  Snowflake?"* — Answer generation calls Groq's API, and Streamlit in
  Snowflake's sandboxed runtime can't make arbitrary outbound HTTPS calls
  without configuring an External Access Integration (network rules +
  secrets, needing `ACCOUNTADMIN`-level setup). Running locally with
  `snowflake-connector-python` for the Snowflake side and `requests` for
  Groq was the pragmatic choice for a trial account; if Cortex `COMPLETE`
  were available I'd move generation back into Snowflake and the app back
  into Streamlit in Snowflake, since in-platform is the better default
  once it's actually available.
- *"Why offer two different open-weights models instead of one?"* — Cost/
  quality tradeoff transparency — letting a user compare a larger (70B)
  vs. smaller/faster (8B) model on the same retrieved context demonstrates
  that the retrieval layer and the generation layer are genuinely
  decoupled, which matters more once you're not locked into whatever
  models one provider happens to host.

## 6. Evaluation (TruLens + LLM-as-judge)

**Talking points:**
- Three separate, orthogonal signals: groundedness (is the *answer*
  supported by the *retrieved context*), context relevance (did
  *retrieval* find the right context for the *question*), and answer
  relevance (does the *answer* actually address the *question*). Any one
  alone can look good while the pipeline is broken elsewhere — e.g. high
  answer relevance with low context relevance usually means the model is
  answering from pretraining knowledge, not the filing.
- Unanswerable questions + refusal rate exist because accuracy/
  groundedness scores alone can't catch "the model confidently answered a
  question the filings never addressed" — that failure mode needs its
  own dedicated test.
- Compared three chunk sizes rather than picking one from intuition,
  because chunk size is one of the highest-leverage, cheapest-to-tune
  knobs in a RAG system, and "bigger chunks = more context but less
  precise retrieval" is a real tradeoff worth measuring, not assuming.

**Likely questions:**
- *"Why not just use retrieval recall@k against a labeled set?"* — That
  measures retrieval alone; this project's evaluation set doesn't have
  labeled "correct chunk IDs" (expensive to build), so LLM-judged
  groundedness/relevance plus end-to-end accuracy against a human-written
  `expected_answer` is a more practical proxy that still exercises the
  whole pipeline, not just the search layer.
- *"How would you validate the LLM-as-judge itself isn't wrong?"* — Spot-
  check a sample of its 0/1 accuracy calls by hand, and consider a second
  judge model as a cross-check if this were going to production — judge
  reliability is itself worth evaluating, not assumed.
