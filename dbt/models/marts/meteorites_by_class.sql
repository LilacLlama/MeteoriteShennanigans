{{ config(materialized='table') }}

select
    recclass,
    count(*)         as count,
    sum(mass_g)      as total_mass_g,
    avg(mass_g)      as avg_mass_g,
    min(year_landed) as first_year,
    max(year_landed) as last_year
from {{ ref('meteorites') }}
group by recclass
order by count desc
