-- Q: How has area-weighted occupancy developed, and which buildings drag the portfolio down?
SELECT
    b.building_code, b.city, b.asset_type, b.grade,
    round(100.0 * SUM(f.area_sqm) FILTER (WHERE f.is_occupied AND m.year = 2021) / NULLIF(SUM(f.area_sqm) FILTER (WHERE m.year = 2021), 0), 1) AS occ_2021,
    round(100.0 * SUM(f.area_sqm) FILTER (WHERE f.is_occupied AND m.year = 2023) / NULLIF(SUM(f.area_sqm) FILTER (WHERE m.year = 2023), 0), 1) AS occ_2023,
    round(100.0 * SUM(f.area_sqm) FILTER (WHERE f.is_occupied AND m.year = 2025) / NULLIF(SUM(f.area_sqm) FILTER (WHERE m.year = 2025), 0), 1) AS occ_2025,
    round(SUM(f.area_sqm) FILTER (WHERE NOT f.is_occupied AND m.year = 2025) / 12)                        AS avg_vacant_sqm_2025
FROM mart.fact_unit_month f
JOIN mart.dim_month m USING (month_start)
JOIN mart.dim_building b USING (building_id)
GROUP BY 1, 2, 3, 4
ORDER BY occ_2025;
