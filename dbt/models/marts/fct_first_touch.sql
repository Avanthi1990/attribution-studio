-- =============================================================================
-- fct_first_touch  (mart -> table)
--
-- First-touch attribution: 100% of a converted journey's credit goes to the
-- channel of its FIRST touch. Output is credit-by-channel -- exactly what the
-- app plots and what the side-by-side model comparison unions together.
--
-- Grain: one row per channel.
--   attributed_conversions = how many conversions this channel "won" first touch on
--   attributed_value        = revenue from those conversions
--
-- Because int_journeys already flagged is_first_touch, the model itself is just
-- "filter to the first touch of each converted journey, then group by channel".
-- That's the whole payoff of the staging -> intermediate -> marts layering.
--
-- Note on windows: first-touch normally also takes a conversion-window config
-- (only count the first touch if it's within N days of the conversion). That
-- filter is user-configurable, so it'll be applied here via a var/macro later;
-- this first cut credits the first touch regardless of recency.
--
-- Edge case: a journey that converts with ZERO preceding touches (a "direct"
-- conversion) has no is_first_touch row, so it isn't credited to any channel.
-- That's correct for first-touch -- there's no touch to attribute -- but it means
-- sum(attributed_conversions) can be < total conversions. We'll surface those as
-- an '(unattributed)' bucket when we generalize across models.
-- =============================================================================

with first_touches as (

    select
        channel,
        conversion_value
    from {{ ref('int_journeys') }}
    where journey_converted          -- only attribute journeys that converted
      and is_first_touch             -- ...crediting their first touch only

)

select
    'first_touch'                       as attribution_model,
    channel,
    count(*)                            as attributed_conversions,
    coalesce(sum(conversion_value), 0)  as attributed_value
from first_touches
group by channel
order by attributed_conversions desc
