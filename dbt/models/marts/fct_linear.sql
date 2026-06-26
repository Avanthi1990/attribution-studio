-- =============================================================================
-- fct_linear  (mart -> table)
--
-- Linear attribution: split each converted journey's credit EVENLY across all of
-- its touches. A journey with 4 touches gives each touch 1/4 of a conversion.
--
-- This is the first MULTI-touch model: instead of one winner taking 100%
-- (first/last), every touch shares. So credit becomes FRACTIONAL -- a channel can
-- earn 7.5 conversions, not just whole ones. Each converted journey still
-- distributes exactly 1.0 conversion total, so the grand total across channels
-- equals the number of converted journeys (same as first/last touch).
--
-- The whole model is "give each touch 1/touches_in_journey" -- and
-- touches_in_journey was already computed once in int_journeys. No new windows or
-- ranking; just a weighted sum.
-- =============================================================================

with journey_touches as (

    select
        channel,
        conversion_value,
        touches_in_journey
    from {{ ref('int_journeys') }}
    where journey_converted          -- only journeys that reached the target
      and is_touch                   -- every marketing touch shares the credit
    -- touches_in_journey is guaranteed >= 1 here (this row IS a touch), so the
    -- 1/N division below is always safe.

)

select
    'linear'                                            as attribution_model,
    channel,
    sum(1.0 / touches_in_journey)                       as attributed_conversions,
    coalesce(sum(conversion_value / touches_in_journey), 0) as attributed_value
from journey_touches
group by channel
order by attributed_conversions desc
