# Tableau build guide

Three dashboards, built on the CSV extracts in `tableau/data/` (exported from the `tableau.*` views by `src/export_tableau.py`). Tableau Public cannot connect to PostgreSQL, so the extracts are the data source; with Tableau Desktop you can point the same sheets at the views directly.

| File | Grain | Rows | Feeds |
|---|---|---|---|
| `unit_month.csv` | unit × month | 186,780 | Occupancy & income |
| `building_scorecard.csv` | building | 26 | Executive overview |
| `vacancy_spells.csv` | vacancy spell | 2,018 | Pricing |
| `tickets.csv` | maintenance ticket | 32,736 | Service & retention |
| `lease_expiry.csv` | expired lease | 3,960 | Service & retention |
| `retention_watchlist.csv` | lease expiring 2026 | 823 | Service & retention |
| `receivables.csv` | invoice | 172,280 | Cash |

Add each file as a **separate data source** (they have different grains; do not join them). Use `building_code` as a shared filter field across sources (Dashboard → Filters → Apply to: all using related data sources, after defining the blend relationship on `building_code`).

---

## Colours
One accent and one neutral, so the problem always pops:
- Accent (problem / highlight): `#eb6834`
- Primary series: `#2a78d6`
- Context / everything else: `#c9c8c3`
- Background: `#fcfcfb`, text `#0b0b0b`, secondary text `#52514e`

Do not use red/green status colours for series.

---

## Calculated fields

**unit_month**
```
// Occupancy %  (area-weighted)
SUM([Occupied Sqm]) / SUM([Area Sqm])

// Vacant sqm
SUM([Area Sqm]) - SUM([Occupied Sqm])

// Rent-free leakage %
1 - SUM([Net Rent Eur]) / SUM([Gross Rent Eur])
```

**building_scorecard**
```
// Problem type  (drives the highlight colour)
IF [Asking Vs Market] >= 0.15 THEN "Over-priced"
ELSEIF [Sla Breach Rate] >= 0.5 THEN "Service failure"
ELSE "Other" END
```

**vacancy_spells** (filter `Is Complete Spell = 1` on every sheet)
```
// Asking vs market band
IF [Asking Vs Market] <= 0.05 THEN "1. At market (<= +5%)"
ELSEIF [Asking Vs Market] <= 0.15 THEN "2. +5% to +15%"
ELSEIF [Asking Vs Market] <= 0.25 THEN "3. +15% to +25%"
ELSE "4. Above +25%" END

// Vacant 12m+
IF [Months Vacant] >= 12 THEN 1 ELSE 0 END
```

**tickets / lease_expiry**
```
// SLA breach rate
AVG([Sla Breach])

// Renewal rate
AVG([Renewed])
```

**receivables**
```
// Overdue (excl. not-yet-due and settled)
IF [Aging Bucket] <> "Settled" AND [Aging Bucket] <> "Not yet due" THEN [Open Eur] END

// SC recon part of open balance
IF [Sc Recon Eur] > 0 THEN MIN([Open Eur], [Sc Recon Eur]) ELSE 0 END

// Aging sort
CASE [Aging Bucket] WHEN "1-30 days" THEN 1 WHEN "31-90 days" THEN 2
WHEN "91-180 days" THEN 3 WHEN "180+ days" THEN 4 END
```

---

## Dashboard 1: Executive overview (1200 × 800)
1. **KPI row** (4 text tiles from `unit_month` + `receivables`): Occupancy Dec-2025 · Net rent 2025 · Overdue receivables · Renewal rate. Big number, one-line caption underneath ("94.0% occupied, but 52% of vacant space sits in 6 buildings").
2. **Occupancy trend** – line, `Month Start` (continuous month) vs `Occupancy %`, single blue line, y-axis 85–100%.
3. **Building scorecard** – horizontal bars, `Building Code` sorted by occupancy, colour = `Problem type` (accent for Over-priced and Service failure, grey for Other). Tooltip: occupancy, yield, SLA breach rate, renewal rate, overdue EUR.
4. **Title as the finding**, not the topic: *"We are not short of demand: slow repairs and above-market asking rents create our vacancy."*

## Dashboard 2: Leasing & pricing
1. **Scatter** (`building_scorecard`): x = `Asking Vs Market`, y = AVG months to re-let (from `vacancy_spells`, blended), colour = `Problem type`, labels only on accent marks.
2. **Bar** (`vacancy_spells`): `Asking vs market band` vs AVG `Months Vacant` and % `Vacant 12m+` (two separate bar charts side by side; never a dual axis).
3. **Table**: longest current vacancies (Is Complete Spell = 0), with asking rent, benchmark and gap – the re-pricing to-do list.

## Dashboard 3: Service & retention
1. **Bar** (`lease_expiry`): `Complaint Band` vs `Renewal rate`, blue bars, labels on bars.
2. **Bar** (`tickets`): SLA breach rate by building, top 2 accent.
3. **Heatmap** (`tickets`): building × category, colour = SLA breach rate (single-hue sequential blue).
4. **Watch-list table** (`retention_watchlist`): filter `Churn Risk` (default High), sorted by `Contract Rent Pa Eur` desc. This is the sheet the leasing team uses weekly.

## Dashboard 4 (optional): Cash
1. Stacked bar of `Open Eur` by building, colour = SC recon part vs other, filtered to `180+ days`.
2. Aging bucket bars sorted by `Aging sort`.

---

## Published
Executive overview: https://public.tableau.com/views/CommercialPropertyLeasingAnalytics-Bulgaria/ExecutiveOverview
