-- Q: Why do tenants leave? Renewal rate at expiry vs. service experience in the
--    12 months before expiry (SLA breaches on maintenance tickets).
SELECT
    COALESCE(complaint_band, 'All expiries')   AS complaint_band,
    COUNT(*)                                     AS expiries,
    SUM(renewed)                                 AS renewed,
    round(100.0 * AVG(renewed), 1)               AS renewal_rate_pct,
    round(AVG(tickets_12m), 1)                   AS avg_tickets_12m,
    round(AVG(avg_satisfaction_12m), 2)          AS avg_satisfaction
FROM mart.fact_lease_expiry
GROUP BY ROLLUP (complaint_band)
ORDER BY GROUPING(complaint_band), complaint_band;
