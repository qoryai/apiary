defmodule ApiaryProWeb do
  @moduledoc """
  The entrypoint of the edition's web modules, as `ApiaryWeb` is the core's:

      use ApiaryProWeb, :live_view
      use ApiaryProWeb, :html

  Each is the core's (`ApiaryWeb`), with the same imports, components and endpoint, but
  with `~p` verified against `ApiaryProWeb.Router`, which holds the core's routes and
  the edition's: a module of the edition links to either, and a core module to the core's
  alone. Its sentences are the edition's, translated with the edition's backend
  (`ApiaryProWeb.Gettext`) and kept in the edition's catalogues; a core component it
  renders says its sentences with the core's.
  """

  @doc false
  def router, do: ApiaryWeb.router()

  @doc false
  def controller, do: ApiaryWeb.controller(ApiaryProWeb.Router, ApiaryProWeb.Gettext)

  @doc false
  def live_view, do: ApiaryWeb.live_view(ApiaryProWeb.Router, ApiaryProWeb.Gettext)

  @doc false
  def live_component, do: ApiaryWeb.live_component(ApiaryProWeb.Router, ApiaryProWeb.Gettext)

  @doc false
  def html, do: ApiaryWeb.html(ApiaryProWeb.Router, ApiaryProWeb.Gettext)

  @doc false
  def verified_routes, do: ApiaryWeb.verified_routes(ApiaryProWeb.Router)

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
