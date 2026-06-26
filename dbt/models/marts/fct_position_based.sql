-- =============================================================================
-- fct_position_based  (mart -> table)
--
-- Position-based ("U-shaped") attribution: reward the touches that opened and
-- closed the journey, give the middle touches a smaller shared slice. Default
-- 40 / 20 / 40 -- first touch 40%, last touch 40%, the middle 20% split evenly.
--
-- We assign a RAW weight per touch, then normalize each journey to sum to 1.0.
-- Normalizing makes the awkward edge cases fall out for free:
--   - 1 touch  -> it's both first and last, gets 100%
--   - 2 touches-> first + last only (no middle); raw 0.4+0.4=0.8 -> 50/50 after norm
--   - 3+ touches-> 0.4 + 0.2(shared) + 0.4 = 1.0 already; normalize is a no-op
-- ...and, as with every model, the grand total reconciles to converted journeys.
--
-- Uses touch_seq + touches_in_journey, both precomputed in int_journeys.
-- =============================================================================

{% set first_w = var('position_first_weight', 0.4) %}
{% set last_w  = var('position_last_weight', 0.4) %}

with journey_touches as (

    select
        journey_id,
        channel,
        conversion_value,
        touch_seq,
        touches_in_journey
    from {{ ref('int_journeys') }}
    where journey_converted
      and is_touch

),

weighted as (

    select
        journey_id,
        channel,
        conversion_value,
        case
            -- single touch is both first and last -> all the credit
            when touches_in_journey = 1 then 1.0
            when touch_seq = 1                   then {{ first_w }}
            when touch_seq = touches_in_journey  then {{ last_w }}
            -- middle touches share the remaining weight evenly
            else (1 - {{ first_w }} - {{ last_w }}) / (touches_in_journey - 2)
        end as raw_weight
    from journey_touches

),

normalized as (

    select
        channel,
        conversion_value,
        raw_weight / sum(raw_weight) over (partition by journey_id) as credit
    from weighted

)

select
    'position_based'                              as attribution_model,
    channel,
    sum(credit)                                   as attributed_conversions,
    coalesce(sum(conversion_value * credit), 0)   as attributed_value
from normalized
group by channel
order by attributed_conversions desc
