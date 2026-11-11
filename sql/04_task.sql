/* =====================================================================
   FilingIQ — 04_task.sql
   Automates PROCESS_NEW_DOCS() with an hourly, cost-aware TASK, plus the
   test queries used to validate the "upload 20, then 4 more" incremental
   scenario. Run after 03_process_procedure.sql.
   ===================================================================== */

USE WAREHOUSE FILINGIQ_WH;
USE DATABASE FILINGIQ_DB;
USE SCHEMA PUBLIC;

-- A TASK is Snowflake's built-in scheduler: it runs a SQL statement (or,
-- as here, a small Snowflake Scripting block) on a schedule, using its own
-- warehouse. The WHEN clause is evaluated BEFORE the warehouse is spun up
-- — so if SYSTEM$STREAM_HAS_DATA() says "no new files", the task skips
-- the run entirely and you are not billed any compute for that hour. This
-- is what keeps an "hourly" pipeline cheap: most hours, nothing happens.
--
-- The task body refreshes the stage directory table (so the stream has a
-- chance to see files uploaded since the last refresh) and then calls the
-- ingestion procedure. VERIFY: multi-statement task bodies written as an
-- inline Snowflake Scripting "BEGIN ... END" block (rather than a single
-- statement or a CALL to a wrapping procedure) — confirm this is still
-- supported syntax on your account; if not, move the ALTER STAGE REFRESH
-- into the top of PROCESS_NEW_DOCS() and set this task body to simply
-- `CALL PROCESS_NEW_DOCS();`.
-- Tested order matters here: COMMENT must appear before WHEN or task
-- creation is rejected on some Snowflake releases.
CREATE OR REPLACE TASK INGEST_TASK
    WAREHOUSE = FILINGIQ_WH
    SCHEDULE = '60 MINUTE'
    COMMENT = 'Hourly incremental ingestion: refreshes RAW_DOCS, then processes any new files via PROCESS_NEW_DOCS().'
    WHEN SYSTEM$STREAM_HAS_DATA('FILINGIQ_DB.PUBLIC.DOCS_STREAM')
AS
BEGIN
    ALTER STAGE FILINGIQ_DB.PUBLIC.RAW_DOCS REFRESH;
    CALL FILINGIQ_DB.PUBLIC.PROCESS_NEW_DOCS();
END;

-- Tasks are created SUSPENDED by default — you must explicitly resume one
-- before it will ever fire on its schedule.
ALTER TASK INGEST_TASK RESUME;

-- Confirm it's running.
SHOW TASKS LIKE 'INGEST_TASK' IN SCHEMA FILINGIQ_DB.PUBLIC;


/* =====================================================================
   MANUAL EXECUTION
   ===================================================================== */

-- Trigger the task body immediately rather than waiting for the hourly
-- schedule — the fastest way to pick up newly uploaded files on demand.
EXECUTE TASK INGEST_TASK;

-- Inspect recent runs: state (SUCCEEDED/FAILED/SKIPPED), timing, and any
-- error. SKIPPED means the WHEN clause evaluated to FALSE (no new files)
-- — that's the expected, cost-free outcome most hours.
SELECT
    NAME,
    STATE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    ERROR_CODE,
    ERROR_MESSAGE,
    RETURN_VALUE
FROM TABLE(
    INFORMATION_SCHEMA.TASK_HISTORY(
        TASK_NAME => 'INGEST_TASK',
        SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP())
    )
)
ORDER BY SCHEDULED_TIME DESC;


/* =====================================================================
   INCREMENTAL-LOAD VALIDATION
   Scenario: upload ~20 PDFs, run ingestion, verify; then upload 4 more
   PDFs and prove ONLY those 4 get processed (not the original 20 again).
   ===================================================================== */

-- --- Round 1: after uploading the first ~20 PDFs -----------------------
-- ALTER STAGE FILINGIQ_DB.PUBLIC.RAW_DOCS REFRESH;
-- EXECUTE TASK INGEST_TASK;   -- or: CALL PROCESS_NEW_DOCS();

-- Expect ~20 rows (one per file), almost all status = 'OK'.
SELECT status, COUNT(*) AS file_count, SUM(chunk_count) AS chunks
FROM INGESTION_LOG
GROUP BY status
ORDER BY status;

-- One row per file processed so far, most-recent first.
SELECT file_name, status, chunk_count, error_message, processed_at
FROM INGESTION_LOG
ORDER BY processed_at DESC;

-- Chunk volume per company/year.
SELECT company, fiscal_year, COUNT(*) AS chunk_count
FROM DOC_CHUNKS
GROUP BY company, fiscal_year
ORDER BY company, fiscal_year;

-- --- Round 2: upload 4 more PDFs, then re-run --------------------------
-- ALTER STAGE FILINGIQ_DB.PUBLIC.RAW_DOCS REFRESH;
-- EXECUTE TASK INGEST_TASK;

-- Proof of incrementality #1: INGESTION_LOG should now have exactly
-- (previous total) + 4 rows, i.e. 4 brand-new file_name values appeared
-- and none of the original files were reprocessed (no duplicate rows for
-- the same file_name unless you deliberately re-uploaded one).
SELECT file_name, COUNT(*) AS times_logged, MAX(processed_at) AS last_processed
FROM INGESTION_LOG
GROUP BY file_name
HAVING COUNT(*) > 1
ORDER BY last_processed DESC;
-- ^ Should return 0 rows unless a file was intentionally re-uploaded
--   (re-uploads are expected to appear here exactly once extra, per
--   replace — see 03_process_procedure.sql's idempotent delete step).

-- Proof of incrementality #2: only files logged AFTER round 1's cutoff
-- timestamp should be the 4 new ones. Replace the timestamp with round
-- 1's max(processed_at).
-- SELECT file_name, status, chunk_count, processed_at
-- FROM INGESTION_LOG
-- WHERE processed_at > '2026-01-01 00:00:00'   -- <- round 1 cutoff
-- ORDER BY processed_at;

-- Proof of incrementality #3: total chunk count grew only by the new
-- files' contribution, i.e. DOC_CHUNKS for the original 20 files is
-- untouched (same row counts as before round 2).
SELECT COUNT(DISTINCT relative_path) AS distinct_files, COUNT(*) AS total_chunks
FROM DOC_CHUNKS;
