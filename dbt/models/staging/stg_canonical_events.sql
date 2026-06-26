-- =============================================================================
-- stg_canonical_events
--
-- Light, 1:1 cleaning of the raw uploaded events. No business logic here:
--   - cast types (timestamp, numeric)
--   - trim + lowercase the categorical fields so grouping is consistent
--   - turn empty strings ('') from the CSV into real NULLs
--   - standardize event_type to the 4 canonical values + add is_conversion/is_touch flags
--
-- Journey ordering / sessionization / first-last touch is BUSINESS LOGIC and
-- lives in the intermediate models built on top of this. Keeping staging a clean
-- pass-through is what lets every attribution model share one trusted base.
-- =============================================================================

with source as (

    select * from {{ source('raw', 'canonical_events') }}

),

cleaned as (

    select
        -- ---- identity / time ----
        trim(user_id)                              as user_id,
        cast(event_timestamp as timestamp)         as event_timestamp,

        -- ---- categoricals (trim; empty string -> NULL) ----
        nullif(trim(channel), '')                  as channel,
        nullif(trim(campaign), '')                 as campaign,
        nullif(trim(session_id), '')               as session_id,

        -- ---- event_type: normalize to one of the 4 canonical values ----
        lower(trim(event_type))                    as event_type,

        -- ---- conversion attributes ----
        nullif(lower(trim(conversion_type)), '')   as conversion_type,
        cast(nullif(trim(cast(value as text)), '') as numeric) as value

    from source

)

select
    *,
    -- convenience flags used by every downstream attribution model
    (event_type = 'conversion')                       as is_conversion,
    (event_type in ('impression', 'click', 'session')) as is_touch
from cleaned
