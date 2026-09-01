defmodule FanfarrWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use FanfarrWeb, :controller
      use FanfarrWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths,
    do: ~w(assets fonts images favicon.ico favicon.svg apple-touch-icon.png robots.txt)

  @doc """
  Filename prefixes of static files that live at the root rather than in a
  directory.

  Digesting rewrites `favicon.svg` to `favicon-<hash>.svg`, which no longer
  matches an exact `:only` entry, so these need Plug.Static's prefix matching
  or they 404 in prod. Anything added to `static_paths/0` that is a bare file
  rather than a directory belongs here too.
  """
  def static_root_file_prefixes, do: ~w(favicon apple-touch-icon robots)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: FanfarrWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: FanfarrWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import FanfarrWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias FanfarrWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FanfarrWeb.Endpoint,
        router: FanfarrWeb.Router,
        statics: FanfarrWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
