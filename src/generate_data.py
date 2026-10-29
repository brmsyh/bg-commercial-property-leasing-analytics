"""
Generate the (anonymised) raw extracts used in this project.

The client's real ERP / CAFM exports cannot be published, so this script rebuilds
statistically equivalent data with the same structure, volumes and data-quality
issues that were found during the engagement. Tenant and building identities are
replaced by codes.

Output: data/raw/*.csv
    buildings.csv, units.csv, tenants.csv, leases.csv,
    invoice_lines_2021_2023.csv, invoice_lines_2024_2025.csv (split to stay under
    GitHub's 25 MB browser-upload limit), payments.csv, maintenance_tickets.csv

Run:  python src/generate_data.py
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pandas as pd

SEED = 20250311
rng = np.random.default_rng(SEED)

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
RAW.mkdir(parents=True, exist_ok=True)

WINDOW_START = pd.Timestamp("2021-01-01")
N_MONTHS = 60                                   # Jan-2021 .. Dec-2025
AS_OF = pd.Timestamp("2025-12-31")
MONTHS = pd.date_range(WINDOW_START, periods=N_MONTHS, freq="MS")
BGN_PER_EUR = 1.95583

# ---------------------------------------------------------------------------
# 1. Portfolio: 26 buildings in Sofia, Plovdiv, Varna and Burgas
# ---------------------------------------------------------------------------
#   code, city, asset_type, grade, year_built, maintenance multiplier,
#   slow-resolution multiplier, pricing premium (asking vs market)
BUILDINGS = [
    ("SOF-A01", "Sofia", "Office", "A", 2016, 1.0, 1.0, 0.02),
    ("SOF-A02", "Sofia", "Office", "A", 2019, 0.9, 0.9, 0.03),
    ("SOF-A03", "Sofia", "Office", "A", 2012, 1.1, 1.0, 0.02),
    ("SOF-A04", "Sofia", "Office", "A", 2020, 0.8, 0.9, 0.04),
    ("SOF-B05", "Sofia", "Office", "B", 2006, 1.2, 1.1, 0.01),
    ("SOF-B06", "Sofia", "Office", "B", 2004, 1.3, 1.1, 0.15),
    ("SOF-B07", "Sofia", "Office", "B", 1998, 3.1, 2.3, 0.02),
    ("SOF-B08", "Sofia", "Office", "B", 2008, 1.1, 1.0, 0.00),
    ("SOF-M09", "Sofia", "Mixed", "A", 2015, 1.0, 1.0, 0.03),
    ("SOF-M10", "Sofia", "Mixed", "B", 2009, 1.2, 1.1, 0.01),
    ("SOF-R11", "Sofia", "Retail", "A", 2013, 1.0, 1.0, 0.03),
    ("SOF-R12", "Sofia", "Retail", "B", 2007, 1.2, 1.1, 0.14),
    ("SOF-R13", "Sofia", "Retail", "A", 2018, 0.9, 0.9, 0.02),
    ("SOF-B14", "Sofia", "Office", "B", 2003, 1.8, 1.4, 0.01),
    ("PDV-A01", "Plovdiv", "Office", "A", 2017, 1.0, 1.0, 0.02),
    ("PDV-B02", "Plovdiv", "Office", "B", 2005, 1.3, 1.1, 0.16),
    ("PDV-R03", "Plovdiv", "Retail", "A", 2014, 1.0, 1.0, 0.02),
    ("PDV-M04", "Plovdiv", "Mixed", "B", 2010, 1.1, 1.0, 0.01),
    ("PDV-R05", "Plovdiv", "Retail", "B", 2008, 1.2, 1.1, 0.02),
    ("VAR-A01", "Varna", "Office", "A", 2015, 1.0, 1.0, 0.02),
    ("VAR-R02", "Varna", "Retail", "B", 2006, 2.9, 2.1, 0.03),
    ("VAR-M03", "Varna", "Mixed", "B", 2011, 1.1, 1.0, 0.01),
    ("VAR-B04", "Varna", "Office", "B", 2002, 1.4, 1.2, 0.15),
    ("BGS-R01", "Burgas", "Retail", "B", 2009, 1.2, 1.1, 0.02),
    ("BGS-A02", "Burgas", "Office", "A", 2019, 0.9, 0.9, 0.02),
    ("BGS-M03", "Burgas", "Mixed", "B", 2012, 1.1, 1.0, 0.01),
]
# buildings where retail tenants disputed the 2022 service-charge reconciliation
DISPUTE_BUILDINGS = {"VAR-R02", "PDV-R05", "BGS-R01", "SOF-R12"}

MARKET_RENT = {  # EUR / sqm / month, 2022 level
    ("Office", "Sofia", "A"): 17.5, ("Office", "Sofia", "B"): 12.0,
    ("Office", "Plovdiv", "A"): 11.0, ("Office", "Plovdiv", "B"): 8.5,
    ("Office", "Varna", "A"): 11.0, ("Office", "Varna", "B"): 8.0,
    ("Office", "Burgas", "A"): 10.0, ("Office", "Burgas", "B"): 7.5,
    ("Retail", "Sofia", "A"): 28.0, ("Retail", "Sofia", "B"): 19.0,
    ("Retail", "Plovdiv", "A"): 18.0, ("Retail", "Plovdiv", "B"): 13.0,
    ("Retail", "Varna", "A"): 16.0, ("Retail", "Varna", "B"): 14.0,
    ("Retail", "Burgas", "A"): 14.0, ("Retail", "Burgas", "B"): 12.0,
}
MARKET_GROWTH = {2016: .95, 2017: .95, 2018: .96, 2019: .97, 2020: .97,
                 2021: .97, 2022: 1.00, 2023: 1.06, 2024: 1.10, 2025: 1.13}
HICP = {2016: .002, 2017: .012, 2018: .026, 2019: .025, 2020: .012,
        2021: .026, 2022: .084, 2023: .054, 2024: .024, 2025: .022}
# service charge: estimate billed monthly vs actual cost index (energy shock 2022)
SC_EST_FACTOR = {2021: 1.00, 2022: 1.03, 2023: 1.30, 2024: 1.15, 2025: 1.08}
SC_ACT_FACTOR = {2021: 0.98, 2022: 1.38, 2023: 1.12, 2024: 1.03, 2025: 1.02}
ENERGY_IDX = {2021: 1.0, 2022: 1.55, 2023: 1.25, 2024: 1.10, 2025: 1.06}

OFFICE_IND = ["IT & Software", "BPO / Shared Services", "Finance & Insurance",
              "Professional Services", "Pharma & Healthcare", "Engineering",
              "Public Sector / NGO", "Media & Marketing", "Education"]
OFFICE_IND_P = [.27, .17, .11, .14, .08, .08, .05, .06, .04]
RETAIL_IND = ["Fashion & Apparel", "Food & Beverage", "Grocery", "Health & Beauty",
              "Electronics", "Services", "Home & Furnishing", "Entertainment"]
RETAIL_IND_P = [.28, .22, .05, .14, .08, .12, .07, .04]

TICKET_CATS = ["HVAC", "Electrical", "Plumbing", "Elevator", "Cleaning",
               "Access & Security", "Lighting", "Fit-out / Carpentry",
               "Pest Control", "IT & Telecom"]
TICKET_P_NORMAL = np.array([.20, .14, .13, .06, .14, .09, .09, .07, .03, .05])
TICKET_P_PROBLEM = np.array([.44, .11, .11, .07, .08, .05, .05, .04, .02, .03])
PRIORITIES = ["Low", "Medium", "High", "Critical"]
PRIORITY_P = [.30, .42, .21, .07]
SLA_HOURS = {"Low": 168, "Medium": 72, "High": 24, "Critical": 4}


def month_index(ts: pd.Timestamp) -> int:
    return (ts.year - 2021) * 12 + ts.month - 1


def add_months(ts: pd.Timestamp, m: int) -> pd.Timestamp:
    return (ts + pd.DateOffset(months=int(m))).normalize()


# ---------------------------------------------------------------------------
# 2. Units
# ---------------------------------------------------------------------------
b_rows, u_rows = [], []
uid = 0
for bi, (code, city, atype, grade, yb, mmult, smult, prem) in enumerate(BUILDINGS, start=1):
    n_units = {"Office": rng.integers(88, 132), "Retail": rng.integers(112, 160),
               "Mixed": rng.integers(100, 140)}[atype]
    floors = {"Office": rng.integers(6, 14), "Retail": 3, "Mixed": rng.integers(5, 10)}[atype]
    gla = 0.0
    for k in range(n_units):
        if atype == "Office":
            utype = "Office"
        elif atype == "Retail":
            utype = "Retail"
        else:
            utype = "Retail" if k < int(n_units * 0.27) else "Office"
        if utype == "Office":
            area = float(np.clip(rng.lognormal(math.log(175), 0.7), 40, 1600))
            floor = int(rng.integers(1, floors + 1)) if atype == "Office" else int(rng.integers(1, floors + 1))
        else:
            area = float(np.clip(rng.lognormal(math.log(105), 0.85), 18, 2600))
            floor = int(rng.choice([0, 0, 0, 1, 1, 2])) if atype == "Retail" else 0
        area = round(area, 1)
        gla += area
        mkt = MARKET_RENT[(utype, city, grade)]
        size_adj = (150 / area) ** 0.06            # small units rent higher per sqm
        unit_factor = float(rng.lognormal(0, 0.10)) * size_adj
        if utype == "Retail" and floor == 0:
            unit_factor *= 1.12
        premium = float(rng.normal(prem, 0.04))
        uid += 1
        u_rows.append(dict(unit_id=f"U{uid:05d}", building_id=bi, unit_code=f"{code}-{floor:02d}{k + 1:03d}",
                           floor=floor, unit_type=utype, area_sqm=area,
                           _mkt=mkt * unit_factor, _premium=premium, _city=city, _grade=grade,
                           _bcode=code, _mmult=mmult, _smult=smult, _atype=atype))
    b_rows.append(dict(building_id=bi, building_code=code, city=city, asset_type=atype, grade=grade,
                       year_built=yb, floors=int(floors), gla_sqm=round(gla, 1)))

units = pd.DataFrame(u_rows)
buildings = pd.DataFrame(b_rows)

# ---------------------------------------------------------------------------
# 3. Lease / vacancy / maintenance simulation per unit
# ---------------------------------------------------------------------------
tenants: list[dict] = []
leases: list[dict] = []
tickets: list[dict] = []
lease_seq = 0
ticket_seq = 0


def new_tenant(utype: str, area: float, since: pd.Timestamp) -> dict:
    tid = f"T{len(tenants) + 1:05d}"
    if utype == "Office":
        ind = rng.choice(OFFICE_IND, p=OFFICE_IND_P)
    else:
        ind = rng.choice(RETAIL_IND, p=RETAIL_IND_P)
    seg = "Large" if area >= 600 else ("Mid" if area >= 180 else "SME")
    # payer behaviour: probability of paying on time
    payer = float(np.clip(rng.beta(7, 2), 0.05, 0.99))
    if seg == "SME":
        payer *= 0.93
    t = dict(tenant_id=tid, industry=ind, segment=seg, first_seen=since,
             _payer=payer, _loyalty=float(rng.normal(0, 0.55)))
    tenants.append(t)
    return t


def gen_tickets(u: dict, t: dict, lease_id: str, m_from: int, m_to: int) -> tuple[int, int, list]:
    """Generate tickets for months [m_from, m_to). Returns (#tickets, #SLA breaches) per month list."""
    global ticket_seq
    problem = u["_mmult"] >= 2.5
    p_cat = TICKET_P_PROBLEM if problem else TICKET_P_NORMAL
    lam = (0.075 + u["area_sqm"] / 3000) * u["_mmult"]
    per_month = []
    for m in range(max(m_from, 0), min(m_to, N_MONTHS)):
        mon = MONTHS[m]
        season = 1.25 if mon.month in (6, 7, 8) else (1.12 if mon.month in (1, 2, 12) else 1.0)
        n = rng.poisson(lam * season)
        nb = 0
        for _ in range(n):
            ticket_seq += 1
            cat = rng.choice(TICKET_CATS, p=p_cat)
            pri = rng.choice(PRIORITIES, p=PRIORITY_P)
            sla = SLA_HOURS[pri]
            created = mon + pd.Timedelta(days=int(rng.integers(0, mon.days_in_month)),
                                         hours=int(rng.integers(7, 20)), minutes=int(rng.integers(0, 60)))
            slow = u["_smult"] * (1.35 if (cat == "HVAC" and problem) else 1.0)
            hours = float(rng.lognormal(math.log(sla * 0.55 * slow), 0.75))
            hours = max(hours, 0.3)
            breach = hours > sla
            nb += int(breach)
            resolved = created + pd.Timedelta(hours=hours)
            status = "Closed"
            if resolved > AS_OF:
                resolved, status = None, "Open"
            reopened = bool(rng.random() < (0.16 if breach else 0.05))
            if status == "Closed":
                base = 4.4 - (1.5 if breach else 0) - (0.6 if reopened else 0)
                rating = int(np.clip(round(rng.normal(base, 0.8)), 1, 5)) if rng.random() < 0.58 else None
            else:
                rating = None
            tickets.append(dict(ticket_id=f"MT{ticket_seq:06d}", unit_id=u["unit_id"],
                                tenant_id=t["tenant_id"], lease_id=lease_id, category=cat,
                                priority=pri, created_at=created, resolved_at=resolved,
                                status=status, reopened=reopened, satisfaction=rating))
        per_month.append((m, n, nb))
    return per_month


def market_rent(u: dict, ts: pd.Timestamp) -> float:
    return u["_mkt"] * MARKET_GROWTH[min(max(ts.year, 2016), 2025)]


for u in units.to_dict("records"):
    utype, area = u["unit_type"], u["area_sqm"]
    # --- initial state at Jan-2021
    occupied0 = rng.random() < (0.90 if u["_grade"] == "A" else 0.84) * (0.93 if u["_premium"] > 0.1 else 1.0)
    if occupied0:
        term = int(rng.choice([36, 60], p=[.6, .4])) if utype == "Office" else int(rng.choice([24, 36, 60], p=[.3, .4, .3]))
        start = add_months(WINDOW_START, -int(rng.integers(1, term)))
        start = start.replace(day=1)
        cursor_tenant = new_tenant(utype, area, start)
        cur_start, cur_term, lease_type, prev_lease = start, term, "New", None
        vacant_from = None
    else:
        cursor_tenant, cur_start = None, None
        vacant_from = WINDOW_START

    t_now = WINDOW_START
    while True:
        if cursor_tenant is None:
            # vacancy spell -> re-letting
            mean_v = (3.2 if u["_grade"] == "A" else 5.2)
            mean_v *= 0.85 if u["_city"] == "Sofia" else 1.15
            mean_v *= math.exp(6.0 * max(u["_premium"], -0.05))
            if vacant_from.year == 2021:
                mean_v *= 1.35
            if utype == "Retail" and u["_grade"] == "B":
                mean_v *= 1.15
            if u["_mmult"] >= 2.5:
                mean_v *= 1.3
            dur = max(1, int(math.ceil(rng.exponential(mean_v))))
            start = add_months(vacant_from, dur)
            if start > AS_OF:
                break
            cursor_tenant = new_tenant(utype, area, start) if rng.random() > 0.06 or not tenants else \
                tenants[int(rng.integers(0, len(tenants)))]
            cur_start = start
            cur_term = int(rng.choice([36, 60], p=[.65, .35])) if utype == "Office" else int(rng.choice([24, 36, 60], p=[.3, .45, .25]))
            lease_type, prev_lease = "New", None

        # --- the lease itself
        lease_seq += 1
        lease_id = f"L{lease_seq:06d}"
        asking = market_rent(u, cur_start) * (1 + u["_premium"])
        if lease_type == "New":
            rent = asking * (1 - rng.uniform(0.0, 0.07))
            rf = int(rng.integers(1, 4)) if utype == "Office" else int(rng.integers(0, 3))
            if cur_start.year <= 2021:
                rf += 1
            if u["_premium"] > 0.1:          # landlord holds headline rent, gives incentives instead
                rf += 1
        else:
            rent = renewal_rent
            rf = int(rng.choice([0, 0, 1]))
        idx_type = rng.choice(["HICP capped 4%", "HICP uncapped", "Fixed 2.5%"], p=[.55, .25, .20])
        end = add_months(cur_start, cur_term) - pd.Timedelta(days=1)

        # early termination (break option / insolvency)
        early_term = None
        if rng.random() < 0.035:
            em = int(rng.integers(6, cur_term - 2))
            early_term = add_months(cur_start, em) - pd.Timedelta(days=1)
        # SME retail tenant defaults in dispute buildings after the 2023 reconciliation
        defaulter = (utype == "Retail" and u["_bcode"] in DISPUTE_BUILDINGS and cursor_tenant["_payer"] < 0.62
                     and cur_start < pd.Timestamp("2023-03-01") < end)
        if defaulter and early_term is None and rng.random() < 0.55:
            early_term = pd.Timestamp("2023-03-01") + pd.DateOffset(months=int(rng.integers(5, 14))) - pd.Timedelta(days=1)
            early_term = early_term.normalize()

        if early_term is not None and early_term >= AS_OF:
            early_term = None
        eff_end = early_term if early_term is not None else end
        m_from, m_to = month_index(cur_start), month_index(eff_end) + 1
        per_month = gen_tickets(u, cursor_tenant, lease_id, m_from, m_to)

        leases.append(dict(lease_id=lease_id, unit_id=u["unit_id"], tenant_id=cursor_tenant["tenant_id"],
                           start_date=cur_start, end_date=end, term_months=cur_term,
                           rent_eur_sqm=round(rent, 2), rent_free_months=rf, indexation=idx_type,
                           lease_type=lease_type, renewal_of=prev_lease,
                           termination_date=early_term, _defaulter=defaulter))

        if eff_end >= AS_OF or (early_term is None and end >= AS_OF):
            break

        if early_term is not None:
            leases[-1]["status"] = "Terminated early"
            cursor_tenant, vacant_from = None, add_months(early_term + pd.Timedelta(days=1), 0)
            continue

        # --- renewal decision at expiry, driven by last-12-month service experience
        last12 = [(n, nb) for (m, n, nb) in per_month if m >= m_to - 12]
        n_t = sum(n for n, _ in last12)
        n_b = sum(nb for _, nb in last12)
        # indexed passing rent at expiry
        yrs = cur_term // 12
        idx = 1.0
        for y in range(1, yrs):
            yr = cur_start.year + y - 1
            infl = HICP.get(yr, 0.025)
            idx *= 1 + (min(infl, 0.04) if idx_type == "HICP capped 4%" else infl if idx_type == "HICP uncapped" else 0.025)
        passing = rent * idx
        offer = max(passing * 1.02, market_rent(u, end) * (1 + max(u["_premium"], 0) * 0.6))
        inc = offer / passing - 1
        logit = (1.15 + (0.35 if u["_grade"] == "A" else 0) - 0.55 * min(n_b, 4) - 0.06 * min(n_t, 12)
                 - 3.5 * max(inc - 0.05, 0) + (0.25 if cursor_tenant["segment"] == "Large" else -0.15 if cursor_tenant["segment"] == "SME" else 0)
                 + cursor_tenant["_loyalty"])
        p_renew = 1 / (1 + math.exp(-logit))
        if rng.random() < p_renew:
            leases[-1]["status"] = "Expired - renewed"
            renewal_rent = offer * (1 - rng.uniform(0, 0.03))
            prev_lease = lease_id
            cur_start = end + pd.Timedelta(days=1)
            cur_term = int(rng.choice([36, 60, 24], p=[.6, .25, .15]))
            lease_type = "Renewal"
        else:
            leases[-1]["status"] = "Expired - vacated"
            cursor_tenant, vacant_from = None, end + pd.Timedelta(days=1)

leases_df = pd.DataFrame(leases).rename(columns={"_defaulter": "defaulter_flag"})
leases_df["status"] = leases_df["status"].fillna("Active")
tenants_df = pd.DataFrame(tenants)
tickets_df = pd.DataFrame(tickets)
print(f"leases {len(leases_df):,}  tenants {len(tenants_df):,}  tickets {len(tickets_df):,}")

# ---------------------------------------------------------------------------
# 4. Billing: invoice lines per lease-month (rent, rent-free, SC, utilities,
#    parking, marketing levy, annual SC reconciliation)
# ---------------------------------------------------------------------------
u_idx = units.set_index("unit_id")
t_idx = tenants_df.set_index("tenant_id")
b_by_id = buildings.set_index("building_id")

SC_BASE = {("Office", "A"): 4.2, ("Office", "B"): 3.2, ("Retail", "A"): 6.0, ("Retail", "B"): 5.0}
lines = []
inv_headers = []
inv_seq = 0
occ_by_year: dict[tuple[str, int], int] = {}   # (lease_id, year) -> months billed

for L in leases_df.itertuples(index=False):
    u = u_idx.loc[L.unit_id]
    area, utype, city, grade = u["area_sqm"], u["unit_type"], u["_city"], u["_grade"]
    eff_end = L.termination_date if pd.notna(L.termination_date) else L.end_date
    m_from, m_to = max(month_index(L.start_date), 0), min(month_index(eff_end) + 1, N_MONTHS)
    if m_from >= m_to:
        continue
    sc_base = SC_BASE[(utype, grade)] * (1.08 if city == "Sofia" else 1.0)
    has_util = utype == "Retail" or rng.random() < 0.55
    has_parking = utype == "Office" and rng.random() < 0.42
    spaces = max(1, int(round(area / 120))) if has_parking else 0
    park_rate = 70.0 if city == "Sofia" else 45.0
    util_k = rng.uniform(0.55, 1.4) * (1.8 if utype == "Retail" else 1.0)
    for m in range(m_from, m_to):
        mon = MONTHS[m]
        k_month = (mon.year - L.start_date.year) * 12 + mon.month - L.start_date.month
        yrs_elapsed = k_month // 12
        idx = 1.0
        for y in range(1, yrs_elapsed + 1):
            infl = HICP.get(L.start_date.year + y - 1, 0.025)
            idx *= 1 + (min(infl, 0.04) if L.indexation == "HICP capped 4%" else infl if L.indexation == "HICP uncapped" else 0.025)
        inv_seq += 1
        inv_id = f"INV{mon.year}{mon.month:02d}-{inv_seq:07d}"
        rent_amt = round(area * L.rent_eur_sqm * idx, 2)
        ls = [("RENT", rent_amt)]
        if k_month < L.rent_free_months:
            ls.append(("RENT_FREE", -rent_amt))
        ls.append(("SERVICE_CHARGE", round(area * sc_base * SC_EST_FACTOR[mon.year], 2)))
        if has_util:
            season = 1.25 if mon.month in (7, 8) else (1.2 if mon.month in (1, 2, 12) else 1.0)
            ls.append(("UTILITIES", round(area * util_k * ENERGY_IDX[mon.year] * season * rng.uniform(0.9, 1.1), 2)))
        if has_parking:
            ls.append(("PARKING", round(spaces * park_rate * (1 + 0.04 * (mon.year - 2021)), 2)))
        if utype == "Retail":
            ls.append(("MARKETING_LEVY", round(area * 0.6, 2)))
        # annual reconciliation billed in March for previous year
        if mon.month == 3 and mon.year >= 2022:
            py = mon.year - 1
            months_prev = occ_by_year.get((L.lease_id, py), 0)
            if months_prev:
                recon = area * sc_base * (SC_ACT_FACTOR[py] - SC_EST_FACTOR[py]) * months_prev
                ls.append(("SC_RECONCILIATION", round(recon, 2)))
        occ_by_year[(L.lease_id, mon.year)] = occ_by_year.get((L.lease_id, mon.year), 0) + 1
        total = 0.0
        for code, amt in ls:
            lines.append((inv_id, L.lease_id, mon, code, amt))
            total += amt
        inv_headers.append((inv_id, L.lease_id, L.tenant_id, mon, round(total, 2),
                            dict(ls).get("SC_RECONCILIATION", 0.0), bool(L.defaulter_flag),
                            L.termination_date if pd.notna(L.termination_date) else None, utype, u["_bcode"]))

lines_df = pd.DataFrame(lines, columns=["invoice_id", "lease_id", "billing_month", "charge_code", "amount_eur"])
inv_df = pd.DataFrame(inv_headers, columns=["invoice_id", "lease_id", "tenant_id", "billing_month", "total",
                                            "recon", "defaulter", "term_date", "utype", "bcode"])
print(f"invoice lines {len(lines_df):,}  invoices {len(inv_df):,}")

# ---------------------------------------------------------------------------
# 5. Payments (cash receipts) up to AS_OF
# ---------------------------------------------------------------------------
payer = inv_df["tenant_id"].map(t_idx["_payer"]).to_numpy()
n = len(inv_df)
due = inv_df["billing_month"] + pd.Timedelta(days=14)
on_time = rng.random(n) < payer
late_days = np.where(on_time, -rng.integers(0, 10, n), np.ceil(rng.gamma(1.6, 11 / np.maximum(payer, .2), n)))
pay_date = due + pd.to_timedelta(late_days, unit="D")
pay_amt = inv_df["total"].to_numpy().copy()

# disputed 2022 reconciliation in some retail buildings: tenants withhold the recon amount
disp = ((inv_df["bcode"].isin(DISPUTE_BUILDINGS)) & (inv_df["utype"] == "Retail") &
        (inv_df["billing_month"] == pd.Timestamp("2023-03-01")) & (inv_df["recon"] > 0))
withhold = disp & (rng.random(n) < 0.62)
pay_amt = np.where(withhold, pay_amt - inv_df["recon"].to_numpy(), pay_amt)
# defaulting tenants stop paying in the months before they leave
stop = inv_df["defaulter"] & inv_df["term_date"].notna() & \
    (inv_df["billing_month"] > inv_df["term_date"].fillna(AS_OF) - pd.DateOffset(months=5))
pay_amt = np.where(stop, 0.0, pay_amt)
# random partial payments
partial = (~stop) & (rng.random(n) < 0.004)
pay_amt = np.where(partial, np.round(pay_amt * rng.uniform(0.3, 0.8, n), 2), pay_amt)
# negative invoice totals (credit notes from recon) are offset, not paid
pay_amt = np.where(inv_df["total"].to_numpy() <= 0, 0.0, pay_amt)

pay = pd.DataFrame({"invoice_id": inv_df["invoice_id"], "tenant_id": inv_df["tenant_id"],
                    "payment_date": pay_date, "amount_eur": np.round(pay_amt, 2)})
pay = pay[(pay["amount_eur"] > 0) & (pay["payment_date"] <= AS_OF)].copy()
# a part of payments arrive in two instalments
split = rng.random(len(pay)) < 0.07
p2 = pay[split].copy()
first = np.round(p2["amount_eur"] * rng.uniform(0.4, 0.7, len(p2)), 2)
p2_second = p2.copy()
p2["amount_eur"] = first
p2_second["amount_eur"] = (p2_second["amount_eur"] - first).round(2)
p2_second["payment_date"] = p2_second["payment_date"] + pd.to_timedelta(rng.integers(7, 40, len(p2)), unit="D")
p2_second = p2_second[p2_second["payment_date"] <= AS_OF]
pay = pd.concat([pay[~split], p2, p2_second]).sort_values("payment_date").reset_index(drop=True)
pay.insert(0, "payment_id", [f"PMT{i + 1:07d}" for i in range(len(pay))])
pay["method"] = rng.choice(["Bank transfer", "SEPA", "Direct debit", "Card"], len(pay), p=[.62, .2, .15, .03])
print(f"payments {len(pay):,}")

# ---------------------------------------------------------------------------
# 6. Write raw extracts WITH the data-quality issues seen in the source systems
# ---------------------------------------------------------------------------
def messy_city(c: str) -> str:
    r = rng.random()
    variants = {"Sofia": ["SOFIA", "Sofia ", "Sofiya", "sofia"], "Plovdiv": ["PLOVDIV", " Plovdiv"],
                "Varna": ["VARNA", "varna "], "Burgas": ["Bourgas", "BURGAS", "burgas"]}
    return rng.choice(variants[c]) if r < 0.45 else c


# book value (latest external valuation) used for gross-yield analysis - deterministic
CAP_VALUE = {("Office", "Sofia", "A"): 3200, ("Office", "Sofia", "B"): 2150, ("Retail", "Sofia", "A"): 4300,
             ("Retail", "Sofia", "B"): 2850, ("Mixed", "Sofia", "A"): 3400, ("Mixed", "Sofia", "B"): 2350}
def cap_value(r):
    base = CAP_VALUE.get((r.asset_type, "Sofia", r.grade), 1800)
    city_k = {"Sofia": 1.0, "Plovdiv": 0.68, "Varna": 0.70, "Burgas": 0.62}[r.city]
    age_k = 1 - 0.006 * (2025 - r.year_built)
    return round(r.gla_sqm * base * city_k * age_k, -4)
buildings["book_value_eur"] = [cap_value(r) for r in buildings.itertuples()]

# market rent benchmark (broker quarterly report, Q4-2025) used to judge asking rents
REF = ROOT / "data" / "reference"
REF.mkdir(parents=True, exist_ok=True)
pd.DataFrame([dict(unit_type=t, city=c, grade=g, benchmark_rent_eur_sqm=round(v * MARKET_GROWTH[2025] * 2) / 2,
                   source="Broker market report Q4-2025")
              for (t, c, g), v in MARKET_RENT.items()]).to_csv(REF / "market_rent_benchmark.csv", index=False)

b_out = buildings.copy()
b_out["city"] = b_out["city"].map(messy_city)
b_out["asset_type"] = [a.upper() if rng.random() < .2 else a for a in b_out["asset_type"]]
b_out.to_csv(RAW / "buildings.csv", index=False)

u_out = units[["unit_id", "building_id", "unit_code", "floor", "unit_type", "area_sqm"]].copy()
u_out["asking_rent_eur_sqm"] = (units["_mkt"] * MARKET_GROWTH[2025] * (1 + units["_premium"])).round(2)
u_out["area_sqm"] = u_out["area_sqm"].astype(str)
mask = rng.random(len(u_out)) < 0.03
u_out.loc[mask, "area_sqm"] = u_out.loc[mask, "area_sqm"].str.replace(".", ",", regex=False)
bad = rng.choice(len(u_out), 9, replace=False)
u_out.loc[u_out.index[bad[:5]], "area_sqm"] = "0"
u_out.loc[u_out.index[bad[5:]], "area_sqm"] = (-units.loc[bad[5:], "area_sqm"]).astype(str).values
u_out["unit_type"] = [x.lower() if rng.random() < .08 else (x + " " if rng.random() < .05 else x) for x in u_out["unit_type"]]
u_out.to_csv(RAW / "units.csv", index=False)

t_out = tenants_df[["tenant_id", "industry", "segment", "first_seen"]].copy()
t_out["first_seen"] = t_out["first_seen"].dt.strftime("%Y-%m-%d")
blank = rng.random(len(t_out)) < 0.04
t_out.loc[blank, "industry"] = ""
t_out["industry"] = [x + "  " if (x and rng.random() < .05) else x for x in t_out["industry"]]
dups = t_out.sample(23, random_state=SEED).copy()
dups["segment"] = dups["segment"].str.upper()
t_out = pd.concat([t_out, dups]).sort_values("tenant_id").reset_index(drop=True)
t_out.to_csv(RAW / "tenants.csv", index=False)


def messy_date(d) -> str:
    if pd.isna(d):
        return ""
    r = rng.random()
    if r < 0.70:
        return d.strftime("%Y-%m-%d")
    if r < 0.88:
        return d.strftime("%d.%m.%Y")
    return d.strftime("%d/%m/%Y")


l_out = leases_df.drop(columns=["defaulter_flag"]).copy()
cur = rng.choice(["EUR", "eur", "€", "BGN"], len(l_out), p=[.78, .07, .05, .10])
l_out["currency"] = cur
l_out["rent_per_sqm"] = np.where(cur == "BGN", (l_out["rent_eur_sqm"] * BGN_PER_EUR).round(2), l_out["rent_eur_sqm"])
l_out = l_out.drop(columns=["rent_eur_sqm"])
for c in ["start_date", "end_date", "termination_date"]:
    l_out[c] = [messy_date(d) for d in l_out[c]]
l_out["status"] = [s.upper() if rng.random() < .06 else s for s in l_out["status"]]
l_out = l_out[["lease_id", "unit_id", "tenant_id", "lease_type", "renewal_of", "start_date", "end_date",
               "term_months", "termination_date", "rent_per_sqm", "currency", "rent_free_months",
               "indexation", "status"]]
l_out.to_csv(RAW / "leases.csv", index=False)

li = lines_df.copy()
li.insert(0, "line_id", np.arange(1, len(li) + 1))
li["billing_month"] = li["billing_month"].dt.strftime("%Y-%m-%d")
r = rng.random(len(li))
li["charge_code"] = np.where(r < 0.03, li["charge_code"].str.lower(),
                             np.where(r < 0.05, li["charge_code"] + " ", li["charge_code"]))
amt = li["amount_eur"].map(lambda v: f"{v:.2f}")
comma = rng.random(len(li)) < 0.02
amt[comma] = amt[comma].str.replace(".", ",", regex=False)
li["amount_eur"] = amt
dup = li.sample(frac=0.003, random_state=SEED)
li = pd.concat([li, dup]).sort_values(["line_id"]).reset_index(drop=True)
early = li["billing_month"] < "2024-01-01"
li[early].to_csv(RAW / "invoice_lines_2021_2023.csv", index=False)
li[~early].to_csv(RAW / "invoice_lines_2024_2025.csv", index=False)

p_out = pay.copy()
p_out["payment_date"] = p_out["payment_date"].dt.strftime("%Y-%m-%d")
p_out["method"] = [m.upper() if rng.random() < .05 else m for m in p_out["method"]]
pdup = p_out.sample(frac=0.004, random_state=SEED + 1)
p_out = pd.concat([p_out, pdup]).sort_values("payment_id").reset_index(drop=True)
p_out.to_csv(RAW / "payments.csv", index=False)

tk = tickets_df.copy()
r = rng.random(len(tk))
tk["category"] = np.where(r < 0.03, None, np.where(r < 0.06, tk["category"].str.lower(), tk["category"]))
tk.loc[(tk["category"] == "HVAC") & (rng.random(len(tk)) < 0.15), "category"] = "Air conditioning"
tk["priority"] = [p.upper() if rng.random() < .04 else p for p in tk["priority"]]
tk["created_at"] = tk["created_at"].dt.strftime("%Y-%m-%d %H:%M")
tk["resolved_at"] = pd.to_datetime(tk["resolved_at"]).dt.strftime("%Y-%m-%d %H:%M")
# a few records where the technician closed the ticket with a wrong timestamp
badr = tk.sample(41, random_state=SEED).index
tk.loc[badr, "resolved_at"] = (pd.to_datetime(tk.loc[badr, "created_at"]) - pd.Timedelta(days=1)).dt.strftime("%Y-%m-%d %H:%M")
tk["satisfaction"] = tk["satisfaction"].astype("Int64")
tk.to_csv(RAW / "maintenance_tickets.csv", index=False)

total = sum(len(pd.read_csv(RAW / f, usecols=[0])) for f in
            ["buildings.csv", "units.csv", "tenants.csv", "leases.csv", "invoice_lines_2021_2023.csv", "invoice_lines_2024_2025.csv",
             "payments.csv", "maintenance_tickets.csv"])
print(f"raw invoice_lines rows: {len(li):,} | total raw rows: {total:,}")
