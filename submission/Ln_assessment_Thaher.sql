-- LINKNET TECHNICAL ASSESSMENT
-- Data Analyst & Visualization
-- Quratul N.O Thaher
-- PostgreSQL (DBeaver)

-- DATASET
--   homepass_fin
--   subscription_snapshot_fin
--   servco_fin
--   media_package_fin
--   region_master_fin

-- NOTE ON TYPE CASTING
-- The source CSVs were loaded without a predefined schema, so all columns arrive as text. Queries cast explicitly where needed: (ex= ::int, ::date, ::numeric) --> loaded data untouched


-- SECTION 0: INITIAL CHECKS
-- 1. overall coverage
select count(distinct snapshot_date) as total_month,
	count(distinct homeid) as total_homepass,
	min(snapshot_date) as period_start,
	max(snapshot_date) as period_end,
	count(*) as total_rows
from subscription_snapshot_fin;
-- finding: 12 months, 1,000 homepasses, Jan-Dec 2025 with 14,136 rows


-- 2. homes coverage
select snapshot_date,
	count(distinct homeid) as tot_homes,
	count(*) as rows_coverage
from subscription_snapshot_fin
group by snapshot_date
order by snapshot_date;
-- finding: 831 homes Jan-Jun, 1,000 from Jul to December

-- 3. homeid with multiple row
select snapshot_date, homeid, count(*) as total_rows
from subscription_snapshot_fin
group by snapshot_date, homeid
having count(*) > 1;
-- finding: 3,150 homeid recorded in more than 1 row


-- 4. true duplicates check
with home_month as (
select snapshot_date, homeid, count(*) as row_count, count(distinct servco_id) as distinct_servco, sum(active_flag::int) as active_rows
    from subscription_snapshot_fin
    group by snapshot_date, homeid
)
select row_count, count(*) as groups, count(*) filter (where distinct_servco > 1) as multi_servco_groups,
    count(*) filter (where active_rows > 1) as multi_active_groups
from home_month
where row_count > 1
group by row_count;
-- assumption: 3,150 groups, all two servcos on one home --> open-access competition signal (not data issue)
-- 547 groups have both servcos flagged active on the same home, which is not possible

-- 0.5 exclusivity pattern
with duplicate as (
select snapshot_date, homeid
from subscription_snapshot_fin
group by snapshot_date, homeid
having count(*) > 1
)
select h.exclusive_flag, h.technology, count(*) as duplicate_groups
from duplicate d
join homepass_fin h on d.homeid = h.homeid
group by h.exclusive_flag, h.technology
order by duplicate_groups desc;
-- assumption: 450 groups are found on exclusive nodes (Y), where only one servco should be present which suggests exclusivity is not enforced in the source system


-- 0.6 bandwith check
select count(*) as accounts_varied_bandwidth
from (select contract_account
	from subscription_snapshot_fin
	where contract_account <> ''
	group by contract_account
    having count(distinct bandwidth_mbps) > 1
) t;
-- 855 accounts change bandwidth tier month to month
-- assumption: bandwidth_mbps is unreliable and is excluded from the analysis

-- SECTION 1: INFRASTRUCTURE & UTILIZATION

-- 1.1a network level penetration rate (monthly)
select s.snapshot_date::date as snapshot_month,
	count(distinct s.homeid) as total_homepass,
	count(distinct s.homeid) filter (where s.active_flag::int = 1) as active_ca,
	round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
group by snapshot_month
order by snapshot_month;
-- finding: 38.39% in January rising to 69.60% in December
-- July drop 64.38% to 58.30% is a denominator effect --> active CAs rose 535 -> 583


-- 1.1b penetration by region
select h.region, s.snapshot_date::date as snapshot_month,
count(distinct s.homeid) as total_homepass,
count(distinct s.homeid) filter (where s.active_flag::int = 1) as active_ca,
round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
group by h.region, snapshot_month
order by h.region, snapshot_month;
-- finding: Bekasi strongest (80% in December), Jakarta Pusat and Selatan weakest (63,60%)

-- 1.1c penetration by technology
select h.technology, s.snapshot_date::date as snapshot_month, count(distinct s.homeid) as total_homepass,
count(distinct s.homeid) filter (where s.active_flag::int = 1) as active_ca,
round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
group by h.technology, snapshot_month
order by h.technology, snapshot_month;
-- finding: HFC leads FTTH with 73.67% vs 68.01% in December


-- 1.1d penetration by access status
select case
	when h.exclusive_flag = 'Y' and s.snapshot_date::date between h.exclusive_start_date::date and h.exclusive_end_date::date then 'Exclusive'
	when h.exclusive_flag = 'Y' then 'Post-exclusive'
	else 'Open access'
    end as access_status,
    s.snapshot_date::date as snapshot_month,
    count(distinct s.homeid) as total_homepass,
    count(distinct s.homeid) filter (where s.active_flag::int = 1) as active_ca,
    round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
group by access_status, snapshot_month
order by access_status, snapshot_month;
-- finding: exclusive nodes 45.68% -> 74.07% over H1; open access 37.60% -> 74%

-- 1.2a utilization at year end, by node and technology
select h.fibernode, h.technology,
	max(h.region) as region,
	count(distinct s.homeid) as homepass,
	round(avg(h.capex_cost::numeric), 0) as avg_capex_per_home,
	round(count(distinct s.homeid) * avg(h.capex_cost::numeric), 0) as total_capex,
	count(distinct s.homeid) filter (where s.active_flag::int = 1)  as active_ca_year_end,
	round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_dec_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
where s.snapshot_date::date = date '2025-12-31'
group by h.fibernode, h.technology
order by penetration_dec_percent asc;
-- finding: worst fibernode = F708541 FTTH in Jakarta Selatan with 37.14% penetration

-- 1.2b underperforming fibernodes
with node_capex as (
select fibernode,
	count(distinct homeid) as homepass,
	round(count(distinct homeid) * avg(capex_cost::numeric), 0) as total_capex
    from homepass_fin
    group by fibernode
),
node_revenue as (
    select h.fibernode,
    	sum(s.active_flag::int * sc.lease_fee_per_active::numeric) as lease_revenue_2025
    from subscription_snapshot_fin s
    join homepass_fin h on s.homeid = h.homeid
    join servco_fin sc  on s.servco_id::int = sc.servco_id::int
    group by h.fibernode
)
select c.fibernode, c.homepass, c.total_capex, r.lease_revenue_2025,
	round(r.lease_revenue_2025 * 100.0 / nullif(c.total_capex, 0), 2) as revenue_to_capex_percent,
	round(c.total_capex / nullif(r.lease_revenue_2025, 0), 1) as payback_years
from node_capex c
join node_revenue r on c.fibernode = r.fibernode
order by revenue_to_capex_percent asc;
-- finding: F708541 recovers 6.58% of capex per year: 15.2-year payback against a ~5-year median

-- 1.3a exclusive vs open access
select case
when h.exclusive_flag = 'Y' and s.snapshot_date::date between h.exclusive_start_date::date and h.exclusive_end_date::date then 'Exclusive'
when h.exclusive_flag = 'Y' then 'Post-exclusive'
else 'Open access'
end as access_status,
s.snapshot_date::date as snapshot_month,
count(distinct s.homeid) as homepass,
sum(s.active_flag::int * sc.lease_fee_per_active::numeric) as lease_revenue,
round(sum(s.active_flag::int * sc.lease_fee_per_active::numeric) / count(distinct s.homeid), 0) as revenue_per_homepass
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
join servco_fin sc  on s.servco_id::int = sc.servco_id::int
group by access_status, snapshot_month
order by access_status, snapshot_month;

-- 1.3b revenue per homepass: FTTH vs HFC
select h.technology, s.snapshot_date::date as snapshot_month, count(distinct s.homeid) as homepass,
sum(s.active_flag::int * sc.lease_fee_per_active::numeric) as lease_revenue,
round(sum(s.active_flag::int * sc.lease_fee_per_active::numeric) / count(distinct s.homeid), 0) as revenue_per_homepass
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
join servco_fin sc  on s.servco_id::int = sc.servco_id::int
group by h.technology, snapshot_month
order by h.technology, snapshot_month;
-- finding: HFC 107,064 vs FTTH 99,001 per homepass in December
-- assumption: all segments decline in December, the first net churn of the year


-- 1.4a structural pattern: the post-exclusive decline is a composition effect
select s.snapshot_date::date as snapshot_month,
case when c.months_present = 12 then 'Legacy exclusive'
else 'Entered Jul 2025' end as cohort,
	count(distinct s.homeid) as homepass,
    count(distinct s.homeid) filter (where s.active_flag::int = 1)  as active_ca,
    round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
join (
select homeid, count(distinct snapshot_date) as months_present
from subscription_snapshot_fin
group by homeid
) c on s.homeid = c.homeid
where h.exclusive_flag = 'Y'
group by snapshot_month, cohort
order by cohort, snapshot_month;
-- finding: the legacy exclusive homes went 74.07% (Jun) -> 77.78% (Jul): they did not decline
-- the 169 new homes entered at 11.24% and reached 47.93% by December


-- SECTION 2: SERVCO PERFORMANCE & COMPETITION

-- 2.1a active CA growth and lease revenue contribution
select sc.servco_id, sc.servco_name, sc.lease_fee_per_active::numeric as lease_fee,
	count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-01-31' and s.active_flag::int = 1) as active_jan,
	count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1) as active_dec,
	sum(s.active_flag::int * sc.lease_fee_per_active::numeric) as lease_revenue_2025,
	round(sum(s.active_flag::int * sc.lease_fee_per_active::numeric) * 100.0 / sum(sum(s.active_flag::int * sc.lease_fee_per_active::numeric)) over (), 2) as percent_of_revenue
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
group by sc.servco_id, sc.servco_name, sc.lease_fee_per_active
order by lease_revenue_2025 desc;
-- finding: XLS leads revenue at 26.91%, helped by the highest lease fee (140,000)

-- 2.1b penetration rate by servco (December)
select sc.servco_name, count(distinct s.homeid) as addressable_homes,
	count(distinct s.homeid) filter (where s.active_flag::int = 1)  as active_ca,
	round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
where s.snapshot_date::date = date '2025-12-31'
group by sc.servco_name
order by penetration_percent desc;
-- finding: XLS 65.06% highest, INFOCOM 52.28% lowest


-- 2.2 XLS (servco 101) against its 25% minimum guarantee
select s.snapshot_date::date as snapshot_month,
	count(distinct s.homeid) filter (where s.servco_id::int = 101) as xls_addressable,
	count(distinct s.homeid) filter (where s.servco_id::int = 101 and s.active_flag::int = 1) as xls_active,
    round(count(distinct s.homeid) filter (where s.servco_id::int = 101 and s.active_flag::int = 1) * 100.0 / nullif(count(distinct s.homeid) filter (where s.servco_id::int = 101), 0), 2) as xls_penetration_pct, 25.00 as mg_pct,
    round(count(distinct s.homeid) filter (where s.servco_id::int = 101 and s.active_flag::int = 1) * 100.0 / nullif(count(distinct s.homeid) filter (where s.servco_id::int = 101), 0) - 25.00, 2) as gap_vs_mg_pp
from subscription_snapshot_fin s
group by snapshot_month
order by snapshot_month;
-- assumption: minimum_guarantee 0,25 is read as a guaranteed 25% penetration rate
-- XLS clears the floor in all 12 months

-- 2.3a performance in exclusive window vs post-exclusive
select sc.servco_name,
count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-01-31' and s.active_flag::int = 1) as jan,
count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-06-30' and s.active_flag::int = 1) as jun,
count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1) as dec,
count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-06-30' and s.active_flag::int = 1) - count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-01-31' and s.active_flag::int = 1) as h1_growth,
count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1) - count(distinct s.homeid) filter (where s.snapshot_date::date = date '2025-06-30' and s.active_flag::int = 1) as h2_growth
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
group by sc.servco_name
order by h2_growth desc;
-- finding: XLS: +74 in H1 under exclusivity, +14 in H2. The only servco to decelerate.
-- every other servco grew as fast or faster in H2 (post exclusivity)

-- 2.3b single-ISP vs multi-ISP areas
with home_type as (
    select homeid,
    	case when count(distinct servco_id) > 1 then 'Multi-ISP' else 'Single-ISP' end as competition
    from subscription_snapshot_fin
    group by homeid
)
select t.competition,
	count(distinct s.homeid) as homes,
	count(distinct s.homeid) filter (where s.active_flag::int = 1) as active_dec,
	round(count(distinct s.homeid) filter (where s.active_flag::int = 1) * 100.0 / count(distinct s.homeid), 2) as penetration_percent
from subscription_snapshot_fin s
join home_type t on s.homeid = t.homeid
where s.snapshot_date::date = date '2025-12-31'
group by t.competition;
-- finding: multi-ISP homes out-penetrate single-ISP: 73.33% vs 68.00%


-- SECTION 3: MEDIA MONETIZATION & PROFITABILITY

-- 3.1a media attach rate by servco in December
select sc.servco_name,
count(distinct s.contract_account) as active_ca,
count(distinct m.contract_account) as ca_with_media,
round(count(distinct m.contract_account) * 100.0 / nullif(count(distinct s.contract_account), 0), 2) as attach_rate_percent
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
left join media_package_fin m on s.contract_account = m.contract_account
where s.snapshot_date::date = date '2025-12-31'
  and s.active_flag::int = 1
group by sc.servco_name
order by attach_rate_percent desc;
-- finding: MMA strongest upseller at 51.85%, TETRA weakest at 40.94%


-- 3.1b media attach rate by region in December
select h.region,
count(distinct s.contract_account) as active_ca,
count(distinct m.contract_account) as ca_with_media,
round(count(distinct m.contract_account) * 100.0 / nullif(count(distinct s.contract_account), 0), 2) as attach_rate_percent
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
left join media_package_fin m on s.contract_account = m.contract_account
where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1
group by h.region
order by attach_rate_percent desc;
-- finding: Jakarta Pusat best at 53.52%, Jakarta Utara worst at 39.34%
-- assumption: Jakarta Utara worths a focus as media opportunity


-- 3.2a media margin by product
select m.add_on_product,
count(distinct m.contract_account) as subscribers, m.ao_rrp_price::numeric as rrp, m.ao_wholesale_price::numeric as wholesale, m.ao_rrp_price::numeric - m.ao_wholesale_price::numeric as unit_margin,
round((m.ao_rrp_price::numeric - m.ao_wholesale_price::numeric) * 100.0 / m.ao_rrp_price::numeric, 1) as margin_pct,
count(distinct m.contract_account) * (m.ao_rrp_price::numeric - m.ao_wholesale_price::numeric) as total_contribution
from media_package_fin m
group by m.add_on_product, m.ao_rrp_price, m.ao_wholesale_price
order by total_contribution desc;
-- finding: Catchplay is most profitable with highest unit margin (30,000) and highest volume (97 subscribers), contributing 2.91m
-- News Pack is the mismatch: 96 subscribers but only 9,000 unit margin


-- 3.2b lease revenue vs media revenue, December
select sum(s.active_flag::int * sc.lease_fee_per_active::numeric) as lease_revenue,
	sum(coalesce(m.package_price::numeric, 0)) as media_package_revenue,
	sum(coalesce(m.ao_rrp_price::numeric, 0)) as media_addon_revenue,
	sum(coalesce(m.ao_wholesale_price::numeric, 0)) as media_addon_cost,
	sum(coalesce(m.ao_rrp_price::numeric, 0) - coalesce(m.ao_wholesale_price::numeric, 0)) as media_addon_margin
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
left join media_package_fin m on s.contract_account = m.contract_account
where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1;
-- finding: lease 101.3m, media package 32.1m, add-on margin 8.1m

-- 3.3 regions with the highest media monetization potential
-- potential = the margin captured by lifting each region to the best attach
-- rate actually achieved in the network (Jakarta Pusat, 53.52%)
with region_media as (
select h.region, count(distinct s.contract_account) as active_ca, count(distinct m.contract_account) as ca_with_media,
round(count(distinct m.contract_account) * 100.0 / nullif(count(distinct s.contract_account), 0), 2) as attach_rate_percent,
round(avg(coalesce(m.ao_rrp_price::numeric, 0) - coalesce(m.ao_wholesale_price::numeric, 0)) filter (where m.contract_account is not null), 0) as avg_addon_margin
from subscription_snapshot_fin s
join homepass_fin h on s.homeid = h.homeid
left join media_package_fin m on s.contract_account = m.contract_account
where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1
group by h.region
)
select region, active_ca, attach_rate_percent,
round(max(attach_rate_percent) over (), 2) as best_attach_pct,
round(active_ca * (max(attach_rate_percent) over () - attach_rate_percent) / 100, 0) as untapped_accounts,
round(active_ca * (max(attach_rate_percent) over () - attach_rate_percent) / 100 * avg_addon_margin, 0) as monthly_margin_opportunity
from region_media
order by monthly_margin_opportunity desc;
-- finding: Jakarta Utara and Jakarta Barat have the most media potential. 417k/month and 230k/month each
-- these two regions hold 55% of the total 1.18m monthly opportunity


-- 3.4 Is media bundling meaningfully improving ARPU?
select case when m.contract_account is not null then 'With media' else 'No media' end as segment,
count(distinct s.contract_account) as accounts,
round(avg(sc.lease_fee_per_active::numeric), 0) as avg_lease,
round(avg(coalesce(m.package_price::numeric, 0) + coalesce(m.ao_rrp_price::numeric, 0)), 0) as avg_media_revenue,
round(avg(sc.lease_fee_per_active::numeric + coalesce(m.package_price::numeric, 0) + coalesce(m.ao_rrp_price::numeric, 0)), 0) as arpu_gross,
round(avg(sc.lease_fee_per_active::numeric + coalesce(m.package_price::numeric, 0) + coalesce(m.ao_rrp_price::numeric, 0) - coalesce(m.ao_wholesale_price::numeric, 0)), 0) as arpu_net
from subscription_snapshot_fin s
join servco_fin sc on s.servco_id::int = sc.servco_id::int
left join media_package_fin m on s.contract_account = m.contract_account
where s.snapshot_date::date = date '2025-12-31' and s.active_flag::int = 1
group by segment;
-- yes: 243,506 net ARPU with media vs 131,697 without, an 85% uplift
