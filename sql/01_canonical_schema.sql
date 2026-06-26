-- =============================================================================
-- Canonical event schema for Attribution Studio.
--
-- THIS IS THE CONTRACT. Any uploaded CSV is validated against these columns,
-- then loaded into a per-upload schema as `canonical_events`. Every dbt model
-- and attribution rule is written ONCE against this shape, so the pipeline does
-- not care whether the data is apartments, e-commerce, or anything else.
--
-- One row = one marketing TOUCH or a CONVERSION event (long / event-level format).
-- =============================================================================

CREATE TABLE canonical_events (
    -- ---- REQUIRED ----
    user_id          text        NOT NULL,   -- identifies the journey/person
    event_timestamp  timestamp   NOT NULL,   -- ISO datetime of the touch/event
    channel          text        NOT NULL,   -- marketing channel/source (e.g. "Paid Social")
    event_type       text        NOT NULL,   -- one of: impression | click | session | conversion

    -- ---- OPTIONAL ----
    campaign         text,                    -- campaign name
    conversion_type  text,                    -- funnel step on conversion rows (e.g. lead | tour | lease)
    value            numeric,                 -- revenue/value of a conversion
    session_id       text                     -- session grouping
);

-- -----------------------------------------------------------------------------
-- Validation rules the upload layer enforces BEFORE loading (clear errors if not):
--   1. Required columns present: user_id, event_timestamp, channel, event_type
--   2. event_timestamp parses as a date/datetime
--   3. event_type is one of: impression, click, session, conversion
--   4. value (if present) is numeric
--   5. at least one row with event_type = 'conversion' (else nothing to attribute)
--
-- Notes on modeling downstream:
--   - A "journey" is built per user_id, ordered by event_timestamp (sessionize as
--     needed, e.g. inactivity reset) -- same idea as the FTA project, generalized.
--   - Conversions are the rows we attribute credit FOR; touches are what receive credit.
-- -----------------------------------------------------------------------------
