defmodule FanfarrWeb.ThemeTokensTest do
  @moduledoc """
  daisyUI was removed in favour of the design tokens in app.css, but the
  generated markup kept using its class names -- `bg-base-100`, `btn-primary`
  and friends. Those resolve to no CSS at all, so elements simply lose their
  styling and the theme toggle appears broken: it flips `data-theme` correctly
  and the variables change, but nothing consumes them.

  Failing silently is what makes this worth a test. Tailwind does not warn
  about an unknown class.
  """
  use ExUnit.Case, async: true

  # Our own markup only. The vendored SaladUI components are upstream code.
  @our_markup [
    "lib/fanfarr_web/components/layouts.ex",
    "lib/fanfarr_web/components/layouts",
    "lib/fanfarr_web/components/core_components.ex",
    "lib/fanfarr_web/controllers",
    "lib/fanfarr_web/live"
  ]

  @daisy_classes ~w(
    base-100 base-200 base-300 base-content
    btn btn-primary btn-secondary btn-ghost btn-soft btn-sm btn-lg
    navbar card-body menu drawer
  )

  test "no daisyUI class names remain in our markup" do
    offenders =
      @our_markup
      |> Enum.flat_map(&files/1)
      |> Enum.flat_map(fn file ->
        # Only class attributes. Scanning whole files matches prose in
        # @moduledoc, which is not markup and not a problem.
        classes =
          ~r/class=(?:"([^"]*)"|\{([^}]*)\})/
          |> Regex.scan(File.read!(file))
          |> Enum.map_join(" ", fn m -> Enum.at(m, 1, "") <> " " <> Enum.at(m, 2, "") end)

        @daisy_classes
        |> Enum.filter(&Regex.match?(~r/(?<![\w-])#{Regex.escape(&1)}(?![\w-])/, classes))
        |> Enum.map(&{file, &1})
      end)

    assert offenders == [], """
    daisyUI class names found in markup, but daisyUI is not loaded. These
    produce no CSS, so the elements lose their styling and the theme toggle
    looks broken.

    Use the tokens registered in assets/css/app.css instead:
      bg-base-100    -> bg-background / bg-card
      bg-base-200/300 -> bg-muted
      text-base-content -> text-foreground / text-muted-foreground
      border-base-*  -> border-border
      btn btn-primary -> bg-primary text-primary-foreground ...

    Offenders:
    #{Enum.map_join(offenders, "\n", fn {f, c} -> "  #{f}: #{c}" end)}
    """
  end

  defp files(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,heex}"))
      File.regular?(path) -> [path]
      true -> []
    end
  end

  test "app.css registers the tokens the markup relies on" do
    css = File.read!("assets/css/app.css")

    for token <- ~w(--color-background --color-foreground --color-card --color-muted
                    --color-primary --color-border --color-accent --color-ring) do
      assert String.contains?(css, token),
             "app.css does not register #{token}, so utilities using it will not resolve"
    end
  end

  test "the dark token set applies to both selector conventions" do
    theme = File.read!("assets/css/salad_ui_theme_zinc.css")

    # Our own markup keys off data-theme (what the toggle sets); the vendored
    # components key off .dark. Both must switch the same variables.
    assert theme =~ ~r/\.dark,\s*\n?\[data-theme="dark"\]/,
           "the dark palette must apply to both .dark and [data-theme=dark]"
  end
end
