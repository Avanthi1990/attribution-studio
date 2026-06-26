-- =============================================================================
-- fct_last_touch  (mart -> table)
--
-- Last-touch attribution: 100% of a converted journey's credit goes to its most
-- recent ELIGIBLE touch -- the last touch that falls within the lookback window.
--
-- Two steps, mirroring how we explained it:
--   1. WINDOW (filter): keep only touches within `last_touch_lookback_days` days
--      before the conversion. Older touches are too stale to compete.
--   2. LAST (pick one winner): among the survivors, the most recent touch takes
--      ALL the credit; every other eligible touch gets zero.
--
-- Same channel-grain output and `attribution_model` tag as fct_first_touch, so
-- the app can union the two and toggle between them.
--
-- Why we re-pick the last touch instead of reusing int_journeys.is_last_touch:
-- that flag is the journey's last touch REGARDLESS of recency. Once a window is
-- applied, the real winner is the latest touch that survives the filter, which
-- can be an earlier touch (or none, if the journey's tail is all too old).
--
-- Edge case (same as first-touch, more common here): if NO touch is within the
-- window, the journey isn't credited to any channel. We'll fold those into an
-- '(unattributed)' bucket when we generalize across models.
-- =============================================================================

with eligible_touches as (

    -- step 1: only touches inside the lookback window compete
    select
        journey_id,
        channel,
        conversion_value,
        event_timestamp,
        session_id
    from {{ ref('int_journeys') }}
    where journey_converted
      and is_touch
      and conversion_timestamp - event_timestamp
            <= interval '1 day' * {{ var('last_touch_lookback_days', 90) }}

),

ranked as (

    -- step 2: rank survivors by recency; rank 1 = the last touch
    -- (desc on the same keys int_journeys used asc, so this matches is_last_touch
    --  exactly whenever the window doesn't disqualify anything)
    select
        channel,
        conversion_value,
        row_number() over (
            partition by journey_id
            order by event_timestamp desc, session_id desc
        ) as recency_rank
    from eligible_touches

),

winners as (

    select channel, conversion_value
    from ranked
    where recency_rank = 1

)

select
    'last_touch'                        as attribution_model,
    channel,
    count(*)                            as attributed_conversions,
    coalesce(sum(conversion_value), 0)  as attributed_value
from winners
group by channel
order by attributed_conversions desc
