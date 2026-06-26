# Attribution Studio

A self-serve, **multi-model marketing attribution** tool. Upload a marketing-events
CSV and instantly compare **First-Touch / Last-Touch / Linear / Time-Decay /
Position-Based / Markov (data-driven)** attribution — with configurable credit rules —
powered by a real **dbt + Postgres** pipeline behind a **Streamlit** app.

> Evolves the single-dataset First-Touch dashboard into a generalized tool: any CSV in
> the canonical schema works; Irvine Apartments ships as the bundled demo dataset.

## How it works (per-upload, ephemeral)

```
CSV upload → validate against canonical schema → load to Postgres (per-upload schema)
   → dbt build (attribution marts) → Streamlit reads marts → schema dropped (TTL)
```

The **canonical schema** is the contract: any upload is validated to match it, then the
dbt models — written once against that shape — produce every attribution model.
See `sql/01_canonical_schema.sql`.

## Attribution models

| Model | User config |
|---|---|
| First-touch | conversion window(s) |
| Last-touch | lookback window |
| Linear | — (even split) |
| Time-decay | half-life (days) |
| Position-based | first/last weights (default 40/20/40) |
| Markov (data-driven) | conversion definition |

Rule-based models are dbt SQL; **Markov runs in Python** (the Postgres dbt adapter
doesn't support Python models) reading from the prepared journey marts.

## Build scope

**Tier 1 — the demoable MVP (build first):**
1. Generalize dbt models to the canonical schema (Irvine = bundled demo)
2. CSV upload + validation + template/sample download
3. All 6 attribution models (5 in dbt SQL, Markov in Python)
4. Config UI + side-by-side model comparison (credit by channel, conversions, journey explorer)
5. Simple per-upload schema lifecycle (load → build → drop)

**Tier 2 — production hardening (build OR document as design):**
- Concurrency queue/worker, TTL cleanup jobs, upload size caps, hardened security
- (Documented design counts: shows you understand the ops without over-building the demo)

## Stack
PostgreSQL · dbt-core · Streamlit · Python. Same stack as the FTA project, generalized.

## Run locally

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
# load the bundled Irvine demo into Postgres (db: attribution_studio, schema: attribution_demo),
# then build the marts:
cd dbt && ../.venv/bin/dbt run            # staging -> int_journeys -> 5 rule-based marts
cd .. && .venv/bin/python src/markov_attribution.py   # 6th model (Markov)
.venv/bin/streamlit run dashboard/app.py  # http://localhost:8501
```

Attribution config is set with dbt vars (overridable from the app):
`target_conversion` (default `lead`), `last_touch_lookback_days` (90),
`time_decay_half_life_days` (7), `position_first_weight` / `position_last_weight` (0.4).

## Deploy (Streamlit Community Cloud)

The dashboard prefers the live Postgres marts, but **falls back to the committed CSV
snapshots in `dashboard/data/`** when no database is reachable — so it runs on
Streamlit Cloud with zero infrastructure. Point a new app at this repo with main file
`dashboard/app.py`; Cloud installs `requirements.txt` (runtime only, no dbt). To refresh
the hosted demo, rebuild locally and re-commit the snapshot CSVs.

## Status
✅ Engine complete — canonical schema, dbt pipeline (staging → journeys → 6 attribution
marts), Markov, and the Streamlit comparison/journey-explorer UI all working on the
Irvine demo. Next: in-app CSV upload + validation and per-upload schema lifecycle.
