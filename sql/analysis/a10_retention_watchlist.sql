-- Q (proactive): Which active leases expiring in 2026 are most at risk, so the
--    leasing team can act 6-9 months ahead? Risk = SLA breaches in the last 12 months.
SELECT
    l.lease_id, l.tenant_id, b.building_code, u.unit_code, l.area_sqm, t.segment, t.industry,
    l.end_date,
    round(l.contract_rent_pa_eur)                                         AS contract_rent_pa_eur,
    COUNT(tk.ticket_id)                                                   AS tickets_12m,
    COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach)                      AS sla_breaches_12m,
    CASE WHEN COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach) >= 3 THEN 'High'
         WHEN COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach) >= 1 THEN 'Medium'
         ELSE 'Low' END                                                   AS churn_risk
FROM mart.fact_lease l
JOIN mart.dim_unit u USING (unit_id)
JOIN mart.dim_building b ON b.building_id = l.building_id
JOIN mart.dim_tenant t USING (tenant_id)
LEFT JOIN mart.fact_ticket tk ON tk.lease_id = l.lease_id AND tk.created_at >= '2025-01-01'
WHERE l.outcome = 'Active' AND l.end_date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY l.lease_id, l.tenant_id, b.building_code, u.unit_code, l.area_sqm, t.segment, t.industry, l.end_date, l.contract_rent_pa_eur
ORDER BY sla_breaches_12m DESC, contract_rent_pa_eur DESC;
