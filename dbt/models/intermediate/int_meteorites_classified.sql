-- Normalize NASA's free-text `recclass` into a canonical `class_group` that
-- joins to the seed (`meteorite_class_composition`).
--
-- NASA's recclass field has 400+ distinct values that follow a handful of
-- patterns — petrologic-type suffixes ("H5", "LL3.8"), shock/anomaly tags
-- ("CR-an", "Eucrite-pmict"), and a "Relict" prefix for weathered samples.
-- The CASE ladder below collapses all of that down to ~35 class groups.
--
-- Ordering matters: more-specific WHEN clauses come first. In particular,
-- mixed ordinary chondrites (H/L, L/LL) MUST be checked before the single-
-- letter L/H rules, since "H/L3" otherwise matches the H rule.

with normalized as (

    select
        id,
        recclass,
        -- Strip leading "Relict " so weathered samples bucket like their
        -- underlying class (e.g. "Relict OC" → OC_unspecified, "Relict H" → H).
        case
            when lower(trim(recclass)) like 'relict %'
                then trim(substring(trim(recclass) from 8))
            else trim(recclass)
        end as rc
    from {{ ref('stg_meteorites') }}

)

select
    id,
    recclass,
    case
        -- Named groups: prefix match on the full class name.
        when lower(rc) like 'iron%'         then 'Iron'
        when lower(rc) like 'pallasite%'    then 'Pallasite'
        when lower(rc) like 'mesosiderite%' then 'Mesosiderite'
        when lower(rc) like 'lunar%'        then 'Lunar'
        when lower(rc) like 'martian%'      then 'Martian'
        when lower(rc) like 'eucrite%'      then 'Eucrite'
        when lower(rc) like 'diogenite%'    then 'Diogenite'
        when lower(rc) like 'howardite%'    then 'Howardite'
        when lower(rc) like 'ureilite%'     then 'Ureilite'
        when lower(rc) like 'aubrite%'      then 'Aubrite'
        when lower(rc) like 'angrite%'      then 'Angrite'
        when lower(rc) like 'acapulcoite%'  then 'Acapulcoite'
        when lower(rc) like 'lodranite%'    then 'Lodranite'
        when lower(rc) like 'winonaite%'    then 'Winonaite'
        when lower(rc) like 'brachinite%'   then 'Brachinite'

        -- Mixed ordinary chondrites — MUST precede the single-letter rules.
        when regexp_matches(rc, '^H/L')  then 'OC_mixed'
        when regexp_matches(rc, '^L/LL') then 'OC_mixed'

        -- Carbonaceous: two-letter subgroup, then digit/punct/end.
        when regexp_matches(rc, '^CI([0-9./~ -]|$)') then 'CI'
        when regexp_matches(rc, '^CM([0-9./~ -]|$)') then 'CM'
        when regexp_matches(rc, '^CO([0-9./~ -]|$)') then 'CO'
        when regexp_matches(rc, '^CV([0-9./~ -]|$)') then 'CV'
        when regexp_matches(rc, '^CK([0-9./~ -]|$)') then 'CK'
        when regexp_matches(rc, '^CR([0-9./~ -]|$)') then 'CR'
        when regexp_matches(rc, '^CH')               then 'CH'
        when regexp_matches(rc, '^CB')               then 'CB'
        when regexp_matches(rc, '^C([0-9./~ -]|$)')  then 'C_ung'

        -- Enstatite.
        when regexp_matches(rc, '^EH')              then 'EH'
        when regexp_matches(rc, '^EL')              then 'EL'
        when regexp_matches(rc, '^E([0-9./~ -]|$)') then 'E'

        -- Ordinary chondrites. LL before L (longest prefix wins).
        when regexp_matches(rc, '^LL')                then 'LL'
        when regexp_matches(rc, '^L([0-9./~ -]|$)')   then 'L'
        when regexp_matches(rc, '^H([0-9(?/.~ -]|$)') then 'H'
        when rc = 'OC'                                then 'OC_unspecified'

        -- Rumuruti and Kakangari chondrites.
        when regexp_matches(rc, '^R([0-9./~ -]|$)') then 'R'
        when regexp_matches(rc, '^K([0-9./~ -]|$)') then 'K'

        -- Generic fallbacks.
        when lower(rc) like '%achondrite%' then 'achondrite_other'
        when lower(rc) like '%chondrite%'  then 'chondrite_other'

        else 'unknown'
    end as class_group

from normalized
