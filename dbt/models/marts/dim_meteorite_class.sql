{{ config(materialized='table') }}

-- Pure dimension. One row per class_group, all attributes either sourced
-- from the seed (physical facts) or derived here (interpretation).
--
-- No counts or facts about specific meteorites live here — those belong in
-- aggregate marts. Keeping this dim attribute-only means it changes only
-- when geology changes or when we add a new derived field, not when new
-- meteorites land.

select
    class_group,
    metal_fraction_pct,
    parent_body,
    differentiated,
    source_note,

    -- Derived magnetism label. Cutoffs chosen so 'strong' corresponds to a
    -- handheld magnet visibly snapping to the rock, 'medium' a clear pull,
    -- 'weak' a faint pull detectable on a sensitive setup, 'none' nothing.
    -- Adjust these thresholds here — never in the seed.
    case
        when metal_fraction_pct >= 50 then 'strong'
        when metal_fraction_pct >= 10 then 'medium'
        when metal_fraction_pct >   0 then 'weak'
        else 'none'
    end as magnetic_tier,

    metal_fraction_pct > 0 as is_magnetically_catchable

from {{ ref('meteorite_class_composition') }}
