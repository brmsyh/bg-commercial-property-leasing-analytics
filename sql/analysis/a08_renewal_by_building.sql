-- Q: Renewal rate and the cost of tenants who left, by building.
--    Lost income = annual contract rent of vacated leases x months the unit then stood empty.
WITH vac AS (
    SELECT e.lease_id, e.building_id, e.renewed, l.contract_rent_pa_eur,
           (SELECT COUNT(*) FROM mart.fact_unit_month f
             WHERE f.unit_id = e.unit_id AND NOT f.is_occupied
               AND f.month_start > e.end_date
               AND f.month_start < COALESCE((SELECT MIN(n.start_date) FROM mart.fact_lease n
                                              WHERE n.unit_id = e.unit_id AND n.start_date > e.end_date), '2026-01-01')
           ) AS months_empty_after
    FROM mart.fact_lease_expiry e JOIN mart.fact_lease l USING (lease_id)
)
SELECT b.building_code,
       COUNT(*)                                                     AS expiries,
       round(100.0 * AVG(renewed), 1)                               AS renewal_rate_pct,
       round(SUM(contract_rent_pa_eur / 12 * months_empty_after) FILTER (WHERE renewed = 0)) AS lost_rent_eur
FROM vac JOIN mart.dim_building b USING (building_id)
GROUP BY 1
ORDER BY renewal_rate_pct;
