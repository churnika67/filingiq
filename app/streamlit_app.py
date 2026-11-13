"""
FilingIQ — local Streamlit chat app (trial-account version).

Retrieval runs IN Snowflake (FILINGIQ_DB.PUBLIC.SEARCH_CHUNKS, a TF-IDF
keyword-search SQL table function — see sql/05_search_service.sql).
Answer generation runs on Groq's free tier.

WHY THIS APP RUNS LOCALLY (NOT AS STREAMLIT IN SNOWFLAKE): every Snowflake
AI/Cortex function (COMPLETE, AI_COMPLETE, Cortex Search's
EMBED_TEXT_768) returned "not available for trial accounts" errors when
tested against this project's trial account on 2026-11-11 (AI Functions
require a payment method on trial accounts). The pipeline's parsing and
chunking were reworked around that (see sql/03_process_procedure.sql's
PDF_TO_TEXT / CHUNK_TEXT UDFs), but there's no Snowflake-native
replacement for an LLM call itself — so answer generation uses Groq
(free, no card required) instead. Streamlit in Snowflake's sandboxed
runtime can't make arbitrary outbound HTTPS calls to Groq without extra
External Access Integration setup, so this app runs as a normal local
Streamlit app instead, using snowflake-connector-python to query
Snowflake and `requests` to call Groq.

Run:
    pip install -r requirements.txt
    cp .env.example .env      # fill in your values
    streamlit run streamlit_app.py
"""

import os
import re

import pandas as pd
import requests
import snowflake.connector
import streamlit as st
from dotenv import load_dotenv

load_dotenv()

# Local runs read config from .env (above). Streamlit Community Cloud has
# no .env file — it injects secrets via st.secrets (TOML) instead. Copy
# any of those into os.environ so the rest of this file (which reads
# os.getenv/os.environ everywhere) works unmodified on either host.
try:
    for _key, _value in st.secrets.items():
        os.environ.setdefault(_key, str(_value))
except Exception:
    pass  # no secrets.toml configured (e.g. local run with only .env) — fine

GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"
TOP_K_DEFAULT = int(os.getenv("FILINGIQ_TOP_K", "6"))
MAX_CONTEXT_CHARS = 12000  # keeps prompts well inside free-tier token limits

# Groq doesn't host Claude (that was the original model-picker brief,
# written when answer generation was going to run on Cortex COMPLETE).
# These two are both free-tier Groq models with different speed/quality
# tradeoffs, so the picker still demonstrates comparing models on the
# same retrieved context.
# Confirmed live on this account/key 2026-11-11 via GET
# https://api.groq.com/openai/v1/models — Groq's catalog shifted away
# from Llama models entirely since this project was first written.
# VERIFY: re-check https://console.groq.com/docs/models periodically,
# since Groq's hosted catalog changes.
GROQ_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"]

SYSTEM_PROMPT = (
    "You are FilingIQ, an analyst that answers questions about SEC 10-K filings. "
    "Answer ONLY from the numbered excerpts provided. Cite excerpts inline using the "
    "EXACT format [1] or [2] — a single number in plain square brackets, nothing else. "
    "Do NOT use any other citation style, such as special bracket/dagger markers "
    "(e.g. do not write something like a CJK-bracket-plus-dagger citation marker) — "
    "plain [n] only, every time. "
    "Quote exact figures (with units and fiscal year) when the excerpts contain them. "
    "If the excerpts do not contain the answer, reply exactly: Not found in the filings."
)

# Some Groq-hosted models (notably the openai/gpt-oss family) have their
# own built-in citation style baked in from training/post-training —
# e.g. "【2†L9-L13】" — that leaks through even when the system prompt asks
# for plain [n]. This is a defensive cleanup pass, not a fix at the
# source: it rewrites any such marker into the plain [n] format we
# actually want, falling back to just stripping the marker if no number
# is found inside it.
_CITATION_MARKER_RE = re.compile(r"【\s*(\d+)[^】]*】")


def normalize_citations(text: str) -> str:
    return _CITATION_MARKER_RE.sub(lambda m: f"[{m.group(1)}]", text)


# Streamlit's markdown renderer treats a PAIR of `$` as LaTeX math
# delimiters (KaTeX). 10-K answers routinely contain two or more dollar
# amounts ("$193.7 billion ... $115.2 billion"), so everything between
# the first and second `$` gets parsed as a math expression instead of
# plain text -- and inside LaTeX math mode, `%` starts a comment that
# eats the rest of the line, which is exactly what caused "68%year-over-
# year" to lose its space. Escaping every `$` to `\$` turns this off.
def escape_markdown_dollars(text: str) -> str:
    return text.replace("$", "\\$")


st.set_page_config(page_title="FilingIQ", page_icon="🗞️", layout="wide")

# --------------------------------------------------------------------------
# Theme — a warm, editorial "filing desk" look: cream paper background,
# a bold serif newspaper masthead, crimson rule lines, chat turns styled
# as clippings. A deliberate departure from the dark-tech-dashboard look
# most data apps default to, and one that fits the subject matter (SEC
# filings read like a financial newspaper's back pages).
# Paired with app/.streamlit/config.toml (base light/paper colors).
#
# VERIFY: this app's Streamlit version (1.67, confirmed via its own
# openapi.json banner) is newer than most published CSS-selector guides
# for Streamlit theming — internal data-testid attribute names can change
# between versions. Every selector below is additive CSS only (no logic
# depends on it), so if a selector stops matching in a future version,
# the affected element just falls back to Streamlit's default look rather
# than breaking anything.
st.markdown(
    """
    <style>
    @import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700;800;900&family=Source+Serif+4:opsz,wght@8..60,400;8..60,600&family=Inter:wght@400;500;600&display=swap');

    html, body, [class*="css"] { font-family: 'Source Serif 4', Georgia, 'Times New Roman', serif; }

    [data-testid="stAppViewContainer"] {
        background: #F7F1E3;
        background-image:
            repeating-linear-gradient(0deg, rgba(32,28,22,0.025) 0px, rgba(32,28,22,0.025) 1px, transparent 1px, transparent 26px);
    }

    .filingiq-kicker {
        font-family: 'Inter', sans-serif; font-size: 0.68rem; font-weight: 600;
        letter-spacing: 0.22em; text-transform: uppercase; color: #B23A2E; margin-bottom: 0.1rem;
    }
    .filingiq-masthead h1 {
        font-family: 'Playfair Display', Georgia, serif; font-weight: 900; font-size: 3.1rem;
        letter-spacing: -0.01em; color: #201C16; margin: 0.05rem 0 0.3rem 0; line-height: 1;
    }
    .filingiq-masthead { border-bottom: 4px double #201C16; padding-bottom: 0.5rem; }
    .filingiq-dateline {
        display: flex; justify-content: space-between; flex-wrap: wrap; gap: 0.4rem;
        font-family: 'Inter', sans-serif; font-size: 0.72rem; text-transform: uppercase;
        letter-spacing: 0.06em; color: #6B6354; margin: 0.45rem 0 1.4rem 0;
    }

    section[data-testid="stSidebar"], .stSidebar {
        background: #EFE6D3; border-right: 2px solid #201C16;
    }
    section[data-testid="stSidebar"] h1, section[data-testid="stSidebar"] h2,
    section[data-testid="stSidebar"] h3, section[data-testid="stSidebar"] .stMarkdown h3 {
        font-family: 'Inter', sans-serif; text-transform: uppercase; font-weight: 600;
        font-size: 0.74rem; letter-spacing: 0.14em; color: #B23A2E !important;
        border-bottom: 2px solid #201C16; padding-bottom: 0.35rem;
    }

    [data-testid="stChatMessage"], .stChatMessage {
        border-radius: 2px; border: 1px solid #201C16; margin-bottom: 0.75rem;
        background: #FFFCF5; box-shadow: 3px 3px 0 rgba(32,28,22,0.14);
    }

    [data-testid="stMetric"], .stMetric {
        background: #FFFCF5; border: 1px solid #201C16; border-left: 4px solid #B23A2E;
        border-radius: 2px; padding: 0.7rem 1rem 0.5rem 1rem;
    }
    [data-testid="stMetricValue"] { font-family: 'Playfair Display', serif; color: #201C16; }

    .stButton button, button[kind="secondary"] {
        border-radius: 2px !important; border: 2px solid #201C16 !important; color: #201C16 !important;
        background: #FFFCF5 !important; font-family: 'Inter', sans-serif !important;
        font-size: 0.76rem !important; font-weight: 600 !important;
        text-transform: uppercase; letter-spacing: 0.07em;
        box-shadow: 2px 2px 0 #201C16 !important;
    }
    .stButton button:hover, button[kind="secondary"]:hover {
        background: #B23A2E !important; color: #FFFCF5 !important; border-color: #201C16 !important;
    }

    button[data-baseweb="tab"], [data-testid="stTab"] {
        font-family: 'Inter', sans-serif !important; font-size: 0.78rem !important;
        text-transform: uppercase !important; letter-spacing: 0.08em !important;
    }

    details, .streamlit-expanderHeader {
        border: 1px solid #201C16 !important; border-radius: 2px !important; background: #FFFCF5 !important;
    }

    [data-testid="stDataFrame"] { border: 1px solid #201C16; border-radius: 2px; overflow: hidden; }
    </style>
    """,
    unsafe_allow_html=True,
)


# --------------------------------------------------------------------------
# Snowflake
# --------------------------------------------------------------------------
@st.cache_resource
def get_connection():
    params = dict(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.getenv("SNOWFLAKE_ROLE", "ACCOUNTADMIN"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "FILINGIQ_WH"),
        database="FILINGIQ_DB",
        schema="PUBLIC",
    )
    password = os.getenv("SNOWFLAKE_PASSWORD")
    if password:
        # A password or a Programmatic Access Token both go in this field.
        params["password"] = password
    else:
        # No secret stored locally: log in through the browser instead.
        params["authenticator"] = "externalbrowser"
    return snowflake.connector.connect(**params)


def run_query(sql: str, params=None) -> pd.DataFrame:
    cur = get_connection().cursor()
    try:
        cur.execute(sql, params)
        return cur.fetch_pandas_all()
    finally:
        cur.close()


@st.cache_data(ttl=300)
def get_filters() -> pd.DataFrame:
    return run_query(
        "SELECT DISTINCT company, fiscal_year FROM DOC_CHUNKS ORDER BY company, fiscal_year"
    )


# Same ticker/name mapping as SEARCH_CHUNKS' scoring exclusion (see
# sql/05_search_service.sql). Company names are excluded from TF-IDF
# scoring there (fixing an earlier bug where two different questions both
# mentioning "Apple"/"Microsoft" scored identical chunks), but that means
# a company name in the question carries NO weight at all when no
# sidebar filter is set — found live: "How did NVIDIA's data center
# revenue change?" with the filter on "All" pulled 4 of 6 excerpts from
# MSFT, because "revenue"/"change" are generic and "NVIDIA" was being
# ignored entirely. Fix: detect a company mention in the question here
# and apply it as a real filter — but ONLY when exactly one company is
# named, so a genuine comparison question ("Apple and Microsoft...")
# still searches across companies instead of being forced onto just one.
_COMPANY_ALIASES = {
    "AAPL": ["apple", "aapl"],
    "MSFT": ["microsoft", "msft"],
    "NVDA": ["nvidia", "nvda"],
    "GOOGL": ["google", "alphabet", "googl"],
    "AMZN": ["amazon", "amzn"],
    "META": ["meta", "facebook"],
    "TSLA": ["tesla", "tsla"],
    "JPM": ["jpmorgan", "jp morgan", "jpm"],
    "NFLX": ["netflix", "nflx"],
}


def detect_companies(text: str) -> list:
    text_lc = text.lower()
    matched = {
        ticker for ticker, aliases in _COMPANY_ALIASES.items()
        if any(re.search(rf"\b{re.escape(alias)}\b", text_lc) for alias in aliases)
    }
    return sorted(matched)


def detect_single_company(text: str):
    companies = detect_companies(text)
    return companies[0] if len(companies) == 1 else None


def retrieve(question: str, company, year, k: int) -> pd.DataFrame:
    # Casts are required: an untyped NULL doesn't match the UDTF signature.
    return run_query(
        """
        SELECT chunk, company, fiscal_year, relative_path, chunk_index, score
        FROM TABLE(SEARCH_CHUNKS(%s, %s::STRING, %s::NUMBER, %s))
        ORDER BY score DESC
        """,
        (question, company, year, k),
    )


def retrieve_multi_company(question: str, companies: list, year, k: int) -> pd.DataFrame:
    """TF-IDF scores all candidate chunks in one combined ranking, so an
    unfiltered comparison question ("Apple vs. Microsoft risk factors")
    can end up entirely filled with whichever single company's chunks
    happen to score highest overall — found live: a real test returned 6
    excerpts with none from Microsoft and 2 from NVIDIA, which wasn't
    even asked about. Fix: run one filtered search per named company and
    concatenate, so every mentioned company is guaranteed real
    representation instead of competing in one shared ranking."""
    per_company_k = max(2, k // len(companies))
    frames = [retrieve(question, c, year, per_company_k) for c in companies]
    non_empty = [f for f in frames if not f.empty]
    return pd.concat(non_empty, ignore_index=True) if non_empty else pd.DataFrame()


# --------------------------------------------------------------------------
# Generation (Groq)
# --------------------------------------------------------------------------
def groq_chat(model: str, system_prompt: str, user_prompt: str, temperature: float = 0.0) -> str:
    api_key = os.getenv("GROQ_API_KEY")
    if not api_key:
        return "GROQ_API_KEY is not set. Add it to your .env file."
    try:
        resp = requests.post(
            GROQ_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={
                "model": model,
                "temperature": temperature,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
            },
            timeout=60,
        )
    except requests.exceptions.RequestException as e:
        return f"Could not reach Groq ({e.__class__.__name__}). Check your network connection and try again."
    if resp.status_code == 429:
        # Groq's own error message says exactly which limit was hit (TPM,
        # RPM, or a daily cap) and the real wait time — surfacing it
        # directly instead of a hardcoded guess. Found live: a generic
        # "wait a minute" message was mistaken for a daily cap, when the
        # real cause was a per-model tokens-per-minute limit being
        # contended by a second process (the eval notebook) using the
        # same model at the same time.
        try:
            detail = resp.json()["error"]["message"]
        except Exception:
            detail = "Rate limit reached, but Groq didn't return details."
        return f"Groq rate limit hit on model `{model}`: {detail}"
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


def build_context(chunks: pd.DataFrame) -> str:
    parts, used = [], 0
    for i, row in enumerate(chunks.itertuples(index=False), start=1):
        block = f"[{i}] ({row.RELATIVE_PATH}, chunk {row.CHUNK_INDEX})\n{row.CHUNK}"
        if used + len(block) > MAX_CONTEXT_CHARS:
            break
        parts.append(block)
        used += len(block)
    return "\n\n".join(parts)


def get_recent_qa_pairs(history: list, n: int = 3):
    """Pair up consecutive user/assistant turns from the flat chat history,
    most recent n pairs, for follow-up query rewriting."""
    pairs = []
    i = 0
    while i < len(history) - 1:
        if history[i]["role"] == "user" and history[i + 1]["role"] == "assistant":
            pairs.append((history[i]["content"], history[i + 1]["content"]))
            i += 2
        else:
            i += 1
    return pairs[-n:]


def rewrite_standalone_query(history: list, latest_question: str, model: str) -> str:
    """Follow-up questions ("what about in 2023?") retrieve nothing useful
    on their own, since retrieval has no memory of the conversation. Use
    the LLM to fold the last 3 turns into a single self-contained query
    before searching."""
    pairs = get_recent_qa_pairs(history, n=3)
    if not pairs:
        return latest_question

    convo_text = "\n".join(f"User: {q}\nAssistant: {a}" for q, a in pairs)
    rewrite_prompt = f"""Given this recent conversation and a new question, decide
whether the new question needs rewriting.

Rules:
- If the new question is already self-contained (it doesn't rely on a
  pronoun, "it", "that", "what about", or an implicit company/year from
  the conversation to make sense), output it completely UNCHANGED,
  verbatim.
- Only if it genuinely depends on prior context, rewrite it into a single
  self-contained question that folds in ONLY the company names, fiscal
  years, or topics actually stated in the conversation or the question
  itself.
- NEVER add a fact (a year, a company, a figure) that was not explicitly
  stated in the conversation or the new question. If you are not sure a
  detail belongs, leave it out.
- Output ONLY the question text, nothing else — no preamble, no
  explanation, no quotes.

Conversation:
{convo_text}

New question: {latest_question}

Output:"""
    rewritten = groq_chat(model, "You rewrite questions to be self-contained, never inventing facts not already stated.", rewrite_prompt)
    rewritten = rewritten.strip().strip('"')
    # Defensive guard: if the model ignored instructions and produced
    # something wildly longer than the original (a sign it padded in
    # unrequested boilerplate/invented details), fall back to the
    # original question rather than risk degrading retrieval.
    if not rewritten or len(rewritten) > len(latest_question) * 3:
        return latest_question
    return rewritten


# --------------------------------------------------------------------------
# UI
# --------------------------------------------------------------------------
st.markdown(
    """
    <div class="filingiq-kicker">Automated Filing Desk &middot; Est. 2026</div>
    <div class="filingiq-masthead"><h1>FilingIQ</h1></div>
    <div class="filingiq-dateline">
        <span>10-K Intelligence, On Demand</span>
        <span>Retrieval: Snowflake TF-IDF &nbsp;&mdash;&nbsp; Analysis: Groq</span>
    </div>
    """,
    unsafe_allow_html=True,
)

filters = get_filters()
with st.sidebar:
    st.header("Filters")
    companies = ["All"] + sorted(filters["COMPANY"].unique().tolist())
    company = st.selectbox("Company", companies)
    years_df = filters if company == "All" else filters[filters["COMPANY"] == company]
    years = ["All"] + sorted(years_df["FISCAL_YEAR"].unique().tolist(), reverse=True)
    year = st.selectbox("Fiscal year", years)
    # Raising this doesn't reliably fix generic-keyword questions like
    # "main risk factors" — tested directly: at k=15 the same boilerplate
    # chunks (board risk-oversight language, cybersecurity disclaimers)
    # still outrank the actual Item 1A risk list, because they repeat the
    # word "risk" more densely. TF-IDF ranks by literal word frequency,
    # not relevance to intent — see README "Trial-account notes" / known
    # limitations. Exposed anyway since it sometimes helps on queries
    # with rarer, more specific terms.
    k = st.slider("Excerpts to retrieve", 3, 15, TOP_K_DEFAULT)
    model = st.selectbox("Model (Groq)", GROQ_MODELS)

    st.divider()
    if st.button("🗑️ Clear chat"):
        st.session_state.history = []
        st.rerun()

    st.divider()
    st.caption(
        "No data yet? Upload PDFs to the RAW_DOCS stage, run "
        "`ALTER STAGE RAW_DOCS REFRESH;` then `CALL PROCESS_NEW_DOCS();` "
        "in a worksheet (see RUNBOOK.md)."
    )

if "history" not in st.session_state:
    st.session_state.history = []

chat_tab, status_tab = st.tabs(["💬 Chat", "📊 Pipeline status"])

# IMPORTANT: st.chat_input is called here, OUTSIDE the `with chat_tab:`
# block, on purpose. When this widget is called from inside a tab (or any
# other container), some Streamlit versions don't pin it to the bottom of
# the page — it ends up floating mid-page below the tab content instead,
# which is confusing once a conversation has a few turns. Calling it at
# the script's top level keeps it docked to the bottom of the whole page
# regardless of which tab is active; we only *process* its value inside
# chat_tab below, so the actual conversation still renders in the right
# place.
question = st.chat_input("e.g. How did NVIDIA's data center revenue change?")

with chat_tab:
    for turn in st.session_state.history:
        with st.chat_message(turn["role"]):
            st.markdown(escape_markdown_dollars(turn["content"]))
            if turn.get("sources") is not None and not turn["sources"].empty:
                with st.expander("📎 Sources"):
                    st.dataframe(turn["sources"], hide_index=True, width="stretch")

    if question:
        st.session_state.history.append({"role": "user", "content": question, "sources": None})
        with st.chat_message("user"):
            st.markdown(escape_markdown_dollars(question))

        with st.chat_message("assistant"):
            with st.spinner("Rewriting query..."):
                standalone_query = rewrite_standalone_query(st.session_state.history[:-1], question, model)

            with st.spinner("Searching filings..."):
                year_filter = None if year == "All" else int(year)
                if company != "All":
                    chunks = retrieve(standalone_query, company, year_filter, k)
                else:
                    mentioned = detect_companies(question)
                    if len(mentioned) >= 2:
                        chunks = retrieve_multi_company(standalone_query, mentioned, year_filter, k)
                    elif len(mentioned) == 1:
                        chunks = retrieve(standalone_query, mentioned[0], year_filter, k)
                    else:
                        chunks = retrieve(standalone_query, None, year_filter, k)

            if chunks.empty:
                answer, sources = "Not found in the filings.", None
            else:
                with st.spinner("Writing answer..."):
                    answer = groq_chat(model, SYSTEM_PROMPT, f"Excerpts:\n\n{build_context(chunks)}\n\nQuestion: {question}")
                answer = normalize_citations(answer)
                sources = chunks[["RELATIVE_PATH", "CHUNK_INDEX", "SCORE"]].copy()
                # A short text preview lets you sanity-check *what the model
                # actually saw* without a separate SQL query — this is what
                # caught the retrieval-quality issue in the first place.
                sources.insert(1, "PREVIEW", chunks["CHUNK"].str.slice(0, 160) + "…")
                sources = sources.reset_index(drop=True)
                sources.index += 1

            st.markdown(escape_markdown_dollars(answer))
            if sources is not None:
                with st.expander("📎 Sources"):
                    st.dataframe(sources, width="stretch")

        st.session_state.history.append({"role": "assistant", "content": answer, "sources": sources})

with status_tab:
    st.subheader("Pipeline status")
    st.caption("Live view of INGESTION_LOG and DOC_CHUNKS.")

    log = run_query(
        """
        SELECT file_name, status, chunk_count, error_message, processed_at
        FROM INGESTION_LOG
        ORDER BY processed_at DESC
        """
    )

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Files ingested", log["FILE_NAME"].nunique() if not log.empty else 0)
    c2.metric("OK", int((log["STATUS"] == "OK").sum()) if not log.empty else 0)
    c3.metric("WARN", int((log["STATUS"] == "WARN").sum()) if not log.empty else 0)
    c4.metric("FAILED", int((log["STATUS"] == "FAILED").sum()) if not log.empty else 0)

    last_processed = log["PROCESSED_AT"].max() if not log.empty else None
    st.caption(f"Last processed: {last_processed if last_processed is not None else 'never'}")

    st.markdown("**Chunks per company**")
    chunks_by_company = run_query(
        "SELECT company, COUNT(*) AS chunk_count FROM DOC_CHUNKS GROUP BY company ORDER BY company"
    )
    if not chunks_by_company.empty:
        st.bar_chart(chunks_by_company.set_index("COMPANY"))
    else:
        st.info("No chunks yet.")

    st.markdown("**Ingestion log**")
    st.dataframe(log, hide_index=True, width="stretch")
