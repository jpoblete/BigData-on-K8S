-- Usage Notice: This project is not meant for commercial use without permission and proper credit.
-- Author: j.martinez.poblete@gmail.com
-- HiveQL version of the sessionized funnel in samples/trino/hive-clickstream-showcase.sql (warehouse profile).
-- Run in Hue's Hive editor. Same 21 rows as the Trino query; rollup_level is 0 for country+device, 1 per country, 2 overall.
-- Dialect differences: docs/warehouse-profile.md, "Trino SQL vs HiveQL".

WITH ordered AS (
  SELECT *,
         CASE WHEN (unix_timestamp(event_ts)
                    - unix_timestamp(lag(event_ts) OVER (PARTITION BY user_id ORDER BY event_ts))) / 60 <= 30
              THEN 0 ELSE 1 END AS new_session
  FROM demo.clickstream
  WHERE event_date BETWEEN DATE '2026-11-08' AND DATE '2026-11-14'
),
sessions AS (
  SELECT *,
         concat(user_id, '#', CAST(sum(new_session) OVER (PARTITION BY user_id ORDER BY event_ts) AS STRING)) AS session_id
  FROM ordered
),
per_session AS (
  SELECT session_id, country, device,
         max(IF(event_type = 'add_to_cart', 1, 0)) AS carted,
         max(IF(event_type = 'checkout', 1, 0))    AS checked_out,
         max(IF(event_type = 'purchase', 1, 0))    AS purchased,
         sum(amount_eur)                            AS revenue,
         unix_timestamp(max(event_ts)) - unix_timestamp(min(event_ts)) AS duration_s
  FROM sessions
  GROUP BY session_id, country, device
)
SELECT coalesce(country, 'ALL') AS country_or_all,
       coalesce(device, 'ALL')  AS device_or_all,
       count(*) AS sessions,
       round(100.0 * sum(carted)      / count(*), 1) AS cart_pct,
       round(100.0 * sum(checked_out) / count(*), 1) AS checkout_pct,
       round(100.0 * sum(purchased)   / count(*), 1) AS purchase_pct,
       round(sum(revenue), 2) AS revenue_eur,
       round(sum(revenue) / nullif(sum(purchased), 0), 2) AS avg_order_eur,
       percentile_approx(duration_s, 0.5) AS median_session_s,
       grouping(country) + grouping(device) AS rollup_level
FROM per_session
GROUP BY country, device WITH ROLLUP
ORDER BY rollup_level, revenue_eur DESC NULLS LAST;
