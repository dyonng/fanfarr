# Vendored SaladUI

These are the [SaladUI](https://github.com/bluzky/salad_ui) components, copied in
rather than depended on. MIT licensed; the upstream copyright notice is kept
alongside as `LICENSE-salad_ui`.

Vendored from `v1.0.0` (upstream commit `2026-08-11`).

## Why a copy and not a dependency

Two reasons, both practical.

**It would pollute the production release.** SaladUI declares `igniter` and
`sourceror` as runtime dependencies, though they are only used by its `mix
salad.*` code-generation tasks. Depending on the package forces those tools --
and their transitive tree -- into the release, and forces us to drop the
`only: [:dev, :test]` scoping on our own copies of them. Vendoring the
components leaves that behind entirely: the components themselves never
reference either library.

**It bounds the maintenance risk.** SaladUI reached 1.0.0 three weeks before we
adopted it and is essentially a single-maintainer project. As a live dependency
that is a real exposure. As a copy, the worst case is that we maintain files we
already have.

This also happens to be how shadcn/ui -- the library SaladUI ports -- is meant
to be consumed: you copy the components into your project and own them.

## What was changed

- The `chart` component was dropped, both its `.ex` and its `.js`. It requires
  the `chart.js` npm package, and we have no charts and no node_modules.
- Nothing else. Modules keep the `SaladUI.*` namespace so the components'
  internal references resolve unedited; renaming 41 files' modules would be
  pure risk for a cosmetic gain.

## What it needs to work

- `tw_merge` as a real dependency, and `TwMerge.Cache` started in the
  supervision tree. The components resolve Tailwind class conflicts through it,
  and it raises on a missing ETS table if unsupervised.
- The JS runtime in `assets/js/salad_ui`, with each interactive component
  imported in `app.js` -- component modules self-register with the factory on
  import, so an unimported one renders but stays inert.
- The `SaladUI` hook registered on the LiveSocket.
- Design tokens from `assets/css/salad_ui_theme_zinc.css`, exposed as Tailwind
  utilities by the `@theme inline` block in `app.css`.

## Upgrading

There is no automatic path -- that is the trade. Diff against upstream and port
what you want. `test/fanfarr_web/vendor_salad_ui_test.exs` is the smoke test
that catches a component that has stopped rendering, since nothing upstream
will tell us.
