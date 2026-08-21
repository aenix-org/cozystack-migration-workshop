CREATE TABLE IF NOT EXISTS passes
(
    pass_id      UInt64,
    created_at   DateTime,
    guest_name   String,
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    duration_min UInt16
)
ENGINE = MergeTree
ORDER BY (created_at, entrance)
