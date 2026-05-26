{{ config(materialized='table') }}

-- The post-1980 spike visible here is from systematic Antarctic survey
-- programmes (ANSMET, JARE) finding decades of accumulated falls — not
-- an actual change in the meteorite influx rate.
select
    (year_landed // 10) * 10               as decade,
    count(*)                               as count,
    sum(mass_g)                            as total_mass_g,
    count(*) filter (where fall = 'Fell')  as falls_witnessed,
    count(*) filter (where fall = 'Found') as finds_recovered
from {{ ref('meteorites') }}
where year_landed is not null
group by decade
order by decade
