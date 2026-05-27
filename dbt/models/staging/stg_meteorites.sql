with raw as (

    select * from {{ source('nasa', 'meteorite_landings') }}

)

select
    id,
    name,
    nametype,
    recclass,
    "mass (g)"                as mass_g,
    fall,
    try_cast(year as integer) as year_landed,
    reclat                    as latitude,
    reclong                   as longitude

from raw

where reclat is not null
  and reclong is not null
  and reclat between -90 and 90
  and reclong between -180 and 180
  -- Drop NASA's "(0, 0)" null-placeholder rows. ~6,200 records have lat=0
  -- AND lon=0 — the unmarked-island point in the Gulf of Guinea — used as
  -- a stand-in when the original entry had no recorded coordinates. Using
  -- AND (not OR) so legitimate near-equator / prime-meridian readings stay.
  and not (reclat = 0 and reclong = 0)
  -- Drop NASA's known typo: "Northwest Africa 7701" recorded as year 2101.
  -- Allow nulls (some rows legitimately have unknown year) but reject future
  -- dates outright. Range test on this column catches any new bad data.
  and (year is null or try_cast(year as integer) between 860 and 2025)
