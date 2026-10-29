-- Q: Is over-pricing a unit-level accident or a building-level policy?
WITH um AS (
    SELECT unit_id, month_start, is_occupied,
           ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY month_start)
         - ROW_NUMBER() OVER (PARTITION BY unit_id, is_occupied ORDER BY month_start) AS grp
    FROM mart.fact_unit_month
),
spells AS (
    SELECT unit_id, COUNT(*) AS months_vacant
    FROM um WHERE NOT is_occupied
    GROUP BY unit_id, grp
    HAVING MAX(month_start) < '2025-12-01' AND MIN(month_start) > '2021-01-01'
)
SELECT u.building_code, u.city, u.grade,
       round(100 * AVG(u.asking_vs_market), 1)              AS avg_asking_vs_market_pct,
       COUNT(s.unit_id)                                     AS vacancy_spells,
       round(AVG(s.months_vacant), 1)                       AS avg_months_to_relet
FROM mart.dim_unit u
LEFT JOIN spells s USING (unit_id)
GROUP BY 1, 2, 3
ORDER BY avg_asking_vs_market_pct DESC;
