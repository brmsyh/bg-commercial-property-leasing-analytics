-- Q: Is the service problem portfolio-wide or concentrated? SLA performance by building.
SELECT
    b.building_code, b.year_built,
    COUNT(*)                                                         AS tickets,
    round(COUNT(*)::NUMERIC / b.gla_sqm * 1000, 1)                   AS tickets_per_1000_sqm,
    round(100.0 * AVG(t.sla_breach::INT), 1)                         AS sla_breach_pct,
    round(100.0 * AVG(t.sla_breach::INT) FILTER (WHERE t.category = 'HVAC'), 1) AS hvac_breach_pct,
    round(100.0 * COUNT(*) FILTER (WHERE t.category = 'HVAC') / COUNT(*), 1)    AS hvac_share_pct,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY t.resolution_hours)  AS median_resolution_h,
    round(AVG(t.satisfaction), 2)                                    AS avg_satisfaction
FROM mart.fact_ticket t
JOIN mart.dim_building b USING (building_id)
GROUP BY b.building_code, b.year_built, b.gla_sqm
ORDER BY sla_breach_pct DESC;
