-- LEFT JOIN + COALESCE are defensive: every class_group should match a
-- dim row (enforced by the relationships test and the `unknown` seed
-- catch-all), but if one ever slips through, unmatched rows surface with
-- iron_mass_g = 0 and null magnetic_tier rather than disappearing.
-- Downstream consumers (`meteorites_by_class`, `backend/db.py get_yield`)
-- filter on `magnetic_tier IS NOT NULL` as the matching guard.
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
