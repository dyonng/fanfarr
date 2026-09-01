// Lucide icons as Tailwind utilities.
//
// Same mechanism the Phoenix generator uses for Heroicons: each SVG becomes a
// CSS mask on a span, so icons inherit currentColor, cost no runtime
// JavaScript, and only the icons actually referenced are emitted.
//
// Lucide rather than Heroicons because the UI is built on shadcn components,
// and Lucide is the set shadcn is drawn against -- its 2px stroke and 24px
// grid are what those components' spacing assumes.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function ({ matchComponents, theme }) {
  let iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  let values = {}

  fs.readdirSync(iconsDir).forEach((file) => {
    if (!file.endsWith(".svg")) return
    let name = path.basename(file, ".svg")
    values[name] = { name, fullPath: path.join(iconsDir, file) }
  })

  matchComponents(
    {
      lucide: ({ name, fullPath }) => {
        // Lucide ships its SVGs pretty-printed. Collapsing whitespace keeps the
        // data URI compact without gluing attributes together.
        let content = fs
          .readFileSync(fullPath)
          .toString()
          .replace(/\s+/g, " ")
          .trim()

        content = encodeURIComponent(content)

        return {
          [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
          "-webkit-mask": `var(--lucide-${name})`,
          mask: `var(--lucide-${name})`,
          "mask-repeat": "no-repeat",
          // Lucide draws on a 24px grid. Without an explicit mask-size the
          // artwork renders at that intrinsic size and is clipped by any
          // smaller box -- `size-4` in particular, which most call sites use.
          // `contain` scales it to whatever the element ends up being.
          "-webkit-mask-size": "contain",
          "mask-size": "contain",
          "-webkit-mask-position": "center",
          "mask-position": "center",
          "background-color": "currentColor",
          "vertical-align": "middle",
          display: "inline-block",
          // A default only: a `size-*` utility on the same element wins.
          width: theme("spacing.5"),
          height: theme("spacing.5")
        }
      }
    },
    { values }
  )
})
