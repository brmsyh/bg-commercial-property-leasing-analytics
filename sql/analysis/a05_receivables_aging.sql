-- Q: Where is cash stuck? Open receivables at 31-Dec-2025 by building and aging bucket,
--    and how much of the 180+ day balance is the disputed 2022 service-charge reconciliation.
SELECT
    b.building_code, b.asset_type,
    round(SUM(r.open_eur) FILTER (WHERE r.aging_bucket = '1-30 days'))   AS d1_30,
    round(SUM(r.open_eur) FILTER (WHERE r.aging_bucket = '31-90 days'))  AS d31_90,
    round(SUM(r.open_eur) FILTER (WHERE r.aging_bucket = '91-180 days')) AS d91_180,
    round(SUM(r.open_eur) FILTER (WHERE r.aging_bucket = '180+ days'))   AS d180_plus,
    round(SUM(LEAST(r.open_eur, GREATEST(r.sc_recon_eur, 0))) FILTER (WHERE r.aging_bucket = '180+ days')) AS d180_from_sc_recon,
    COUNT(DISTINCT r.tenant_id) FILTER (WHERE r.aging_bucket = '180+ days') AS tenants_180_plus
FROM mart.fact_receivable r
JOIN mart.dim_building b USING (building_id)
WHERE r.aging_bucket NOT IN ('Settled', 'Not yet due')
GROUP BY 1, 2
ORDER BY d180_plus DESC NULLS LAST;
