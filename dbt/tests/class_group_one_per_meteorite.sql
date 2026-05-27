-- Asserts the classification + dim join doesn't produce a fan-out. Every
-- meteorite should have exactly one `class_group`; if `int_meteorites_classified`
-- ever returned duplicate rows per id (regex bug? two patterns matching?), the
-- fact table would silently get extra rows and aggregates would over-count.
--
-- Fails the build if any meteorite has >1 distinct class_group.

SELECT
    id,
    COUNT(DISTINCT class_group) AS class_group_count
FROM {{ ref('meteorites') }}
GROUP BY id
HAVING COUNT(DISTINCT class_group) > 1
