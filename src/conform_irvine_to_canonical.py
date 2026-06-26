"""
Conform the Irvine Apartments FTA event stream into the canonical schema.

This is the "map any source -> canonical" step: it reads the FTA project's
events.csv (Irvine-specific columns) and writes data/sample_irvine.csv in the
canonical event schema, so Attribution Studio's pipeline can read it like any
other upload. Irvine becomes the bundled demo dataset.

Canonical columns: user_id, event_timestamp, channel, campaign, event_type,
                   conversion_type, value, session_id

Run:  python3 src/conform_irvine_to_canonical.py
"""

import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
SRC = os.path.join(PROJECT, "..", "irvine-apartments-fta", "data", "events.csv")
OUT = os.path.join(PROJECT, "data", "sample_irvine.csv")

# --- event_type mapping: 7 Irvine types -> 4 canonical types --------------------
# browsing -> "session" (a touch); funnel completions -> "conversion".
SESSION_EVENTS = {"page_view", "property_view"}

# --- conversion_type mapping: which funnel step a conversion is -----------------
CONVERSION_TYPE = {
    "lead_submitted": "lead",
    "tour_scheduled": "tour",
    "tour_completed": "tour",
    "application_submitted": "application",
    "lease_signed": "lease",
}

CANONICAL_FIELDS = [
    "user_id", "event_timestamp", "channel", "campaign",
    "event_type", "conversion_type", "value", "session_id",
]


def to_canonical(row):
    irv_type = row["event_type"]
    if irv_type in SESSION_EVENTS:
        event_type = "session"
        conversion_type = ""
    else:
        event_type = "conversion"
        conversion_type = CONVERSION_TYPE.get(irv_type, "")

    return {
        "user_id": row["user_id"],
        "event_timestamp": row["event_ts"],
        "channel": row["channel_group"],     # use the rolled-up channel
        "campaign": row["campaign"],
        "event_type": event_type,
        "conversion_type": conversion_type,
        "value": "",                          # no revenue in the Irvine data
        "session_id": row["session_id"],
    }


with open(SRC) as f:
    rows = list(csv.DictReader(f))

with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=CANONICAL_FIELDS)
    w.writeheader()
    for r in rows:
        w.writerow(to_canonical(r))

# --- quick summary --------------------------------------------------------------
n = len(rows)
sessions = sum(1 for r in rows if r["event_type"] in SESSION_EVENTS)
conversions = n - sessions
print(f"wrote {n} canonical events -> data/sample_irvine.csv")
print(f"  sessions (touches): {sessions}")
print(f"  conversions:        {conversions}")
