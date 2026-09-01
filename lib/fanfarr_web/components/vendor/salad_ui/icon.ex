defmodule SaladUI.Icon do
  @moduledoc """
  Renders a [Lucide](https://lucide.dev) icon.

  Vendored change: upstream renders Heroicons. This project uses Lucide, the
  set shadcn's components are drawn against, so the clause matches `lucide-`
  names instead. Icons come from the Tailwind plugin in
  `assets/vendor/lucide.js`, which emits a CSS mask per referenced icon.

  ## Examples
      <.icon name="lucide-x" />
      <.icon name="lucide-refresh-cw" class="ml-1 w-3 h-3 animate-spin" />
  """

  use SaladUI, :component

  attr :name, :string, required: true
  attr :class, :string, default: ""

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]}></span>
    """
  end
end
