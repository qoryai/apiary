defmodule ApiaryWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use ApiaryWeb, :controller
      use ApiaryWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  # Not `docs`: `priv/static/docs` holds a tree of the documentation per set of features,
  # and the endpoint serves /docs from the instance's tree alone (ApiaryWeb.DocsController).
  def static_paths,
    do: ~w(assets fonts images favicon.ico favicon.svg favicon-32.png robots.txt)

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

      use Gettext, backend: ApiaryWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      # The domain's words: the locale follows the scope the live_session loaded.
      on_mount ApiaryWeb.Lingo

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
      use Gettext, backend: ApiaryWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import ApiaryWeb.CoreComponents
      # The components of the runs, run and connections pages
      import ApiaryWeb.RunComponents
      # Whole translated sentences with marked-up parts
      import ApiaryWeb.RichText

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias ApiaryWeb.Layouts
      # Dates, times and numbers as the reader writes them
      alias ApiaryWeb.Format

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ApiaryWeb.Endpoint,
        router: ApiaryWeb.Router,
        statics: ApiaryWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
