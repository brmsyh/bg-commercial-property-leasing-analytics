-- Q: Which buildings earn their book value? 2025 net rent, rent per sqm and gross yield.
WITH r AS (
    SELECT building_id,
           SUM(net_rent_eur)   AS net_rent_2025,
           SUM(gross_rent_eur) AS gross_rent_2025
    FROM mart.fact_invoice
    WHERE billing_month BETWEEN '2025-01-01' AND '2025-12-01'
    GROUP BY 1
)
SELECT b.building_code, b.city, b.asset_type, b.grade, b.gla_sqm,
       round(r.net_rent_2025)                                         AS net_rent_2025_eur,
       round(r.net_rent_2025 / b.gla_sqm / 12, 2)                     AS net_rent_per_gla_sqm_month,
       round(100 * (r.gross_rent_2025 - r.net_rent_2025) / r.gross_rent_2025, 1) AS rent_free_pct,
       round(b.book_value_eur / 1e6, 1)                               AS book_value_m_eur,
       round(100 * r.net_rent_2025 / b.book_value_eur, 2)             AS gross_yield_pct
FROM mart.dim_building b JOIN r USING (building_id)
ORDER BY gross_yield_pct;
