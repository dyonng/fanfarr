defmodule FanfarrWeb.AuthOverrides do
  @moduledoc """
  Branding for the sign-in and register pages.

  Without these, AshAuthentication's defaults present the Ash Framework logo
  and a light-mode palette, which is jarring as the first thing an operator
  sees. These bring the pages onto Fanfarr's own tokens so the entry point
  looks like the rest of the application.
  """
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.Components

  override Components.Banner do
    set :root_class, "w-full flex flex-col items-center gap-1 py-6"
    set :href_url, "/"
    set :href_class, "text-3xl font-semibold tracking-tight text-foreground no-underline"
    # No image at all: the default points at an Ash Framework logo hosted
    # off-site, which an appliance on a private network may not even reach.
    set :image_url, nil
    set :dark_image_url, nil
    set :image_class, "hidden"
    set :dark_image_class, "hidden"
    set :text, "🎺 Fanfarr"
    set :text_class, "text-3xl font-semibold tracking-tight text-foreground"
  end

  override Components.SignIn do
    set :root_class, "grid h-screen place-items-center bg-background px-4"
    set :strategy_display_order, [:password]
  end

  override Components.Password do
    set :root_class, "w-full max-w-sm"
    # No toggles: registration and reset do not exist here, so there is
    # nothing to switch to. Removing register_path from the route already
    # stops the form rendering; these keep the links from appearing at all.
    set :register_toggle_text, nil
    set :reset_toggle_text, nil
    set :sign_in_toggle_text, nil
    set :show_first, :sign_in
    set :hide_class, "hidden"
  end

  override Components.Password.SignInForm do
    set :label_class, "mb-4 text-xl font-semibold tracking-tight text-foreground"
    set :label, "Sign in"
    set :disable_button_text, "Signing in…"
  end

  override Components.Password.Input do
    set :field_class, "mt-2 mb-3"
    set :label_class, "block text-xs font-medium text-muted-foreground mb-1"

    set :input_class,
        "h-9 w-full rounded-md border border-input bg-background px-3 text-sm text-foreground " <>
          "placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 " <>
          "focus-visible:ring-ring"

    set :submit_class,
        "mt-4 h-9 w-full rounded-md bg-primary px-3 text-sm font-medium " <>
          "text-primary-foreground hover:bg-primary/90 transition-colors"

    set :error_ul, "text-destructive text-xs mt-1"
  end

  override Components.HorizontalRule do
    set :hr_inner_class, "w-full border-t border-border"
    set :text_inner_class, "px-2 bg-background text-muted-foreground font-medium"
  end
end
