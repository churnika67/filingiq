/* =====================================================================
   FilingIQ — 03_process_procedure.sql
   Defines the PDF-parsing and chunking UDFs, plus PROCESS_NEW_DOCS(): the
   heart of the pipeline. Consumes the stream, parses new PDFs, chunks
   them, deduplicates, logs, and cleans up — idempotently and with
   per-file error isolation.
   Run after 02_stream.sql.

   WHY NOT SNOWFLAKE.CORTEX.* HERE: this project originally used
   SNOWFLAKE.CORTEX.PARSE_DOCUMENT and
   SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER. On a brand-new trial
   account (tested 2026-11-11), every Cortex/AI function — both the
   legacy SNOWFLAKE.CORTEX.* family and the newer AI_* family
   (AI_PARSE_DOCUMENT, AI_COMPLETE, EMBED_TEXT_768) — returned errors like:
     "SNOWFLAKE.CORTEX.COMPLETE is not available on this account.
      New accounts are blocked from using legacy SNOWFLAKE.CORTEX
      functions. Please migrate to AI Functions and use AI_COMPLETE
      instead."
     "AI function _AI_PARSE_DOCUMENT is not available for trial accounts."
   AI Functions on trial accounts require a payment method on file. Since
   this project targets a no-payment-method trial account, parsing and
   chunking are reimplemented below as ordinary Snowflake Python UDFs
   (pypdf + hand-rolled recursive-character splitting) — no AI/Cortex
   functions, no external service, still runs entirely inside Snowflake.
   If your account *does* have AI Functions enabled, swapping PDF_TO_TEXT
   back to AI_PARSE_DOCUMENT / CHUNK_TEXT back to a Cortex splitter is a
   drop-in replacement — only the two function bodies below would change.
   ===================================================================== */

USE WAREHOUSE FILINGIQ_WH;
USE DATABASE FILINGIQ_DB;
USE SCHEMA PUBLIC;

-- A PYTHON UDF lets you run arbitrary Python (with a chosen set of
-- Anaconda packages) as a SQL function. SnowflakeFile is a small Snowpark
-- helper that opens a file sitting in a stage, given a URL built by
-- BUILD_SCOPED_FILE_URL — this is the standard pattern for Python UDFs
-- that need to process raw file bytes.
-- VERIFY: `pypdf` package availability/version in the Snowflake Anaconda
-- channel for your account. If it's missing, run
-- `SELECT * FROM INFORMATION_SCHEMA.PACKAGES WHERE PACKAGE_NAME ILIKE '%pdf%';`
-- to see what's available and adjust the PACKAGES clause (e.g. 'PyPDF2').
CREATE OR REPLACE FUNCTION PDF_TO_TEXT(file_url STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
HANDLER = 'extract_text'
PACKAGES = ('pypdf', 'snowflake-snowpark-python')
COMMENT = 'Extracts plain text from a PDF sitting in a stage, given a scoped file URL. Replaces SNOWFLAKE.CORTEX.PARSE_DOCUMENT (blocked on trial accounts).'
AS
$$
import io
import re
from snowflake.snowpark.files import SnowflakeFile
from pypdf import PdfReader

# Found by live-testing: one page of a real NVDA 10-K extracted as
# "GULYHQ E\\ JURZWK LQ UHYHQXH" — every Latin letter shifted +3
# (Caesar-cipher style), confirmed to come from the PDF's own embedded
# font (PyMuPDF reproduces the identical shift, so it isn't a pypdf-only
# bug — the font's content-stream codes are genuinely offset). That same
# page also uses a control character (0x01) as its word separator
# instead of a real space. This block normalizes separators, then tries
# small un-shifts and keeps whichever one (if any) produces a dramatically
# more English-like result, so it only fires on pages that are actually
# broken this way — verified directly: 1 of 175 NVDA pages affected, 0 of
# 362 pages across the other 3 filings in this corpus false-triggered.
# LIMITATION: this specific page also has a second, more severely broken
# encoding for its numeric financial table (different control-character
# substitutions for digits), which this heuristic does not attempt to
# recover — only the narrative paragraph text on that page is restored.
_COMMON_WORDS = frozenset(
    "the and for with from this that was were has have our we is are "
    "revenue income expenses total increase decrease segment fiscal year "
    "quarter billion million company net sales cost operating margin "
    "compared primarily driven growth which were december march june "
    "september other including items results financial statements".split()
)


def _normalize_separators(text: str) -> str:
    text = text.replace('\x01', ' ')
    return re.sub(r'[\x00-\x08\x0b\x0e-\x1f]', '', text)


def _shift_letters(text: str, n: int) -> str:
    out = []
    for ch in text:
        if 'A' <= ch <= 'Z':
            out.append(chr((ord(ch) - ord('A') - n) % 26 + ord('A')))
        elif 'a' <= ch <= 'z':
            out.append(chr((ord(ch) - ord('a') - n) % 26 + ord('a')))
        else:
            out.append(ch)
    return ''.join(out)


def _word_score(text: str) -> int:
    words = [w.strip('.,();:%$').lower() for w in text.split()]
    return sum(1 for w in words if w in _COMMON_WORDS)


def _repair_page_if_garbled(text: str) -> str:
    text = _normalize_separators(text)
    base_score = _word_score(text)
    best_shift, best_score = 0, base_score
    for n in range(1, 13):
        candidate = _shift_letters(text, n)
        score = _word_score(candidate)
        if score > best_score:
            best_shift, best_score = n, score
    if best_shift and best_score >= 5 and best_score > base_score * 3:
        return _shift_letters(text, best_shift)
    return text


def extract_text(file_url: str) -> str:
    with SnowflakeFile.open(file_url, 'rb') as f:
        raw_bytes = f.read()
    reader = PdfReader(io.BytesIO(raw_bytes))
    pages = []
    for page in reader.pages:
        pages.append(_repair_page_if_garbled(page.extract_text() or ''))
    return "\n\n".join(pages)
$$;

-- A hand-rolled recursive-character text splitter: tries to break on
-- paragraph boundaries first, falling back to sentence boundaries, then
-- hard character windows, so chunks rarely cut mid-sentence. Overlap
-- carries the tail of one chunk into the start of the next so a fact
-- split across a chunk boundary still appears whole in at least one
-- chunk. Pure standard library (no extra PACKAGES needed) — replaces
-- SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER (blocked on trial
-- accounts).
CREATE OR REPLACE FUNCTION CHUNK_TEXT(input_text STRING, chunk_size NUMBER, chunk_overlap NUMBER)
RETURNS ARRAY
LANGUAGE PYTHON
RUNTIME_VERSION = '3.10'
HANDLER = 'chunk'
COMMENT = 'Recursive-character text splitter with overlap. Replaces SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER (blocked on trial accounts).'
AS
$$
import re

def _split_into_paragraphs(text, target_size):
    paragraphs = re.split(r'(\n\s*\n)', text)
    pieces, buf = [], ""
    for part in paragraphs:
        buf += part
        if len(buf) >= target_size:
            pieces.append(buf)
            buf = ""
    if buf:
        pieces.append(buf)
    return pieces

def _split_oversized(piece, chunk_size):
    if len(piece) <= chunk_size * 1.5:
        return [piece]
    sentences = re.split(r'(?<=[.!?])\s+', piece)
    out, cur = [], ""
    for sentence in sentences:
        if cur and len(cur) + len(sentence) > chunk_size:
            out.append(cur)
            cur = sentence
        else:
            cur = (cur + " " + sentence).strip() if cur else sentence
    if cur:
        out.append(cur)
    # Last resort: a "sentence" that's itself longer than chunk_size (no
    # punctuation at all) gets hard-wrapped by character count.
    final = []
    for o in out:
        if len(o) > chunk_size * 2:
            for i in range(0, len(o), chunk_size):
                final.append(o[i:i + chunk_size])
        else:
            final.append(o)
    return final

def chunk(input_text: str, chunk_size: int, chunk_overlap: int):
    if not input_text or not input_text.strip():
        return []

    rough_pieces = _split_into_paragraphs(input_text, chunk_size)
    fine_pieces = []
    for piece in rough_pieces:
        fine_pieces.extend(_split_oversized(piece, chunk_size))

    # Merge small pieces up to chunk_size, carrying `chunk_overlap`
    # trailing characters of the previous chunk forward as a prefix.
    chunks, acc = [], ""
    for piece in fine_pieces:
        if not acc or len(acc) + len(piece) <= chunk_size:
            acc = (acc + piece) if acc else piece
        else:
            chunks.append(acc)
            tail = acc[-chunk_overlap:] if chunk_overlap > 0 else ""
            if tail:
                # A raw character slice almost always starts mid-word
                # ("...tters 47" from "Matters 47"). Drop everything up
                # to and including the first whitespace in the slice so
                # the carried-over overlap starts at a clean word
                # boundary instead.
                first_space = tail.find(" ")
                tail = tail[first_space + 1:] if first_space != -1 else ""
            acc = (tail + " " + piece) if tail else piece
    if acc:
        chunks.append(acc)

    return [c.strip() for c in chunks if c.strip()]
$$;


-- A STORED PROCEDURE in Snowflake Scripting (the "AS $$ ... $$" / BEGIN...END
-- block below) is like a SQL-native script: it lets you DECLARE variables,
-- loop over query results, and branch with IF statements — things plain
-- SQL can't do — while still calling ordinary SQL statements and the UDFs
-- above inline.
CREATE OR REPLACE PROCEDURE PROCESS_NEW_DOCS(
    CHUNK_SIZE    NUMBER DEFAULT 1800,
    CHUNK_OVERLAP NUMBER DEFAULT 300
)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Idempotently ingests all files currently sitting in DOCS_STREAM: parse -> chunk -> dedupe -> log.'
EXECUTE AS CALLER
AS
$$
DECLARE
    files_processed  NUMBER   DEFAULT 0;
    ok_count         NUMBER   DEFAULT 0;
    warn_count       NUMBER   DEFAULT 0;
    failed_count     NUMBER   DEFAULT 0;
    total_chunks     NUMBER   DEFAULT 0;

    v_relative_path  STRING;
    v_file_name      STRING;
    v_company        STRING;
    v_fiscal_year    NUMBER;
    v_file_url       STRING;
    v_parsed_text    STRING;
    v_chunk_count    NUMBER;

    -- A user-defined EXCEPTION lets us RAISE a custom, catchable error
    -- (e.g. "parsed text came back empty") and handle it with the exact
    -- same per-file EXCEPTION block that catches genuine UDF/SQL errors,
    -- so both paths end up writing one clean INGESTION_LOG row.
    empty_parse_exception EXCEPTION (-20001, 'Parsed text is empty.');

    -- Snowflake Scripting's FOR loop can iterate a query directly, but
    -- some accounts/releases require an explicitly DECLAREd CURSOR bound
    -- to the query instead of an inline SELECT in the FOR clause --
    -- that's what this is. `FOR file_record IN files_cursor DO ... END FOR;`
    -- below opens/fetches/closes it automatically.
    files_cursor CURSOR FOR SELECT relative_path, file_url FROM PENDING_FILES;
BEGIN
    -- STEP 1: consume the stream into PENDING_FILES in a single DML
    -- statement. This INSERT is what advances the stream's offset once it
    -- commits — so every file the stream currently reports as new/changed
    -- gets captured here exactly once, even if the procedure later fails
    -- partway through a given file. The explicit ::TIMESTAMP_NTZ cast
    -- avoids a type-mismatch error against DOCS_STREAM's LAST_MODIFIED
    -- column (which can come back as TIMESTAMP_TZ).
    INSERT INTO PENDING_FILES (relative_path, file_url, size, last_modified)
    SELECT
        RELATIVE_PATH,
        BUILD_SCOPED_FILE_URL(@RAW_DOCS, RELATIVE_PATH),
        SIZE,
        LAST_MODIFIED::TIMESTAMP_NTZ
    FROM DOCS_STREAM
    WHERE METADATA$ACTION = 'INSERT';

    -- STEP 2: idempotent reprocessing. If any of these paths were already
    -- parsed/chunked in a previous run (i.e. the file was re-uploaded),
    -- wipe out the old rows first so re-ingestion REPLACES rather than
    -- duplicates. Doing this once, in bulk, before the per-file loop is
    -- both simpler and cheaper than per-file deletes.
    DELETE FROM DOC_CHUNKS
    WHERE relative_path IN (SELECT relative_path FROM PENDING_FILES);

    DELETE FROM PARSED_DOCS
    WHERE relative_path IN (SELECT relative_path FROM PENDING_FILES);

    -- STEP 3: process each pending file one at a time so that a single
    -- corrupt/unparseable PDF can't abort the whole batch.
    FOR file_record IN files_cursor DO
        files_processed := files_processed + 1;
        v_relative_path := file_record.relative_path;
        v_file_url      := file_record.file_url;

        -- Nesting a BEGIN...EXCEPTION...END block *inside* the FOR loop
        -- body is what gives us per-file error isolation: if this block
        -- raises, only this iteration's EXCEPTION handler fires and the
        -- FOR loop moves on to the next file.
        BEGIN
            -- Filenames follow TICKER_YEAR_10K.pdf. Strip any folder
            -- prefix first (in case files were uploaded into a
            -- subdirectory of the stage) before splitting on '_'.
            v_file_name   := SPLIT_PART(v_relative_path, '/', -1);
            v_company     := SPLIT_PART(v_file_name, '_', 1);
            v_fiscal_year := TRY_TO_NUMBER(SPLIT_PART(v_file_name, '_', 2));

            -- PDF_TO_TEXT (defined above) extracts raw text from the PDF
            -- sitting at this scoped file URL.
            INSERT INTO PARSED_DOCS (relative_path, company, fiscal_year, file_url, parsed_text)
            SELECT
                :v_relative_path,
                :v_company,
                :v_fiscal_year,
                :v_file_url,
                PDF_TO_TEXT(:v_file_url);

            SELECT parsed_text INTO :v_parsed_text
            FROM PARSED_DOCS
            WHERE relative_path = :v_relative_path;

            -- Data-quality check #1: empty parse result -> FAILED.
            IF (v_parsed_text IS NULL OR LENGTH(TRIM(v_parsed_text)) = 0) THEN
                RAISE empty_parse_exception;
            END IF;

            -- CHUNK_TEXT (defined above) splits the parsed text into
            -- overlapping chunks. FLATTEN() turns the returned ARRAY into
            -- one row per element so we can INSERT each chunk as its own
            -- row, with FLATTEN's INDEX column preserving chunk order.
            --
            -- Data-quality check #2 (dedup): two 10-K pages sometimes
            -- produce byte-identical boilerplate chunks (e.g. repeated
            -- headers/footers that survived parsing). QUALIFY + SHA2 keeps
            -- only the first occurrence of each distinct chunk per file.
            INSERT INTO DOC_CHUNKS (relative_path, company, fiscal_year, file_url, chunk_index, chunk, chunk_hash)
            SELECT
                :v_relative_path,
                :v_company,
                :v_fiscal_year,
                :v_file_url,
                chunk_index,
                chunk_text,
                SHA2(chunk_text)
            FROM (
                SELECT
                    f.index                                   AS chunk_index,
                    :v_file_name || ': ' || f.value::STRING    AS chunk_text
                FROM TABLE(
                    FLATTEN(
                        INPUT => CHUNK_TEXT(:v_parsed_text, :CHUNK_SIZE, :CHUNK_OVERLAP)
                    )
                ) f
            )
            QUALIFY ROW_NUMBER() OVER (PARTITION BY SHA2(chunk_text) ORDER BY chunk_index) = 1;

            SELECT COUNT(*) INTO :v_chunk_count
            FROM DOC_CHUNKS
            WHERE relative_path = :v_relative_path;

            total_chunks := total_chunks + v_chunk_count;

            -- Data-quality check #3: suspiciously few chunks (e.g. a
            -- mostly-scanned-image 10-K that PDF_TO_TEXT barely extracted
            -- text from) -> WARN, not FAILED, since we did get *some*
            -- usable content.
            IF (v_chunk_count < 5) THEN
                warn_count := warn_count + 1;
                INSERT INTO INGESTION_LOG (file_name, status, chunk_count, error_message)
                VALUES (:v_file_name, 'WARN', :v_chunk_count, 'Fewer than 5 chunks produced; parsing may be incomplete.');
            ELSE
                ok_count := ok_count + 1;
                INSERT INTO INGESTION_LOG (file_name, status, chunk_count, error_message)
                VALUES (:v_file_name, 'OK', :v_chunk_count, NULL);
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                -- Catches both our own RAISE'd empty_parse_exception and
                -- any genuine error (e.g. PDF_TO_TEXT choking on a
                -- malformed/encrypted PDF). SQLERRM is a built-in
                -- Snowflake Scripting variable holding the message of
                -- whatever error triggered this handler.
                failed_count := failed_count + 1;
                INSERT INTO INGESTION_LOG (file_name, status, chunk_count, error_message)
                VALUES (:v_file_name, 'FAILED', 0, :SQLERRM);
        END;
    END FOR;

    -- STEP 4: clear the scratch table so the next run starts clean.
    DELETE FROM PENDING_FILES;

    RETURN 'Processed ' || files_processed || ' file(s): '
        || ok_count || ' OK, ' || warn_count || ' WARN, ' || failed_count || ' FAILED. '
        || 'Total chunks written: ' || total_chunks || '.';
END;
$$;

-- Manual smoke test (run this any time after uploading + refreshing files):
-- CALL PROCESS_NEW_DOCS();                    -- uses default 1800/300 chunking
-- CALL PROCESS_NEW_DOCS(1000, 200);            -- custom chunk size/overlap
