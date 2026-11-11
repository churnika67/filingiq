# FilingIQ — 90-Second Demo Script

Target runtime: ~90 seconds. Practice with a timer; trim pauses before
cutting content.

---

**[0:00–0:12] Hook + what it is**

> "This is FilingIQ — a Snowflake pipeline that automatically ingests
> 10-K filings and feeds a RAG chatbot. The interesting part isn't the
> chatbot — it's that uploading a new filing is the *only* manual step.
> Everything else — parsing, chunking, deduping, indexing — runs itself."

*(Screen: README architecture diagram, or the folder structure for a
half-second, then cut to Snowsight.)*

**[0:12–0:30] Show the pipeline, not just the chatbot**

> "Here's the ingestion side. I upload a PDF to this stage — that's it,
> that's the only manual action in the whole system."

*(Screen: Snowsight stage browser, drag-drop or show an already-uploaded
file. Run `ALTER STAGE RAW_DOCS REFRESH;`.)*

> "A stream on this stage detects the new file. An hourly task — gated so
> it only runs when there's actually something new, to keep cost near
> zero — calls a stored procedure that parses it, chunks it, and logs
> the result."

*(Screen: run `EXECUTE TASK INGEST_TASK;`, then
`SELECT * FROM INGESTION_LOG ORDER BY processed_at DESC LIMIT 3;` —
point at the new OK row with a chunk count.)*

**[0:30–0:45] Prove it's incremental, not a one-shot script**

> "And it's genuinely incremental — if I upload one more file right now,
> only that file gets reprocessed. The other dozens of filings already
> ingested are untouched — no reprocessing, no duplicate chunks."

*(Screen: quickly show the "duplicates" validation query from
`sql/04_task.sql` returning 0 rows.)*

**[0:45–1:10] The chatbot demo**

> "Now the payoff — the Streamlit app on top of all that."

*(Screen: Streamlit app, Chat tab.)*

> "I'll ask a factual question with a company filter applied..."

*(Type a question like: "What was NVIDIA's data center revenue in fiscal
2024?" Show the answer streaming in, then expand the Sources box.)*

> "...and it cites exactly which filing that came from. Now a follow-up,
> no re-typing the company name..."

*(Type: "How does that compare to the prior year?" — demonstrates query
rewriting using chat history.)*

**[1:10–1:22] The refusal behavior**

> "And if I ask something the filings genuinely don't cover..."

*(Type an unanswerable-style question, e.g. "What's the CEO's favorite
programming language?")*

> "...it says so, instead of making something up. That's not an accident
> — it's measured. I ran a TruLens evaluation across three chunking
> strategies, scoring groundedness, relevance, and refusal rate, to pick
> the best config."

*(Screen: quick flash of `eval/results/comparison_chart.png` or the
Pipeline status tab.)*

**[1:22–1:30] Close**

> "Upload a file, everything downstream — parsing, indexing, monitoring,
> answering — takes care of itself. That's FilingIQ."

*(Screen: back to README or architecture diagram for the final beat.)*

---

## Recording tips

- Pre-upload most filings before recording; only demo the *incremental*
  upload live (one new file), so you're not waiting on a 100-page PDF to
  parse on camera.
- Have the Pipeline status tab and `INGESTION_LOG` query pre-run in a
  second tab so you can cut to it instantly instead of waiting on a
  warehouse resume.
- If Groq latency is noticeably slow during recording, trim the
  script's pauses rather than the content — a 2-3 second "thinking"
  pause reads as normal for an LLM demo.
