# DESIGN.md

<!-- impeccable:design-schema 1 -->

## World

Split-flap departure board, restrained to what an operate surface may borrow:
type, palette, density, and one signature move. Never the board's chrome --
navigation, controls, and tables stay standard web components.

## Palette

Matte near-black ground (`--background` oklch 0.105), flap-face cards one step
up (`--card` oklch 0.16). Zinc scale otherwise untouched. State colors keep
their jobs and nothing else: emerald = done, amber = attention, dim red =
failed. No new hues were added for decoration.

## Type

Barlow Condensed (self-hosted woff2, OFL, `priv/static/fonts/`) as `font-flap`
for display: page titles, library title cells, attention counts, coverage
percentages. Body, labels, and controls stay on the system sans. Tabular
numerals wherever numbers change between renders.

## Signature move

Changed rows cascade in top to bottom (`.FlapBoard` colocated hook on the
library tbody + `flap-in` keyframes): new arrivals and status flips animate,
steady rows sit still. Honors `prefers-reduced-motion`. The move audits as:
fresh titles flip in on sync, failed rewrites dim red without motion.

## Rules carried forward

- One condensed face, two weights (500/600); never condensed body copy.
- `kbd` hints are themed (mono, bordered), never browser-default.
- Touch targets stay 44px on phones; dialogs keep a 1rem side gutter.
- Focus rings from the system; no custom glow.
