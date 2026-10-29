-- =====================================================================
-- 02_load_raw.sql   (run with psql from the repository root)
--   psql -d bg_property -f sql/02_load_raw.sql
-- =====================================================================
\copy raw.buildings           FROM 'data/raw/buildings.csv'           WITH (FORMAT csv, HEADER true)
\copy raw.units               FROM 'data/raw/units.csv'               WITH (FORMAT csv, HEADER true)
\copy raw.tenants             FROM 'data/raw/tenants.csv'             WITH (FORMAT csv, HEADER true)
\copy raw.leases              FROM 'data/raw/leases.csv'              WITH (FORMAT csv, HEADER true)
\copy raw.invoice_lines       FROM 'data/raw/invoice_lines_2021_2023.csv' WITH (FORMAT csv, HEADER true)
\copy raw.invoice_lines       FROM 'data/raw/invoice_lines_2024_2025.csv' WITH (FORMAT csv, HEADER true)
\copy raw.payments            FROM 'data/raw/payments.csv'            WITH (FORMAT csv, HEADER true)
\copy raw.maintenance_tickets FROM 'data/raw/maintenance_tickets.csv' WITH (FORMAT csv, HEADER true)
\copy raw.market_rent_benchmark FROM 'data/reference/market_rent_benchmark.csv' WITH (FORMAT csv, HEADER true)

SELECT 'buildings' AS tbl, COUNT(*) FROM raw.buildings UNION ALL
SELECT 'units', COUNT(*) FROM raw.units UNION ALL
SELECT 'tenants', COUNT(*) FROM raw.tenants UNION ALL
SELECT 'leases', COUNT(*) FROM raw.leases UNION ALL
SELECT 'invoice_lines', COUNT(*) FROM raw.invoice_lines UNION ALL
SELECT 'payments', COUNT(*) FROM raw.payments UNION ALL
SELECT 'maintenance_tickets', COUNT(*) FROM raw.maintenance_tickets;
