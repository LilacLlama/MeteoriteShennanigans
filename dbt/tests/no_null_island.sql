-- Asserts that the (0, 0) null-placeholder filter in `stg_meteorites` is
-- actually working. NASA's CSV uses lat=0,lon=0 (null-island, Gulf of Guinea)
-- as a stand-in for "we don't know the coordinates" — without this filter
-- ~6,200 rows bucket into the same S2 cell and dominate the heatmap for the
-- wrong reason.
--
-- This is a singular test: dbt runs the query and fails if any rows come back.

SELECT id, name, latitude, longitude
FROM {{ ref('stg_meteorites') }}
WHERE latitude = 0
  AND longitude = 0
