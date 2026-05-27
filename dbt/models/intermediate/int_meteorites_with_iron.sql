{{ config(materialized='view') }}

-- One row per meteorite, joined to its class dim so `iron_mass_g` and
-- `magnetic_tier` are available per row. This is the single source of
-- truth for "what's the iron content of this rock?" — downstream marts
-- (meteorites_by_class, meteorites_by_s2) consume it instead of redoing
-- the join.
--
-- LEFT JOIN keeps unclassified rows in the table with COALESCE'd
-- iron_mass_g = 0. Marts that want only classified rows can filter on
-- `magnetic_tier IS NOT NULL`.
--
-- Materialised as a view: it's a thin join and downstream marts always
-- aggregate, so paying for a stored copy buys nothing.

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
