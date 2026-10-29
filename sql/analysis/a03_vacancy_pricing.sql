-- Q: Why do some units stay empty so long? Re-letting time vs. how far the unit's
--    asking rent sits above the broker market benchmark (Q4-2025).
-- Vacancy spells = consecutive vacant months (gaps-and-islands). Only complete
-- spells (started after Jan-2021 and re-let before Dec-2025) are measured.
WITH um AS (
    SELECT unit_id, building_id, month_start, is_occupied,
           ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY month_start)
         - ROW_NUMBER() OVER (PARTITION BY unit_id, is_occupied ORDER BY month_start) AS grp
    FROM mart.fact_unit_month
),
spells AS (
    SELECT unit_id, MIN(month_start) AS vac_from, COUNT(*) AS months_vacant
    FROM um WHERE NOT is_occupied
    GROUP BY unit_id, grp
    HAVING MAX(month_start) < '2025-12-01' AND MIN(month_start) > '2021-01-01'
)
SELECT
    CASE WHEN u.asking_vs_market <= 0.05 THEN '1. at market (<= +5%)'
         WHEN u.asking_vs_market <= 0.15 THEN '2. +5% to +15%'
         WHEN u.asking_vs_market <= 0.25 THEN '3. +15% to +25%'
         ELSE '4. above +25%' END                                  AS asking_vs_market_band,
    COUNT(*)                                                       AS vacancy_spells,
    round(AVG(s.months_vacant), 1)                                 AS avg_months_to_relet,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY s.months_vacant)   AS median_months_to_relet,
    round(100.0 * AVG((s.months_vacant >= 12)::INT), 1)            AS pct_vacant_12m_plus
FROM spells s
JOIN mart.dim_unit u USING (unit_id)
GROUP BY 1
ORDER BY 1;
