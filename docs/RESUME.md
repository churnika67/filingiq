# FilingIQ — Resume / LinkedIn Copy

## Resume bullets

Pick the metrics variant that matches your actual eval numbers once
you've run `eval/eval_notebook.ipynb`; placeholders marked `[ ]`.

- Designed and built an incremental, idempotent document-ingestion
  pipeline in Snowflake (stage + stream + task + stored procedure) that
  parses, chunks, deduplicates, and monitors SEC 10-K filings with
  per-file error isolation, processing new uploads automatically within
  [ ] minute(s) at near-zero idle cost (X-Small warehouse, auto-suspend,
  stream-gated scheduling).
- Built a RAG chatbot (SQL-based TF-IDF retrieval + Groq LLM, Streamlit)
  over the ingested filings with conversational query rewriting and
  strict answer grounding; evaluated 3 chunking configurations across
  [ ] questions with TruLens, improving groundedness from [ ]% to [ ]%
  and achieving a [ ]% correct-refusal rate on unanswerable questions.
- Diagnosed a platform constraint (Snowflake Cortex/AI Functions blocked
  on trial accounts without a payment method) and re-architected parsing,
  chunking, and search around Python UDFs and a hand-built SQL scoring
  function rather than blocking the project on it.

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
refuses to answer when a filing doesn't support a claim. I evaluated
three chunking strategies end-to-end with TruLens (groundedness, context
relevance, answer relevance) plus LLM-as-judge accuracy and refusal-rate
testing on unanswerable questions, landing on [ ] as the best-performing
configuration with a [ ]% composite score.
