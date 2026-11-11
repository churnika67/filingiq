/* =====================================================================
   FilingIQ — 05_search_service.sql
   Creates SEARCH_CHUNKS: a SQL table function (UDTF) implementing TF-IDF
   keyword search over DOC_CHUNKS, plus smoke-test queries. Run after
   04_task.sql (or at minimum after DOC_CHUNKS has some rows in it).

   WHY NOT A CORTEX SEARCH SERVICE: Cortex Search Service creation calls
   SNOWFLAKE.CORTEX.EMBED_TEXT_768 internally to build its vector index.
   On this trial account that function returns:
     "AI function EMBED_TEXT_768 is not available for trial accounts."
   so Cortex Search isn't an option without adding a payment method (see
   the note at the top of sql/03_process_procedure.sql for the matching
   parsing/chunking workaround). SEARCH_CHUNKS below is a from-scratch
   TF-IDF (term frequency x inverse document frequency) scorer: it
   rewards chunks containing more of the query's rare words, which is a
   reasonable keyword-search stand-in for a managed vector index, at the
   cost of not understanding synonyms/semantic similarity the way
   embedding-based search would.
   ===================================================================== */

USE WAREHOUSE FILINGIQ_WH;
USE DATABASE FILINGIQ_DB;
USE SCHEMA PUBLIC;

-- A SQL UDTF (table function) is defined as a single SELECT statement
-- parameterized by its arguments; calling it with TABLE(SEARCH_CHUNKS(...))
-- returns rows just like querying a table. Unlike a Cortex Search
-- Service, there's no separate index object to keep in sync — every call
-- reads DOC_CHUNKS directly, so results are always current as of the
-- last commit (no TARGET_LAG to think about).
--
-- VERIFY / IMPORTANT SYNTAX NOTE: the body below is a classic
-- single-quoted string literal (`AS '...'`, with every literal `'`
-- inside doubled to `''`), NOT the `AS $$ ... $$` dollar-quoted form.
-- Tested directly against this account: a `WITH`-clause body inside
-- `$$ ... $$` fails to compile ("unexpected 'WITH'"), while the exact
-- same SQL inside a single-quoted string body compiles and runs fine.
-- If you rewrite this function, keep the single-quote form.
--
-- Scoring: for each query term, term frequency is computed via a
-- LENGTH/REPLACE trick (counts substring occurrences without needing
-- regex for the counting itself), weighted by ln(1 + N / document_frequency)
-- — classic TF-IDF. Both frequencies are computed only over the
-- (optionally company/year-filtered) candidate set, not the whole table,
-- which keeps this cheap on a small corpus and also means "document
-- frequency" is scoped to whatever subset you're actually searching.
--
-- Three fixes found by live-testing this against real 10-Ks, all scoped
-- to the scoring step only (the returned `chunk` text is unchanged):
--  1. `chunk` is stored as "FILENAME.pdf: <body>" (by design — see
--     sql/03_process_procedure.sql). Scoring against the raw chunk let
--     filename tokens ("aapl", "2026", "10k") compete with real content
--     words. `lc` strips everything up to the first ": " before scoring.
--  2. A company's own name/ticker appears in nearly every one of its own
--     chunks (10-Ks reference the company constantly), so a short
--     passage that happens to repeat it densely — e.g. a subsidiary
--     list — can out-score the actual narrative answer purely on raw
--     frequency. Known tickers/names are excluded from SCORING
--     unconditionally (not only when a `company_filter` happens to be
--     set) — found by testing that two different questions mentioning
--     "Apple" and "Microsoft" with no company filter applied returned
--     the exact same top chunks with identical scores, because those
--     two names were the only terms that matched anything at all.
--  3. A stopword list keeps generic question words ("what", "does",
--     "the", "mention"...) from being treated as query terms at all —
--     they'd otherwise match almost every chunk and add noise without
--     adding any real signal. REGEXP_REPLACE strips punctuation before
--     splitting on spaces, so "factors?" and "factors" are the same term.
CREATE OR REPLACE FUNCTION SEARCH_CHUNKS(
    query_text      STRING,
    company_filter  STRING,
    year_filter     NUMBER,
    k               NUMBER
)
RETURNS TABLE (
    chunk          STRING,
    company        STRING,
    fiscal_year    NUMBER,
    relative_path  STRING,
    chunk_index    NUMBER,
    score          FLOAT
)
LANGUAGE SQL
COMMENT = 'TF-IDF keyword search over DOC_CHUNKS. Replaces Cortex Search Service (EMBED_TEXT_768 blocked on trial accounts).'
AS '
    WITH terms AS (
        SELECT DISTINCT t.value::STRING AS term
        FROM TABLE(SPLIT_TO_TABLE(REGEXP_REPLACE(LOWER(query_text), ''[^a-z0-9 ]'', '' ''), '' '')) t
        WHERE LENGTH(t.value) > 2
          AND t.value NOT IN (
                ''the'', ''a'', ''an'', ''of'', ''and'', ''or'', ''to'', ''in'', ''on'', ''for'', ''with'',
                ''from'', ''that'', ''this'', ''these'', ''those'', ''are'', ''its'', ''their'',
                ''what'', ''which'', ''who'', ''whose'', ''why'', ''when'', ''how'',
                ''does'', ''did'', ''do'', ''is'', ''was'', ''were'', ''has'', ''have'',
                ''mention'', ''mentions'', ''mentioned'', ''related'', ''about'', ''main''
          )
          -- Exclude known tickers/company names from scoring UNCONDITIONALLY
          -- (not only when a sidebar company_filter happens to be set).
          -- Found by live-testing a comparison question with the filter
          -- left on "All": a company''s own name appears in nearly every
          -- one of its own chunks, so with no exclusion at all, two
          -- completely different questions that both happen to mention
          -- "Apple" and "Microsoft" (e.g. one asking to compare them, one
          -- asking generally about risk factors right after, with the
          -- follow-up rewriter folding the companies back in) can end up
          -- scoring the SAME six boilerplate chunks with IDENTICAL totals
          -- — because the only terms that actually matched anything in
          -- those chunks were the two company names, and every other,
          -- genuinely distinguishing word in each question matched zero
          -- chunks. Excluding company names/tickers from scoring (not
          -- from the WHERE filter, which still uses the real
          -- company_filter/year_filter as before) forces ranking to run
          -- on the actual topic words instead.
          -- VERIFY / LIMITATION: hardcoded to the companies this demo
          -- corpus actually uses; extend this list for other tickers.
          AND t.value NOT IN (
                ''aapl'', ''apple'', ''msft'', ''microsoft'', ''nvda'', ''nvidia'',
                ''googl'', ''google'', ''amzn'', ''amazon'', ''meta'', ''tsla'', ''tesla'',
                ''jpm'', ''jpmorgan'', ''nflx'', ''netflix''
          )
    ),
    cand AS (
        SELECT c.chunk_id, c.chunk, c.company, c.fiscal_year, c.relative_path, c.chunk_index,
               LOWER(SUBSTR(c.chunk, POSITION('': '' IN c.chunk) + 2)) AS lc
        FROM FILINGIQ_DB.PUBLIC.DOC_CHUNKS c
        WHERE (company_filter IS NULL OR c.company = UPPER(company_filter))
          AND (year_filter    IS NULL OR c.fiscal_year = year_filter)
    ),
    n AS (
        SELECT COUNT(*) AS n FROM cand
    ),
    df AS (
        SELECT t.term, COUNT_IF(CONTAINS(c.lc, t.term)) AS df
        FROM terms t CROSS JOIN cand c
        GROUP BY t.term
    ),
    scored AS (
        SELECT c.chunk_id, c.chunk, c.company, c.fiscal_year, c.relative_path, c.chunk_index,
               SUM(
                   ((LENGTH(c.lc) - LENGTH(REPLACE(c.lc, t.term, ''''))) / LENGTH(t.term))
                   * LN(1 + n.n / NULLIF(df.df, 0))
               ) AS score
        FROM cand c
        CROSS JOIN terms t
        JOIN df ON df.term = t.term
        CROSS JOIN n
        GROUP BY c.chunk_id, c.chunk, c.company, c.fiscal_year, c.relative_path, c.chunk_index
    )
    SELECT chunk, company, fiscal_year, relative_path, chunk_index, score
    FROM scored
    WHERE score > 0
    QUALIFY ROW_NUMBER() OVER (ORDER BY score DESC) <= k
';

SHOW FUNCTIONS LIKE 'SEARCH_CHUNKS' IN SCHEMA FILINGIQ_DB.PUBLIC;


/* =====================================================================
   SMOKE TESTS
   Pass NULL::STRING / NULL::NUMBER for a filter you don't want applied —
   an untyped NULL doesn't match the UDTF's declared signature, so the
   casts are required, not optional.
   ===================================================================== */

-- Unfiltered search across all companies/years.
SELECT *
FROM TABLE(
    SEARCH_CHUNKS('what were the primary drivers of revenue growth', NULL::STRING, NULL::NUMBER, 5)
)
ORDER BY score DESC;

-- Filtered search: only chunks where company = 'NVDA'.
SELECT *
FROM TABLE(
    SEARCH_CHUNKS('data center revenue growth', 'NVDA', NULL::NUMBER, 5)
)
ORDER BY score DESC;

-- Compound filter: one company AND a specific fiscal year.
SELECT *
FROM TABLE(
    SEARCH_CHUNKS('risk factors related to supply chain', 'NVDA', 2024, 5)
)
ORDER BY score DESC;
