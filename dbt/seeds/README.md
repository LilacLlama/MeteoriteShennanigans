# Seeds

## `meteorite_class_composition.csv`

One row per canonical `class_group` (the buckets produced by
`int_meteorites_classified`'s CASE ladder). Schema and tests are defined in
`_seeds.yml`; this file documents *how the numbers got there*.

### Construction

Authored in a single sweep alongside the magnet-yield feature
(commit `7916652`). Values were assembled from a mix of:

- **Primary literature** for the well-characterised groups
  (irons, ordinary chondrites, carbonaceous chondrites). Cited in the
  `source_note` column.
- **Textbook / class-wide estimates** where primary literature reports
  specimen-level values but the seed needs a single number for the whole
  class (e.g. CH at 20% — Bischoff 1993 measures 36% for the type
  specimen ALH 85085, but Wikipedia/textbook summaries give 20% as the
  class-wide figure).
- **Conservative midpoints** for ambiguous-classification rows like
  `OC_mixed`, `E`, `C_ung`, `chondrite_other`, `achondrite_other`. These
  rows are flagged in `source_note` with wording like "Midpoint of…" or
  "Conservative … estimate".
- **Zero** for the `unknown` catch-all, deliberately — it captures
  recclass values the ladder didn't recognise (`"Stone-uncl"`,
  `"Fusion crust"`, etc.), and weighting them as zero avoids inflating
  magnet-yield numbers based on uninterpretable rows.

### Honest caveats

- The `source_note` citations name canonical references but were not
  one-for-one transcriptions from those papers. Spot-checks against
  primary literature have found values that sit at the high edge of the
  reported range (H at 17% vs. Jarosewich 1990's 13.6 ± 4.6 wt%) or that
  use the class-wide textbook figure rather than the specific number
  measured in the cited paper (CH).
- Values are appropriate for ranking classes by magnet-attractability
  (which is what this project does) and for order-of-magnitude yield
  estimates. They are **not** suitable for publication-grade meteoritics.
- If you need a defensible specific number for any one class, verify
  against the cited paper or the
  [Meteoritical Bulletin Database](https://www.lpi.usra.edu/meteor/).

### When to update this seed

The `relationships` test on `int_meteorites_classified.class_group →
dim_meteorite_class.class_group` (defined in `dbt/models/intermediate/_models.yml`)
will fail when the classifier produces a `class_group` value with no
matching seed row. That's the trigger: NASA adds a new recclass, the
classifier's CASE ladder is extended to bucket it, and a corresponding
row must be added here.

### Derived attributes don't live here

`magnetic_tier` and `is_magnetically_catchable` are *derived* from
`metal_fraction_pct` and computed in `dim_meteorite_class.sql`, not
stored in this seed. Adjust the magnetism cutoffs in that model, not
here — the seed stays pure physical data.

### References used for spot-checks

The "Honest caveats" section above is grounded in comparisons against
these sources. They're a good starting point if you want to verify or
update any specific row.

- Jarosewich (1990), [*Chemical analyses of meteorites: A compilation
  of stony and iron meteorite analyses*](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1945-5100.1990.tb00717.x)
  — primary source for ordinary-chondrite metal contents (H/L/LL).
- Weisberg et al. (2001), [*A new metal-rich chondrite grouplet*](https://onlinelibrary.wiley.com/doi/pdf/10.1111/j.1945-5100.2001.tb01882.x)
  — established the CB classification and the CBa/CBb subdivision.
- Campbell, Humayun & Weisberg, [*Formation of Metal in the CH
  Chondrites ALH 85085 and PCA 91467*](https://www.sciencedirect.com/science/article/abs/pii/S0016703703008469)
  — measures 36 wt% metallic Fe,Ni in ALH 85085.
- Washington University in St. Louis, [*Metal, iron & nickel in
  meteorites*](https://sites.wustl.edu/meteoritesite/items/metal-iron-nickel/)
  — accessible class-by-class summary; useful sanity-check reference.
- Lunar Homestead, [*Lunar Free Metallic Iron*](https://lunarhomestead.com/2018/02/21/lunar-free-iron/)
  — summary of lunar metal abundances (<1 vol% in returned samples).
- [Meteoritical Bulletin Database](https://www.lpi.usra.edu/meteor/) —
  authoritative per-specimen records; useful when chasing a specific
  meteorite or recclass.
