{{ config(materialized='table') }}

select
    id,
    name,
    nametype,
    recclass,
    mass_g,
    fall,
    year_landed,
    latitude,
    longitude
from {{ ref('stg_meteorites') }}
