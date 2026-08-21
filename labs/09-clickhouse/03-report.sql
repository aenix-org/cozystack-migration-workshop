SELECT
    toStartOfMonth(created_at)          AS month,
    count()                             AS guests,
    round(avg(duration_min))            AS avg_minutes,
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    topK(1)(entrance)[1]                AS busiest_entrance
FROM passes
GROUP BY month
ORDER BY month
