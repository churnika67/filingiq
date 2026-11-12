# FilingIQ — Resume / LinkedIn Copy

## Resume bullets

Remaining placeholder marked `[ ]`: ingestion latency depends on how you
schedule the task (hourly by default, or on-demand via `EXECUTE TASK`),
so fill in whatever cadence you actually run it at.

- Designed and built an incremental, idempotent document-ingestion
  pipeline in Snowflake (stage + stream + task + stored procedure) that
  parses, chunks, deduplicates, and monitors SEC 10-K filings with
  per-file error isolation, processing new uploads automatically within
  [ ] minute(s) at near-zero idle cost (X-Small warehouse, auto-suspend,
  stream-gated scheduling) across 12 real 10-K filings spanning 8
  companies.
- Built a RAG chatbot (SQL-based TF-IDF retrieval + Groq LLM, Streamlit)
  over the ingested filings with conversational query rewriting,
  multi-company comparison retrieval, and strict answer grounding;
  evaluated with TruLens, measuring 0.64 groundedness, 0.81 context
  relevance, and 0.75 answer relevance on real questions against the
  deployed corpus.
- Diagnosed a platform constraint (Snowflake Cortex/AI Functions blocked
  on trial accounts without a payment method) and re-architected parsing,
  chunking, and search around Python UDFs and a hand-built SQL scoring
  function rather than blocking the project on it.
- Found and fixed six distinct, independently-verified bugs through live
  testing — a corrupted-font PDF decoding issue (reverse-engineered a
  Caesar-cipher-style character shift), a query-rewrite step that
  hallucinated facts, a mid-word chunk-boundary bug, and three retrieval
  scoring issues — each confirmed with a before/after test, not just
  patched and assumed fixed.

## LinkedIn project description (3 sentences)

FilingIQ is a Snowflake-native data engineering project that turns a
folder of 10-K PDFs into a continuously updated, queryable knowledge
base: an internal stage with change-data-capture (via a Snowflake
STREAM) feeds an hourly, idempotent ingestion pipeline that parses,
chunks, deduplicates, and logs every filing with per-file error
isolation, all running on a single auto-suspending warehouse for
near-zero idle cost — parsing and chunking run as Snowflake Python UDFs
after I found Cortex/AI Functions were blocked on a no-payment-method
trial account. On top of that pipeline sits a retrieval-augmented chatbot
(a SQL TF-IDF search function plus a Groq-hosted LLM, served via
Streamlit) that answers questions with cited sources and explicitly
refuses to answer when a filing doesn't support a claim. I evaluated the
pipeline end-to-end with TruLens (groundedness, context relevance,
answer relevance) plus LLM-as-judge accuracy against human-written
reference answers, measuring 0.64 groundedness and 0.75 answer relevance
on real questions against the deployed 8-company, 12-filing corpus —
and along the way found and fixed six distinct, independently-verified
bugs through live testing, including reverse-engineering a corrupted
PDF font encoding by cross-referencing two different extraction
libraries.
