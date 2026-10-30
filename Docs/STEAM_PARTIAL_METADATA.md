# Partial Steam entries and legacy platform data

Some separately listed modes have a sparse public Store response. For AppID
212910 (Black Ops II - Zombies), the official response supplies Windows support,
artwork, categories and 50 achievements, while description, developer and
publisher fields are empty. Ready preserves that distinction rather than copying
the main game's description or treating a missing field as lost ownership.

The catalog parser exposes available categories and achievement counts. The
detail also shows the declared launch description. Legacy PICS associations in
`extended.developer`/`extended.publisher` and platform declarations in
`extended.validoslist` or older launch fields are recognized. Empty Store fields
cannot erase previously known descriptions/associations or prevent later PICS
repair. An authoritative PICS game classification is retained when the public
Store entry labels the mode as advertising.

When PICS has no platform declaration at all, a selected game's size lookup can
use that same AppID's explicit official Store platform declaration. It does not
override an explicit conflicting PICS platform or infer executable architecture.
Size/depot authorization remains separate from catalog metadata.

The [validation checkpoint](../Validation/steam-partial-metadata-checkpoint.json)
records replay of the actual official response and controlled parser/merge/UI
checks. A publisher description absent from Steam remains explicitly unavailable.
