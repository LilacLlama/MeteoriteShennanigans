-- Final fact table. Carries the canonical `class_group` from
-- `int_meteorites_classified` alongside NASA's original `recclass`. The
-- magnet-yield query joins this to `dim_meteorite_class` on `class_group` to
-- get `metal_fraction_pct` — never re-derive that join in the backend.

select
    m.id,
    m.name,
    m.nametype,
    m.recclass,
    c.class_group,
    m.mass_g,
    m.fall,
    m.year_landed,
    m.latitude,
    m.longitude
from {{ ref('stg_meteorites') }} m
left join {{ ref('int_meteorites_classified') }} c using (id)
