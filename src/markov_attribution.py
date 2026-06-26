"""
Markov (data-driven) attribution for Attribution Studio.

The five rule-based models are fixed formulas. Markov instead LEARNS each channel's
importance from the journey patterns, via the "removal effect":

  1. Treat every journey as a path of channels:
         start -> ILS -> Organic -> Email -> (conversion | null)
     Converted journeys end in the absorbing state 'conversion'; abandoned ones
     end in 'null'. Consecutive duplicate channels are collapsed (a self-loop
     doesn't change absorption probability, so this only cleans up the graph).
  2. Build the transition-probability matrix between channel states.
  3. Base conversion probability = P(reach 'conversion' from 'start').
  4. Removal effect of channel c = how much that probability DROPS when c is
     removed (its paths can no longer convert). A channel whose removal collapses
     many conversion paths is important.
  5. Each channel's credit = its removal effect, normalized across channels, times
     the total number of converted journeys.

Unlike the dbt marts, this is run as a script because dbt-postgres has no Python
models. It reads analytics.int_journeys (whatever target_conversion was last
built) and writes analytics.fct_markov in the same schema, with the same columns
as the other fct_* marts so the app can union all six.

Run:  .venv/bin/python src/markov_attribution.py
"""

from collections import defaultdict

import numpy as np
import psycopg2

DB = dict(host="localhost", dbname="attribution_studio", user="avanthijandhyala")


def load_journeys(cur):
    """Return {journey_id: {converted, value, channels[]}} from int_journeys."""
    cur.execute(
        """
        SELECT journey_id, journey_converted, coalesce(conversion_value, 0),
               channel, touch_seq
        FROM analytics.int_journeys
        WHERE is_touch
        ORDER BY journey_id, touch_seq
        """
    )
    journeys = {}
    for jid, converted, value, channel, _seq in cur.fetchall():
        j = journeys.setdefault(
            jid, {"converted": converted, "value": float(value), "channels": []}
        )
        # collapse consecutive duplicate channels (ILS, ILS -> ILS)
        if not j["channels"] or j["channels"][-1] != channel:
            j["channels"].append(channel)
    return journeys


def build_transitions(journeys):
    """Channel transition counts + the set of channels + conversion totals."""
    trans = defaultdict(lambda: defaultdict(float))
    channels = set()
    n_converted = 0
    total_value = 0.0
    for j in journeys.values():
        terminal = "conversion" if j["converted"] else "null"
        path = ["start"] + j["channels"] + [terminal]
        for a, b in zip(path[:-1], path[1:]):
            trans[a][b] += 1
        channels.update(j["channels"])
        if j["converted"]:
            n_converted += 1
            total_value += j["value"]
    # row-normalize to probabilities
    P = {s: {t: c / sum(d.values()) for t, c in d.items()} for s, d in trans.items()}
    return P, sorted(channels), n_converted, total_value


def conversion_probability(P, channels, removed=None):
    """Solve P(reach 'conversion' from 'start'), optionally removing one channel.

    Removing a channel = any transition into it now dies (absorbs to 0), so the
    channel is dropped from the transient states and never contributes to credit.
    For transient state s:  p[s] = sum_t P[s][t] * p[t], with p[conversion]=1 and
    p[null]=p[removed]=0. That's the linear system (I - Q) p = r.
    """
    transient = ["start"] + [c for c in channels if c != removed]
    idx = {s: i for i, s in enumerate(transient)}
    n = len(transient)
    A = np.eye(n)
    b = np.zeros(n)
    for s in transient:
        i = idx[s]
        for t, p in P.get(s, {}).items():
            if t == "conversion":
                b[i] += p
            elif t in idx:  # another transient channel
                A[i, idx[t]] -= p
            # transitions to 'null' or the removed channel -> absorb to 0
    return np.linalg.solve(A, b)[idx["start"]]


def main():
    conn = psycopg2.connect(**DB)
    cur = conn.cursor()

    journeys = load_journeys(cur)
    P, channels, n_converted, total_value = build_transitions(journeys)

    base = conversion_probability(P, channels)
    # removal effect per channel (clamp tiny negatives from float noise to 0)
    removal = {
        c: max(0.0, 1 - conversion_probability(P, channels, removed=c) / base)
        for c in channels
    }
    total_re = sum(removal.values())

    # normalize removal effects into credit shares, scale to actual conversions
    rows = []
    for c in channels:
        share = removal[c] / total_re if total_re else 0.0
        # cast numpy floats -> native float so psycopg2 can adapt them
        rows.append(("markov", c, float(share * n_converted), float(share * total_value)))

    cur.execute("DROP TABLE IF EXISTS analytics.fct_markov;")
    cur.execute(
        """
        CREATE TABLE analytics.fct_markov (
            attribution_model      text,
            channel                text,
            attributed_conversions numeric,
            attributed_value       numeric
        )
        """
    )
    cur.executemany("INSERT INTO analytics.fct_markov VALUES (%s, %s, %s, %s)", rows)
    conn.commit()

    # summary
    print(f"journeys: {len(journeys)}  converted: {n_converted}  "
          f"base conversion prob: {base:.3f}")
    print(f"wrote analytics.fct_markov ({len(rows)} channels), "
          f"total attributed = {sum(r[2] for r in rows):.2f}")
    for _, c, conv, _v in sorted(rows, key=lambda r: -r[2]):
        print(f"  {c:<12} {conv:6.2f}   removal_effect={removal[c]:.4f}")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()
