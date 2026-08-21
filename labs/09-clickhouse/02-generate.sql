INSERT INTO passes
SELECT
    number AS pass_id,
    addMinutes(
        addHours(
            addDays(
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    concat('Гость № ', toString(number)) AS guest_name,
    ['Продажи', 'Разработка', 'Бухгалтерия',
     'Кадры', 'Логистика'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    ['разовый', 'разовый', 'разовый', 'разовый', 'разовый', 'разовый',
     'недельный', 'недельный',
     'автомобильный', 'групповой'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
FROM numbers(1000000)
