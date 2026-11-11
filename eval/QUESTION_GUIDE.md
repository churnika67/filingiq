# Writing good evaluation questions for FilingIQ

`questions.csv` is the evaluation set for the RAG pipeline. This guide
explains how to fill in the blank `expected_answer` column and how to
extend the set with your own questions.

## Columns

| Column | Meaning |
|---|---|
| `question` | The question to ask the chatbot, exactly as a user would type it. |
| `expected_answer` | **You fill this in** — the correct, concise answer, taken directly from the filing. |
| `company` | Ticker the question is about (matches the `TICKER` in `TICKER_YEAR_10K.pdf`). |
| `fiscal_year` | Single year for factual/unanswerable questions; `YYYY-YYYY` for comparison questions spanning two filings. |
| `type` | One of `factual`, `comparison`, `unanswerable`. |

## How to find answers in a 10-K

10-Ks follow a standard SEC structure (Form 10-K, Regulation S-K). The
fastest way to find an answer is to go straight to the right Item:

- **Item 1 — Business**: segment descriptions, products, employee counts, competition.
- **Item 1A — Risk Factors**: supply chain, regulatory, competitive, and macro risks the company discloses.
- **Item 7 — MD&A (Management's Discussion & Analysis)**: the best source for *narrative* explanations of *why* revenue/margins changed year over year — this is usually where "primary drivers of X" answers live.
- **Item 7A — Quantitative and Qualitative Disclosures About Market Risk**: interest rate, currency, commodity exposure.
- **Item 8 — Financial Statements**: the actual Income Statement, Balance Sheet, Cash Flow Statement, and footnotes — the authoritative source for exact dollar figures (revenue, R&D expense, segment revenue, capex, etc.).
- **Item 8 footnotes — Segment Information**: segment-level revenue/operating income breakdowns (e.g. AWS, Data Center, Reality Labs).
- **Cover page**: company name, ticker, fiscal year end date.
- **Signatures page**: officer names/titles as of the filing date (useful for "who was CEO" questions).
- **Audit report (right before Item 8 or in an exhibit)**: name of the independent registered public accounting firm.

Use Ctrl+F / Cmd+F in the PDF for exact phrases like "Data Center revenue",
"gross margin", "full-time employees", "Item 1A", or a specific dollar
figure you're trying to confirm.

## Writing factual questions (20 in the set)

- Ask for a single, verifiable fact: a dollar figure, a percentage, a
  count, a name.
- Prefer facts stated explicitly in the filing (a number in a table) over
  facts you'd have to compute — the LLM-as-judge grading step compares
  against your `expected_answer`, so vague or inferred answers are harder
  to grade consistently.
- Spread questions across different companies, years, and 10-K sections
  (don't make every question about revenue) so the eval actually tests
  retrieval breadth, not just "can it find the income statement."

## Writing cross-year comparison questions (5 in the set)

- Ask about a trend or change between two fiscal years for the *same*
  company and metric (e.g. "how did X change from FY22 to FY24").
- These specifically test whether retrieval can pull relevant chunks from
  *two different filings* (and therefore two different `fiscal_year`
  attribute values) for one answer — a good proxy for whether your
  `SEARCH_CHUNKS` filters and chunk attribution are working correctly.
- Write `expected_answer` as a short statement of direction + magnitude,
  e.g. "Increased from $X to $Y, driven by growth in segment Z."

## Writing unanswerable questions (5 in the set)

- These should be plausible-sounding questions that a 10-K genuinely does
  **not** and *cannot* answer: personal details about executives, future
  stock prices, unannounced product plans, information from a different
  company's filing that isn't in your corpus, etc.
- The point is to measure the chatbot's **refusal rate** — a well-grounded
  RAG system should say "Not found in the filings" rather than
  hallucinating a plausible-sounding but fabricated answer.
- Leave `expected_answer` blank (or write "N/A — should refuse") for these;
  the eval notebook scores them by whether the chatbot *correctly refused*,
  not by comparing to a specific answer.

## Filling in `expected_answer`

1. Open the 10-K PDF for the `company`/`fiscal_year` in the row.
2. Locate the relevant section using the table above.
3. Write a short (1-2 sentence), specific answer in your own words,
   including the exact figure/name where applicable.
4. Leave `unanswerable` rows blank — see above.
5. Save the file as `questions.csv` (same filename, same columns) so
   `eval_notebook.ipynb` can load it without changes.
