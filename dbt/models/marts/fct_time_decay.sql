-- =============================================================================
-- fct_time_decay  (mart -> table)
--
-- Time-decay attribution: like linear, every touch shares credit -- but touches
-- closer to the conversion get MORE. Credit decays exponentially with how long
-- before the conversion the touch happened, set by a half-life:
--
--     raw_weight = 0.5 ^ (days_before_conversion / half_life_days)
--
-- A touch at the moment of conversion has weight 1.0; one half-life earlier, 0.5;
-- two half-lives earlier, 0.25; and so on. We then NORMALIZE each journey's
-- weights so they sum to 1.0, so -- like every other model -- each converted
-- journey distributes exactly one conversion and the grand total still
-- reconciles to the number of converted journeys.
--
-- Uses conversion_timestamp + event_timestamp, both already on every touch row
-- from int_journeys. This is the first model that needs the time GAP, not just
-- order -- which is exactly why we broadcast conversion_timestamp back then.
-- =============================================================================

with journey_touches as (

    select
        journey_id,
        channel,
        conversion_value,
        -- days between this touch and its journey's conversion (>= 0 by
        -- construction: touches always precede the target conversion)
        extract(epoch from (conversion_timestamp - event_timestamp)) / 86400.0
            as days_before_conversion
    from {{ ref('int_journeys') }}
    where journey_converted
      and is_touch

),

weighted as (

    select
        journey_id,
        channel,
        conversion_value,
        power(0.5, days_before_conversion / {{ var('time_decay_half_life_days', 7) }})
            as raw_weight
    from journey_touches

),

normalized as (

    -- scale each journey's weights to sum to 1.0 (raw_weight sum is always > 0)
    select
        channel,
        conversion_value,
        raw_weight / sum(raw_weight) over (partition by journey_id) as credit
    from weighted

)

select
    'time_decay'                                  as attribution_model,
    channel,
    sum(credit)                                   as attributed_conversions,
    coalesce(sum(conversion_value * credit), 0)   as attributed_value
from normalized
group by channel
order by attributed_conversions desc
