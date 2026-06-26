"""
Attribution Studio -- Streamlit comparison UI.

Shows credit-by-channel for six attribution models side by side, so you can see
how each re-distributes the same conversions.

Data source: prefers the live dbt marts in Postgres (local dev); if no database is
reachable -- e.g. on Streamlit Community Cloud -- it falls back to the committed
CSV snapshots in dashboard/data/. When a live DB is present, the sidebar can
re-run the whole dbt + Markov pipeline with new config.

Run locally:  .venv/bin/streamlit run dashboard/app.py
"""

import os
import subprocess
from pathlib import Path

import pandas as pd
import plotly.express as px
import psycopg2
import streamlit as st

PROJECT = Path(__file__).resolve().parent.parent
DBT_DIR = PROJECT / "dbt"
DBT = str(PROJECT / ".venv" / "bin" / "dbt")
PY = str(PROJECT / ".venv" / "bin" / "python")
SNAP = Path(__file__).parent / "data"

# connection defaults match local Postgres.app; override via env vars for a hosted DB
DB = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": os.environ.get("PGPORT", "5432"),
    "dbname": os.environ.get("PGDATABASE", "attribution_studio"),
    "user": os.environ.get("PGUSER", os.environ.get("USER", "postgres")),
    "password": os.environ.get("PGPASSWORD", ""),
}

# stable display order + friendly names for the six models
MODELS = {
    "first_touch": "First-touch",
    "last_touch": "Last-touch",
    "linear": "Linear",
    "time_decay": "Time-decay",
    "position_based": "Position-based",
    "markov": "Markov",
}

JOURNEY_COLS = (
    "user_id, journey_id, event_seq_in_journey, event_timestamp, channel, "
    "event_type, conversion_type, is_touch, is_target_conversion, touch_seq, "
    "touches_in_journey, journey_converted"
)


@st.cache_data(ttl=300)
def fetch():
    """Return (credit_df, journeys_df, source_label, is_live)."""
    try:
        conn = psycopg2.connect(connect_timeout=3, **DB)
        tables = pd.read_sql(
            "select table_name from information_schema.tables "
            "where table_schema='analytics' and table_name like 'fct_%'", conn
        )["table_name"].tolist()
        credit = pd.concat(
            [pd.read_sql(
                f"select attribution_model, channel, attributed_conversions, "
                f"attributed_value from analytics.{t}", conn) for t in tables],
            ignore_index=True,
        )
        journeys = pd.read_sql(
            f"select {JOURNEY_COLS} from analytics.int_journeys order by "
            "user_id, event_timestamp", conn
        )
        conn.close()
        source, live = "Postgres (live dbt marts)", True
    except Exception:
        credit = pd.read_csv(SNAP / "credit_snapshot.csv")
        journeys = pd.read_csv(SNAP / "journeys_snapshot.csv")
        source, live = "CSV snapshot (committed marts)", False

    journeys["event_timestamp"] = pd.to_datetime(journeys["event_timestamp"])
    return credit, journeys, source, live


def rebuild(cfg):
    """Re-run dbt with the chosen vars, then the Markov script. Returns (ok, log)."""
    vars_str = "{" + ", ".join(f"{k}: {v}" for k, v in cfg.items()) + "}"
    dbt = subprocess.run([DBT, "run", "--vars", vars_str],
                         cwd=DBT_DIR, capture_output=True, text=True)
    if dbt.returncode != 0:
        return False, dbt.stdout + dbt.stderr
    mk = subprocess.run([PY, "src/markov_attribution.py"],
                        cwd=PROJECT, capture_output=True, text=True)
    if mk.returncode != 0:
        return False, mk.stdout + mk.stderr
    return True, "Rebuilt all six models."


# ---------------------------------------------------------------------------- UI
st.set_page_config(page_title="Attribution Studio", layout="wide")
st.title("Attribution Studio")
st.caption(
    "Compare six attribution models over the same conversions. "
    "Same journeys, six different verdicts on which channels earned the credit."
)

credit, journeys, source, is_live = fetch()
ctypes = sorted(journeys["conversion_type"].dropna().unique().tolist())

with st.sidebar:
    st.header("Configuration")
    st.caption(f"Data source: **{source}**")
    target = st.selectbox(
        "Attribute credit for", ["any"] + ctypes,
        index=(["any"] + ctypes).index("lead") if "lead" in ctypes else 0,
        help="Which funnel step counts as THE conversion. Earlier steps become "
             "neutral context; their touches credit this target instead.",
        disabled=not is_live,
    )
    lookback = st.number_input("Last-touch lookback (days)", 1, 365, 90, disabled=not is_live)
    half_life = st.number_input("Time-decay half-life (days)", 1, 180, 7, disabled=not is_live)
    first_w = st.slider("Position-based: first-touch weight", 0.0, 1.0, 0.4, 0.05, disabled=not is_live)
    last_w = st.slider("Position-based: last-touch weight", 0.0, 1.0, 0.4, 0.05, disabled=not is_live)

    if is_live:
        if st.button("Rebuild models", type="primary", use_container_width=True):
            cfg = {
                "target_conversion": target,
                "last_touch_lookback_days": lookback,
                "time_decay_half_life_days": half_life,
                "position_first_weight": first_w,
                "position_last_weight": last_w,
            }
            with st.spinner("Running dbt + Markov..."):
                ok, log = rebuild(cfg)
            if ok:
                fetch.clear()
                st.success(log)
                st.rerun()
            else:
                st.error("Build failed:")
                st.code(log)
    else:
        st.info("Config + rebuild need a local Postgres. This hosted demo shows a "
                "committed snapshot (target = lead).")

tab_compare, tab_journeys = st.tabs(["Model comparison", "Journey explorer"])

with tab_compare:
    present = [m for m in MODELS if m in set(credit["attribution_model"])]
    credit["Model"] = credit["attribution_model"].map(MODELS)

    total = credit.groupby("attribution_model")["attributed_conversions"].sum()
    c1, c2 = st.columns(2)
    c1.metric("Channels", credit["channel"].nunique())
    c2.metric("Conversions attributed (per model)", f"{total.iloc[0]:.0f}")

    st.subheader("Credit by channel")
    fig = px.bar(
        credit, x="channel", y="attributed_conversions", color="Model",
        barmode="group",
        category_orders={"Model": [MODELS[m] for m in present]},
        labels={"attributed_conversions": "Attributed conversions", "channel": "Channel"},
    )
    fig.update_layout(legend_title_text="", height=460)
    st.plotly_chart(fig, use_container_width=True)

    st.subheader("Side by side")
    pivot = (
        credit.pivot_table(index="channel", columns="attribution_model",
                           values="attributed_conversions", aggfunc="sum")
        .reindex(columns=present).rename(columns=MODELS).round(2)
        .sort_values(MODELS[present[0]], ascending=False)
    )
    st.dataframe(pivot, use_container_width=True)
    st.caption("Every model distributes the same total conversions — they just "
               "disagree on *which channel* earned each one.")

with tab_journeys:
    st.subheader("Journey explorer")
    st.caption("Inspect one customer's reconstructed journey.")
    users = sorted(journeys.loc[journeys["journey_converted"], "user_id"].unique())
    if users:
        u = st.selectbox("User", users)
        j = (journeys[journeys["user_id"] == u]
             .sort_values("event_timestamp")
             .drop(columns=["user_id"]))
        st.dataframe(j, use_container_width=True, hide_index=True)
    else:
        st.info("No converted journeys in the current data.")
