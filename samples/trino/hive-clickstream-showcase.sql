-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- Trino on Hive showcase (warehouse profile). Run in Hue's Trino editor or:
--   kubectl -n warehouse exec -i trino-coordinator-0 -- trino -f /dev/stdin < samples/trino/hive-clickstream-showcase.sql
-- 200 users x 14 days x 20 clicks (56,000 rows), ORC, one Hive partition per day. Desktop and weekends
-- convert better, Germany worse. Schema demo lives in a trino-owned HDFS directory, created once as hdfs:
--   hdfs dfs -mkdir -p /warehouse/tablespace/external/hive/demo.db
--   hdfs dfs -chown trino:supergroup /warehouse/tablespace/external/hive/demo.db

CREATE SCHEMA IF NOT EXISTS hive.demo WITH (location = 'hdfs://nameservice:8020/warehouse/tablespace/external/hive/demo.db');

CREATE TABLE hive.demo.clickstream
WITH (format = 'ORC', partitioned_by = ARRAY['event_date'])
AS
WITH base AS (
  SELECT u, d, e,
         element_at(ARRAY['ES', 'PT', 'FR', 'DE', 'US'], (u % 5) + 1)        AS country,
         element_at(ARRAY['mobile', 'desktop', 'tablet'], (u % 3) + 1)      AS device,
         -- two visits per user and day; ~3 minutes between clicks inside a visit
         date_add('minute', CASE WHEN e < 10 THEN 9 * 60 ELSE 19 * 60 END + (u * 37) % 120 + 3 * (e % 10),
                  CAST(d AS timestamp(3)))                                  AS event_ts,
         random()                                                           AS r,
         -- weekends and desktop convert better; Germany a bit less
         CASE WHEN day_of_week(d) >= 6 THEN 1.4 ELSE 1.0 END
           * CASE (u % 3) WHEN 1 THEN 1.3 ELSE 1.0 END
           * CASE (u % 5) WHEN 3 THEN 0.7 ELSE 1.0 END                      AS lift
  FROM UNNEST(sequence(DATE '2026-11-01', DATE '2026-11-14', INTERVAL '1' DAY)) AS t1(d)
  CROSS JOIN UNNEST(sequence(0, 199)) AS t2(u)
  CROSS JOIN UNNEST(sequence(0, 19)) AS t3(e)
)
SELECT
  'user-' || lpad(CAST(u AS varchar), 3, '0') AS user_id,
  country,
  device,
  event_ts,
  CASE
    WHEN r < 0.04 * lift THEN 'purchase'
    WHEN r < 0.10 * lift THEN 'checkout'
    WHEN r < 0.25 * lift THEN 'add_to_cart'
    ELSE 'view'
  END AS event_type,
  CASE WHEN r < 0.04 * lift THEN round(15 + 185 * random(), 2) END AS amount_eur,
  slice(shuffle(ARRAY['sale', 'new', 'gift', 'eco', 'premium']), 1, 1 + CAST(floor(2 * random()) AS integer)) AS tags,
  d AS event_date
FROM base;

-- Sessionize clicks (30-minute inactivity gap), then a conversion funnel by country and device with ROLLUP subtotals.
-- The event_date filter prunes Hive partitions: only 7 of the 14 ORC partitions are read.
WITH ordered AS (
  SELECT *,
         CASE WHEN date_diff('minute',
                             lag(event_ts) OVER (PARTITION BY user_id ORDER BY event_ts),
                             event_ts) <= 30
              THEN 0 ELSE 1 END AS new_session
  FROM hive.demo.clickstream
  WHERE event_date BETWEEN DATE '2026-11-08' AND DATE '2026-11-14'
),
sessions AS (
  SELECT *,
         user_id || '#' || CAST(sum(new_session) OVER (PARTITION BY user_id ORDER BY event_ts) AS varchar) AS session_id
  FROM ordered
),
per_session AS (
  SELECT session_id, country, device,
         bool_or(event_type = 'add_to_cart') AS carted,
         bool_or(event_type = 'checkout')    AS checked_out,
         bool_or(event_type = 'purchase')    AS purchased,
         sum(amount_eur)                     AS revenue,
         date_diff('second', min(event_ts), max(event_ts)) AS duration_s
  FROM sessions
  GROUP BY 1, 2, 3
)
SELECT coalesce(country, 'ALL') AS country_or_all,
       coalesce(device, 'ALL')  AS device_or_all,
       count(*)                                                    AS sessions,
       round(100e0 * count_if(carted)      / count(*), 1)          AS cart_pct,
       round(100e0 * count_if(checked_out) / count(*), 1)          AS checkout_pct,
       round(100e0 * count_if(purchased)   / count(*), 1)          AS purchase_pct,
       round(sum(revenue), 2)                                      AS revenue_eur,
       round(sum(revenue) / nullif(count_if(purchased), 0), 2)     AS avg_order_eur,
       approx_percentile(duration_s, 0.5)                          AS median_session_s
FROM per_session
GROUP BY ROLLUP (country, device)
ORDER BY grouping(country, device), revenue_eur DESC NULLS LAST;

-- Which product tags drive revenue? UNNEST the ORC array column, then compare each day with the 3-day moving average.
WITH tagged AS (
  SELECT event_date, tag, amount_eur
  FROM hive.demo.clickstream
  CROSS JOIN UNNEST(tags) AS t(tag)
  WHERE event_type = 'purchase'
),
daily AS (
  SELECT tag, event_date, count(*) AS orders, round(sum(amount_eur), 2) AS revenue_eur
  FROM tagged
  GROUP BY 1, 2
)
SELECT tag, event_date, orders, revenue_eur,
       round(avg(revenue_eur) OVER (PARTITION BY tag ORDER BY event_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS revenue_3d_avg,
       round(100.0 * revenue_eur / sum(revenue_eur) OVER (PARTITION BY event_date), 1) AS share_of_day_pct,
       max_by(event_date, revenue_eur) OVER (PARTITION BY tag) AS best_day
FROM daily
WHERE event_date >= DATE '2026-11-10'
ORDER BY event_date, revenue_eur DESC;
