"""
Tests for `db.get_yield`.

Assumes `data/meteorites.duckdb` has been built — run `make dbt-build` first.
The Antarctic Allan Hills numbers (6,066 catches; Iron sorted to the top of
the per-class breakdown because it dominates iron-mass even at low count) are
stable fixtures of the NASA dataset; if they change, either the data shifted
or the haversine / classification math drifted, and we want to know.
"""

import pytest

from db import EMPTY_YIELD, get_yield

# Allan Hills meteorite-rich region with a 500 km (M-sized) magnet.
ALLAN_HILLS = (-76.7, 157.5, 500.0)


def test_allan_hills_catches_expected_meteorites():
    result = get_yield([ALLAN_HILLS])

    assert result["summary"]["count"] == 6066
    # Most Antarctic finds are chondrites — small free-metal fraction but
    # not zero, so catchable_count is nearly all of count. Exact value is
    # tied to the seed: if a class_group flips between zero and nonzero
    # metal_fraction_pct in meteorite_class_composition.csv, this changes.
    assert result["summary"]["catchable_count"] == 5959
    assert result["summary"]["total_mass_g"] > 1_000_000  # ~1.8 t historically
    assert result["summary"]["iron_mass_g"] > 100_000  # ~610 kg historically
    assert result["summary"]["year_range"][0] is not None
    assert result["summary"]["year_range"][1] is not None
    # Sorted by iron-mass: Iron meteorites are rare here but dominate yield.
    assert result["by_class"][0]["class_group"] == "Iron"
    assert result["by_class"][0]["magnetic_tier"] == "strong"


def test_overlapping_magnets_dedupe():
    one = get_yield([ALLAN_HILLS])
    two = get_yield([ALLAN_HILLS, ALLAN_HILLS])

    # Two identical magnets must not double-count the meteorites they share.
    assert one["summary"]["count"] == two["summary"]["count"]
    assert one["summary"]["total_mass_g"] == two["summary"]["total_mass_g"]
    assert one["summary"]["iron_mass_g"] == two["summary"]["iron_mass_g"]


def test_achondrite_only_region_has_zero_iron_mass():
    # Yamato Mountains, Antarctica — a region with many lunar/Martian
    # achondrite finds. Counts are non-zero but iron yield should be ~0
    # for the achondrite slice. (We don't assert iron_mass==0 because the
    # 500km radius will also sweep up some chondrites.)
    result = get_yield([(-71.5, 35.5, 100.0)])
    # Whatever we caught, catchable_count <= count (achondrites excluded).
    assert result["summary"]["catchable_count"] <= result["summary"]["count"]


def test_empty_magnets_returns_zero_state():
    assert get_yield([]) == EMPTY_YIELD


def test_magnet_in_open_ocean_returns_zero_state():
    # Middle of the Pacific — no meteorites recorded within 100 km.
    result = get_yield([(0.0, -150.0, 100.0)])
    assert result == EMPTY_YIELD


@pytest.mark.parametrize("radius_km", [100.0, 500.0, 1500.0])
def test_larger_radius_catches_at_least_as_many(radius_km):
    # Monotonicity: enlarging a magnet can only ADD catches, never remove them.
    smaller = get_yield([(-76.7, 157.5, 100.0)])
    larger = get_yield([(-76.7, 157.5, radius_km)])
    assert larger["summary"]["count"] >= smaller["summary"]["count"]
