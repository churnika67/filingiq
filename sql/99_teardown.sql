/* =====================================================================
   FilingIQ — 99_teardown.sql
   Drops every object this project created. Run this to fully tear down
   the project and stop all associated compute/storage billing.

   WARNING: destructive and irreversible. This deletes all ingested data,
   parsed text, chunks, logs, the search/parsing functions, and the
   database itself. Make sure you don't need any of it before running.
   ===================================================================== */

USE WAREHOUSE FILINGIQ_WH;

-- Suspend the task first so it can't fire mid-teardown.
ALTER TASK IF EXISTS FILINGIQ_DB.PUBLIC.INGEST_TASK SUSPEND;
DROP TASK IF EXISTS FILINGIQ_DB.PUBLIC.INGEST_TASK;

DROP FUNCTION IF EXISTS FILINGIQ_DB.PUBLIC.SEARCH_CHUNKS(STRING, STRING, NUMBER, NUMBER);

-- Drop the eval chunk-config tables too, if you ran the evaluation
-- notebook (eval/eval_notebook.ipynb).
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.DOC_CHUNKS_1000_200;
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.DOC_CHUNKS_1800_300;
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.DOC_CHUNKS_3000_500;

DROP STREAM IF EXISTS FILINGIQ_DB.PUBLIC.DOCS_STREAM;

DROP PROCEDURE IF EXISTS FILINGIQ_DB.PUBLIC.PROCESS_NEW_DOCS(NUMBER, NUMBER);
DROP FUNCTION IF EXISTS FILINGIQ_DB.PUBLIC.PDF_TO_TEXT(STRING);
DROP FUNCTION IF EXISTS FILINGIQ_DB.PUBLIC.CHUNK_TEXT(STRING, NUMBER, NUMBER);

DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.INGESTION_LOG;
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.DOC_CHUNKS;
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.PARSED_DOCS;
DROP TABLE IF EXISTS FILINGIQ_DB.PUBLIC.PENDING_FILES;

-- Dropping the stage deletes every uploaded PDF. Comment this out if you
-- want to keep the raw files for later re-use.
DROP STAGE IF EXISTS FILINGIQ_DB.PUBLIC.RAW_DOCS;

-- Dropping the database cascades to drop the PUBLIC schema and anything
-- left in it. Note: the Streamlit app (app/) and the eval notebook
-- (eval/) run locally on your machine, not inside Snowflake, so this
-- does NOT remove them — delete those folders yourself if you want them
-- gone too.
DROP DATABASE IF EXISTS FILINGIQ_DB;

-- Finally, the warehouse. Only drop this if you have no other Snowflake
-- project using FILINGIQ_WH.
DROP WAREHOUSE IF EXISTS FILINGIQ_WH;

-- Confirm everything is gone.
SHOW DATABASES LIKE 'FILINGIQ_DB';
SHOW WAREHOUSES LIKE 'FILINGIQ_WH';
