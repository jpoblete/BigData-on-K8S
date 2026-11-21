-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- Trino on Cassandra showcase (warehouse profile). Run in Hue's Trino editor or:
--   kubectl -n warehouse exec -i trino-coordinator-0 -- trino -f /dev/stdin < samples/trino/cassandra-sensor-showcase.sql
-- 12 sensors x 4 sites, one reading every 15 minutes for 20 days (23,040 rows); sensor-07 overheats on 2026-11-13.

DROP TABLE IF EXISTS cassandra.demo.sensor_readings;

CREATE TABLE cassandra.demo.sensor_readings AS
SELECT
  'sensor-' || lpad(CAST(s AS varchar), 2, '0') AS sensor_id,
  element_at(ARRAY['lisbon', 'madrid', 'paris', 'berlin'], (s % 4) + 1) AS site,
  date_add('minute', 15 * m, TIMESTAMP '2026-11-01 00:00:00.000 UTC') AS reading_ts,
  round(
    18 + 6 * sin(2 * pi() * ((m % 96) / 96.0))       -- daily cycle
    + (s % 4) * 1.5                                    -- warmer sites
    + CASE WHEN s = 7 AND m BETWEEN 1200 AND 1215 THEN 2.0 * (m - 1199) ELSE 0 END  -- a sensor overheating
    + (random() - 0.5), 2) AS temperature_c,
  round(45 + 15 * cos(2 * pi() * ((m % 96) / 96.0)) + 10 * (random() - 0.5), 1) AS humidity_pct
FROM UNNEST(sequence(0, 11)) AS t1(s)
CROSS JOIN UNNEST(sequence(0, 1919)) AS t2(m);

-- Overheating episodes: 4+ consecutive readings, each warmer than the previous, ending 10°C+ above where they started.
SELECT sensor_id, site, episode_start, episode_end, readings, start_c, peak_c, rise_c
FROM cassandra.demo.sensor_readings
MATCH_RECOGNIZE (
  PARTITION BY sensor_id, site
  ORDER BY reading_ts
  MEASURES
    FIRST(reading_ts)            AS episode_start,
    LAST(reading_ts)             AS episode_end,
    COUNT(*)                     AS readings,
    FIRST(temperature_c)         AS start_c,
    MAX(temperature_c)           AS peak_c,
    round(MAX(temperature_c) - FIRST(temperature_c), 2) AS rise_c
  ONE ROW PER MATCH
  AFTER MATCH SKIP PAST LAST ROW
  PATTERN (base up{4,})
  DEFINE
    up AS temperature_c > PREV(temperature_c) + 1.0
)
WHERE rise_c >= 10
ORDER BY rise_c DESC;

-- Daily profile per site: percentiles, day-over-day change, rank across sites, and readings more than 3 sigma off the sensor's norm.
WITH scored AS (
  SELECT *,
         (temperature_c - avg(temperature_c) OVER (PARTITION BY sensor_id))
           / stddev(temperature_c) OVER (PARTITION BY sensor_id) AS z
  FROM cassandra.demo.sensor_readings
),
daily AS (
  SELECT site,
         date(reading_ts) AS day,
         round(avg(temperature_c), 2)                          AS avg_c,
         round(approx_percentile(temperature_c, 0.95), 2)      AS p95_c,
         round(corr(temperature_c, humidity_pct), 2)           AS temp_humidity_corr,
         count_if(abs(z) > 3)                                  AS anomalies
  FROM scored
  GROUP BY 1, 2
)
SELECT site, day, avg_c, p95_c,
       round(avg_c - lag(avg_c) OVER (PARTITION BY site ORDER BY day), 2) AS dod_change_c,
       rank() OVER (PARTITION BY day ORDER BY avg_c DESC)                AS warmest_rank,
       temp_humidity_corr, anomalies
FROM daily
WHERE day BETWEEN DATE '2026-11-12' AND DATE '2026-11-14'
ORDER BY day, warmest_rank;
