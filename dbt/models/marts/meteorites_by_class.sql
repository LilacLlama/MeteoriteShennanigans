{{ config(materialized='table') }}

-- Aggregate by canonical class group (not raw recclass) so the chart shows
-- ~35 buckets instead of 400, and so magnetic_tier groupings line up.
-- All per-row joins and the iron_mass_g calc live in `int_meteorites_with_iron`
-- so this mart and `meteorites_by_s2` share the exact same definition of
-- "iron content per landing."
--
-- Filter to classified rows only (inner join semantics) since the per-class
-- breakdown only makes sense for known class_groups.

select
    class_group,
    magnetic_tier,
    parent_body,
    differentiated,
    count(*)         as count,
    sum(mass_g)      as total_mass_g,
    avg(mass_g)      as avg_mass_g,
    sum(iron_mass_g) as iron_mass_g,
    min(year_landed) as first_year,
    max(year_landed) as last_year
from {{ ref('int_meteorites_with_iron') }}
where magnetic_tier is not null
group by class_group, magnetic_tier, parent_body, differentiated
order by count desc
