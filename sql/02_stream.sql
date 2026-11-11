/* =====================================================================
   FilingIQ — 02_stream.sql
   Creates the change-data-capture stream on the RAW_DOCS stage and shows
   how to inspect it. Run after 01_setup.sql.
   ===================================================================== */

USE WAREHOUSE FILINGIQ_WH;
USE DATABASE FILINGIQ_DB;
USE SCHEMA PUBLIC;

-- A STREAM is Snowflake's built-in change-data-capture object: it doesn't
-- store data itself, it stores an "offset" (a bookmark) against another
-- object and, when queried, returns only the rows that changed since that
-- offset. Streams on tables are common; a STREAM ON STAGE is the same idea
-- applied to a stage's directory table — it returns one row per file that
-- was added/removed/modified since the last time the stream was consumed,
-- with a METADATA$ACTION column of 'INSERT' (new/changed file) or 'DELETE'
-- (removed file).
--
-- Consuming a stream (reading it inside a DML statement, e.g. an INSERT
-- ... SELECT ... FROM stream, as PROCESS_NEW_DOCS() does) advances its
-- offset once that DML statement commits. Just SELECTing from it (as the
-- test query below does) does NOT advance the offset, so it's safe to
-- peek at the stream as many times as you like.
--
-- VERIFY: CREATE STREAM ... ON STAGE (streams on directory tables) is a
-- comparatively newer feature, unrelated to Cortex/AI Functions — it has
-- not shown the trial-account restrictions documented elsewhere in this
-- project. Confirm your account's Snowflake release still supports it
-- (Enterprise edition or higher is required for stream-on-stage in some
-- docs versions).
CREATE STREAM IF NOT EXISTS DOCS_STREAM ON STAGE RAW_DOCS
  COMMENT = 'CDC stream over RAW_DOCS directory table; detects newly uploaded/changed 10-K PDFs.';

-- Streams need at least one directory-table refresh to have anything to
-- report. If you haven't uploaded + refreshed yet, this will return 0 rows
-- — that's expected on a brand-new stage.
ALTER STAGE RAW_DOCS REFRESH;

-- Does the stream currently have unconsumed changes? TASK (04_task.sql)
-- uses this exact function in its WHEN clause so it only ever runs (and
-- bills compute) when there's actually new data to process.
SELECT SYSTEM$STREAM_HAS_DATA('DOCS_STREAM') AS has_new_files;

-- Peek at what the stream sees right now. Non-destructive: does not
-- advance the stream offset.
SELECT
    RELATIVE_PATH,
    SIZE,
    LAST_MODIFIED,
    METADATA$ACTION,
    METADATA$ISUPDATE
FROM DOCS_STREAM
ORDER BY LAST_MODIFIED DESC;

-- Only the "new or replaced file" rows — this is the exact filter
-- PROCESS_NEW_DOCS() uses to populate PENDING_FILES.
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DOCS_STREAM
WHERE METADATA$ACTION = 'INSERT'
ORDER BY LAST_MODIFIED DESC;

-- Sanity check against the directory table itself (all files currently in
-- the stage, independent of stream offset).
SELECT RELATIVE_PATH, SIZE, LAST_MODIFIED
FROM DIRECTORY(@RAW_DOCS)
ORDER BY LAST_MODIFIED DESC;
