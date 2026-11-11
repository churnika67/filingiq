/* =====================================================================
   FilingIQ — 01_setup.sql
   Creates the database, warehouse, stage, and core tables.
   Run this entire script top-to-bottom in a Snowsight SQL worksheet.
   Idempotent: safe to re-run (uses CREATE OR REPLACE / IF NOT EXISTS).
   ===================================================================== */

-- A WAREHOUSE is Snowflake's compute layer: a cluster of virtual machines
-- that you pay for only while it's running. AUTO_SUSPEND=60 means it shuts
-- itself off 60 seconds after the last query finishes, and AUTO_RESUME=TRUE
-- means it wakes itself back up the instant a new query arrives — so you
-- are billed only for the seconds you actually compute on. X-Small is the
-- smallest/cheapest size, more than enough for this project's volume.
CREATE WAREHOUSE IF NOT EXISTS FILINGIQ_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Single X-Small warehouse for all FilingIQ compute (ingestion, search, app, eval).';

-- A DATABASE + SCHEMA is Snowflake's namespace hierarchy: DATABASE.SCHEMA.OBJECT.
-- Every table, stage, task, etc. below lives under FILINGIQ_DB.PUBLIC.
CREATE DATABASE IF NOT EXISTS FILINGIQ_DB
  COMMENT = 'FilingIQ: incremental 10-K ingestion pipeline + RAG chatbot.';

CREATE SCHEMA IF NOT EXISTS FILINGIQ_DB.PUBLIC
  COMMENT = 'Default schema holding all FilingIQ pipeline objects.';

USE WAREHOUSE FILINGIQ_WH;
USE DATABASE FILINGIQ_DB;
USE SCHEMA PUBLIC;

-- A STAGE is Snowflake's abstraction over a file storage location. An
-- "internal" stage (the default kind, as opposed to an "external" stage
-- pointing at an S3/Azure/GCS bucket you own) stores files directly inside
-- Snowflake, encrypted at rest. DIRECTORY = (ENABLE = TRUE) turns on a
-- DIRECTORY TABLE: Snowflake automatically maintains a queryable metadata
-- table (RELATIVE_PATH, SIZE, LAST_MODIFIED, FILE_URL, etc.) listing every
-- file currently sitting in the stage. That directory table is what lets a
-- STREAM (see 02_stream.sql) detect newly uploaded files.
-- ENCRYPTION = SNOWFLAKE_SSE is Snowflake-managed server-side encryption —
-- the default and simplest option for an internal stage (no customer-
-- managed keys required, unlike SNOWFLAKE_FULL which also supports
-- client-side encryption).
CREATE STAGE IF NOT EXISTS RAW_DOCS
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Landing zone for raw 10-K PDFs. Filename convention: TICKER_YEAR_10K.pdf';

-- -----------------------------------------------------------------------
-- HOW TO UPLOAD PDFS (no SnowSQL/CLI required):
--   1. In Snowsight, go to Data > Databases > FILINGIQ_DB > PUBLIC > Stages > RAW_DOCS
--   2. Click "+ Files" (top right) and upload your TICKER_YEAR_10K.pdf files
--      (e.g. NVDA_2024_10K.pdf, AAPL_2023_10K.pdf, ...)
--   3. IMPORTANT: uploading through Snowsight does NOT automatically refresh
--      the directory table / stream metadata. After every upload batch, run:
--
--        ALTER STAGE FILINGIQ_DB.PUBLIC.RAW_DOCS REFRESH;
--
--      This tells Snowflake to re-scan the stage and record any new/changed
--      files in the directory table, which is what feeds DOCS_STREAM. The
--      hourly TASK (04_task.sql) does this refresh for you automatically,
--      but refresh manually any time you want ingestion to pick up files
--      immediately instead of waiting for the next scheduled run.
-- -----------------------------------------------------------------------

-- PENDING_FILES: scratch table that briefly holds the batch of newly
-- detected files for the current run of PROCESS_NEW_DOCS(). Cleared at the
-- end of every run.
CREATE TABLE IF NOT EXISTS PENDING_FILES (
    relative_path   STRING        NOT NULL,   -- path of the file within the stage, e.g. 'NVDA_2024_10K.pdf'
    file_url        STRING,                    -- scoped URL built via BUILD_SCOPED_FILE_URL
    size            NUMBER,
    last_modified   TIMESTAMP_NTZ,
    loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Scratch/staging table: new files captured from DOCS_STREAM for the current ingestion run.';

-- PARSED_DOCS: one row per source PDF holding the full extracted text
-- (via the PDF_TO_TEXT UDF, see sql/03_process_procedure.sql) before
-- chunking. Useful for debugging/auditing parse quality independent of
-- chunking.
CREATE TABLE IF NOT EXISTS PARSED_DOCS (
    relative_path   STRING        NOT NULL,
    company         STRING,
    fiscal_year     NUMBER,
    file_url        STRING,
    parsed_text     STRING,                    -- full text returned by PDF_TO_TEXT
    parsed_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (relative_path)
)
COMMENT = 'Full parsed text per source PDF (via PDF_TO_TEXT), before chunking.';

-- DOC_CHUNKS: the table that actually feeds SEARCH_CHUNKS (sql/05_search_service.sql).
-- One row per text chunk, tagged with the attributes we filter/search on.
CREATE TABLE IF NOT EXISTS DOC_CHUNKS (
    chunk_id        STRING        DEFAULT UUID_STRING(),
    relative_path   STRING        NOT NULL,
    company         STRING        NOT NULL,
    fiscal_year     NUMBER        NOT NULL,
    file_url        STRING,
    chunk_index     NUMBER,
    chunk           STRING        NOT NULL,    -- filename-prefixed chunk text (the searchable column)
    chunk_hash       STRING        NOT NULL,    -- SHA2(chunk), used to dedupe
    created_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (chunk_id)
)
COMMENT = 'Chunked 10-K text. Backing table for the SEARCH_CHUNKS TF-IDF search function.';

-- INGESTION_LOG: the pipeline's audit trail / monitoring table. One row
-- per file per processing attempt. This is what the Streamlit "Pipeline
-- status" tab and RUNBOOK verification queries read from.
CREATE TABLE IF NOT EXISTS INGESTION_LOG (
    log_id          NUMBER        AUTOINCREMENT START 1 INCREMENT 1,
    file_name       STRING        NOT NULL,
    status          STRING        NOT NULL,     -- 'OK' | 'WARN' | 'FAILED'
    chunk_count     NUMBER        DEFAULT 0,
    error_message   STRING,
    processed_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (log_id)
)
COMMENT = 'Audit/monitoring log: one row per file per ingestion attempt.';

-- Quick sanity check: objects should all exist now.
SHOW TABLES IN SCHEMA FILINGIQ_DB.PUBLIC;
SHOW STAGES IN SCHEMA FILINGIQ_DB.PUBLIC;
SHOW WAREHOUSES LIKE 'FILINGIQ_WH';
