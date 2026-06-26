-- =============================================================================
-- int_journeys
--
-- Imposes JOURNEY STRUCTURE on the cleaned events. This is where "what is a
-- journey?" gets decided -- the one business definition every attribution model
-- then shares.
--
-- Definition: a journey ends at a TARGET conversion. The target is configurable
-- (var 'target_conversion', default 'lease') because the Irvine data is a FUNNEL
-- (lead -> tour -> application -> lease), and which step counts as "the
-- conversion" is a business choice the app exposes as a dropdown.
--
--   - target_conversion = 'lease'  -> only lease_signed closes a journey; the
--     earlier funnel steps (lead/tour/application) are NEUTRAL context -- they
--     neither close a journey nor receive credit -- so every session before the
--     lease credits the lease.
--   - target_conversion = 'any'    -> every conversion closes a journey.
--
-- A user who hits the target twice has two journeys. Touches after the final
-- target form an "open" (un-converted) journey we keep but flag.
--
-- Output: one row per event, enriched with the journey it belongs to, its
-- position, and journey-level facts. Attribution models read THIS, never raw events.
--
-- NOT done here: conversion/lookback WINDOWS and credit weights -- those are
-- per-model config and live in the marts layer.
-- =============================================================================

{% set target = var('target_conversion', 'lease') %}

with events as (

    select
        *,
        -- the conversion we're attributing credit FOR this run (configurable)
        (
            is_conversion
            and ('{{ target }}' = 'any' or conversion_type = '{{ target }}')
        ) as is_target_conversion
    from {{ ref('stg_canonical_events') }}

),

-- 1. Put each user's events on one timeline and count how many TARGET conversions
--    happened before each row. That running count IS the journey index.
--    Tie-break: at equal timestamps, touches sort before the target conversion.
ordered as (

    select
        *,
        coalesce(
            sum(case when is_target_conversion then 1 else 0 end) over (
                partition by user_id
                order by event_timestamp, is_target_conversion, session_id
                rows between unbounded preceding and 1 preceding
            ),
            0
        ) as journey_index
    from events

),

-- 2. Build a stable journey_id and number the events within each journey.
journeys as (

    select
        *,
        user_id || '_j' || journey_index as journey_id,
        row_number() over (
            partition by user_id, journey_index
            order by event_timestamp, is_target_conversion, session_id
        ) as event_seq_in_journey
    from ordered

),

-- 3. Add the journey-level facts the attribution models need.
enriched as (

    select
        *,
        -- did this journey reach the TARGET conversion? (vs open/abandoned)
        bool_or(is_target_conversion) over (partition by journey_id) as journey_converted,
        -- when it converted (NULL for open journeys) -- time-decay needs this
        max(case when is_target_conversion then event_timestamp end)
            over (partition by journey_id) as conversion_timestamp,
        -- the target conversion's revenue, broadcast onto every touch row
        max(case when is_target_conversion then value end)
            over (partition by journey_id) as conversion_value,
        -- how many TOUCHES (marketing events) in the journey -- linear/position need this
        sum(case when is_touch then 1 else 0 end)
            over (partition by journey_id) as touches_in_journey,
        -- position among touches only (NULL on conversion / neutral rows)
        case when is_touch then
            row_number() over (
                partition by journey_id, is_touch
                order by event_timestamp, session_id
            )
        end as touch_seq
    from journeys

)

select
    journey_id,
    user_id,
    journey_index,
    event_seq_in_journey,
    event_timestamp,
    channel,
    campaign,
    session_id,
    event_type,
    conversion_type,
    value,
    is_touch,
    is_conversion,
    is_target_conversion,
    journey_converted,
    conversion_timestamp,
    conversion_value,
    touches_in_journey,
    touch_seq,
    -- first / last touch within the journey (the whole game for FT / LT models)
    (is_touch and touch_seq = 1)                    as is_first_touch,
    (is_touch and touch_seq = touches_in_journey)   as is_last_touch
from enriched
