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

  An edition's web module builds its own from the same pieces: `live_view/2`,
  `live_component/2`, `html/2` and `controller/2` take the router whose routes its `~p`
  are verified against and the Gettext backend its sentences are translated with, and
  `verified_routes/1` the router. The core's are verified against `ApiaryWeb.Router`,
  which holds the core's routes alone and is part of every edition's router, so a core
  module never links to a path only an edition serves: the edition links to its own pages
  from the places the core gives it (`ApiaryWeb.Extension`, `ApiaryWeb.Nav.Entry`). The
  core's sentences are in `ApiaryWeb.Gettext`'s catalogues, and an edition's in its own
  backend's (`c:ApiaryWeb.Edition.gettext_backend/0`), so each set of catalogues holds
  only the sentences of its own modules.
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

  def controller, do: controller(ApiaryWeb.Router, ApiaryWeb.Gettext)

  @doc """
  controller/2 is `use ApiaryWeb, :controller` with `~p` verified against `router`, and
  its sentences translated with the Gettext backend `gettext`.
  """
  @spec controller(module, module) :: Macro.t()
  def controller(router, gettext) do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: unquote(gettext)

      import Plug.Conn

      unquote(verified_routes(router))
    end
  end

  def live_view, do: live_view(ApiaryWeb.Router, ApiaryWeb.Gettext)

  @doc """
  live_view/2 is `use ApiaryWeb, :live_view` with `~p` verified against `router`, and its
  sentences translated with the Gettext backend `gettext`.
  """
  @spec live_view(module, module) :: Macro.t()
  def live_view(router, gettext) do
    quote do
      use Phoenix.LiveView

      # Async work runs under the page's organisation and workspace ids (ApiaryWeb.Async).
      use ApiaryWeb.Async

      # The domain's words: the locale follows the scope the live_session loaded.
      on_mount ApiaryWeb.Lingo

      unquote(html_helpers(router, gettext))
    end
  end

  def live_component, do: live_component(ApiaryWeb.Router, ApiaryWeb.Gettext)

  @doc """
  live_component/2 is `use ApiaryWeb, :live_component` with `~p` verified against
  `router`, and its sentences translated with the Gettext backend `gettext`.
  """
  @spec live_component(module, module) :: Macro.t()
  def live_component(router, gettext) do
    quote do
      use Phoenix.LiveComponent

      use ApiaryWeb.Async

      unquote(html_helpers(router, gettext))
    end
  end

  def html, do: html(ApiaryWeb.Router, ApiaryWeb.Gettext)

  @doc """
  html/2 is `use ApiaryWeb, :html` with `~p` verified against `router`, and its sentences
  translated with the Gettext backend `gettext`.
  """
  @spec html(module, module) :: Macro.t()
  def html(router, gettext) do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers(router, gettext))
    end
  end

  defp html_helpers(router, gettext) do
    quote do
      # Translation, and the rich text's (`ApiaryWeb.RichText`), with this backend
      use Gettext, backend: unquote(gettext)

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import ApiaryWeb.CoreComponents
      # The components of the runs, run and connections pages
      import ApiaryWeb.RunComponents
      # The patterns every page is built from: its header, a thing's tabs, a settings
      # page, a form page, the line of what a run receives
      import ApiaryWeb.PageComponents
      # Whole translated sentences with marked-up parts
      import ApiaryWeb.RichText

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias ApiaryWeb.Layouts
      # Dates, times and numbers as the reader writes them
      alias ApiaryWeb.Format

      # Routes generation with the ~p sigil
      unquote(verified_routes(router))
    end
  end

  def verified_routes, do: verified_routes(ApiaryWeb.Router)

  @doc """
  verified_routes/1 is `use ApiaryWeb, :verified_routes` with `~p` verified against
  `router`: the endpoint is the core's in every edition.
  """
  @spec verified_routes(module) :: Macro.t()
  def verified_routes(router) do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ApiaryWeb.Endpoint,
        router: unquote(router),
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
