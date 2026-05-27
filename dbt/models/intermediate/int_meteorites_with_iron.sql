{{ config(materialized='view') }}

-- One row per meteorite, joined to its class dim so `iron_mass_g` and
-- `magnetic_tier` are available per row. This is the single source of
-- truth for "what's the iron content of this rock?" — downstream marts
-- (meteorites_by_class, meteorites_by_s2) AND the runtime get_yield query
-- in backend/db.py all consume it instead of redoing the join.
--
-- LEFT JOIN keeps unclassified rows in the table with COALESCE'd
-- iron_mass_g = 0. Marts that want only classified rows can filter on
-- `magnetic_tier IS NOT NULL`.
--
-- Materialised as a view: it's a thin join and downstream consumers
-- always aggregate or filter, so paying for a stored copy buys nothing.
--
-- Layer-ordering note: this intermediate refs marts (`meteorites`,
-- `dim_meteorite_class`), inverting the usual staging → intermediate →
-- marts flow. It's intentional — the enrichment makes sense only AFTER
-- both the fact and the dim exist, and dbt doesn't enforce layer order.
-- Alternative would be to rename this `fct_meteorites_enriched` and move
-- it into marts; kept here because it's a thin transformation step, not
-- a business-ready entity.

select
    m.id,
    m.name,
    m.nametype,
    m.recclass,
    m.class_group,
    m.mass_g,
    m.fall,
    m.year_landed,
    m.latitude,
    m.longitude,
    d.metal_fraction_pct,
    d.magnetic_tier,
    d.parent_body,
    d.differentiated,
    d.is_magnetically_catchable,
    coalesce(m.mass_g * d.metal_fraction_pct / 100.0, 0.0) as iron_mass_g
from {{ ref('meteorites') }} m
left join {{ ref('dim_meteorite_class') }} d using (class_group)
