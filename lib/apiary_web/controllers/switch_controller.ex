defmodule ApiaryWeb.SwitchController do
  @moduledoc """
  Where the links of the breadcrumb's menus lead (`ApiaryWeb.Layouts`): to a workspace,
  the page the reader is on, as it is in that workspace; to an organisation, the same in
  the workspace the person last used there. Every link of the organisation menu and the
  workspace menu comes here. Not a page: a redirect.

      GET /:org/:workspace/switch/:section?page=<path>
      GET /:org/-/switch/:section?page=<path>

  `section` is the navigation entry of the reader's page, and `page` its path after its
  own `/:org/:workspace` (`/runs/<run>/terminal`), which the menu adds to the link when it
  opens. The page is matched to its route in the router (`landing/4`), by one rule for
  every page:

    * a route with no path parameter but `:org` and `:workspace` is kept: the same page
      there;
    * a route with another, which names one thing by its id (a run, a target, a node, a
      secret…), falls back to its list page, the nearest page above it whose route has
      none, else to its section. A version of the policy falls back to the policy's
      History, which lists the versions, and the confirmation of deleting the workspace,
      which names none, to its settings: a confirmation never travels to another
      workspace.

  A page is kept only if it is one of the workspace's own pages, and only where the reader
  may open its section there with its feature on, and the page's own feature is on there
  too; otherwise the section, else the workspace's overview
  (`ApiaryWeb.Layouts.switch_target/3`). The query string is dropped: a filter can name
  what the other workspace does not have. The answer is always a path of the router's own
  routes under that organisation and workspace, never a part of `page`, so a link leads
  nowhere else.

  The pipeline resolves the destination's scope for a person who reaches it and answers
  `404` for anybody else. The link to an organisation resolves the workspace as the
  organisation's own page does (`Apiary.Organisations.resolve_scope/4`): the session's
  while it is in that organisation, else the one the person last used there, else the
  oldest they reach; with none reached it leads to the organisation's own path, which says
  so. Like the palette, it belongs to the console's record, `observability`, which every
  instance has.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  alias ApiaryWeb.Layouts

  @place "/:org/:workspace"

  # The list page of a route whose list is not the nearest page above it, by the route's
  # path after `/:org/:workspace`.
  @lists %{
    "/policy/versions/:n" => "/policy/history",
    "/policy/versions/:n/export" => "/policy/history",
    "/settings/danger" => "/settings",
    "/settings/delete" => "/settings"
  }

  def show(conn, %{"section" => section} = params) do
    redirect(conn, to: target(conn, conn.assigns.current_scope, section, params["page"]))
  end

  defp target(_conn, %{workspace: nil, organisation: organisation}, _section, _page),
    do: ~p"/#{organisation}"

  defp target(conn, %{organisation: organisation, workspace: workspace} = scope, section, page) do
    page =
      case landing(conn.private.phoenix_router, organisation.slug, workspace.slug, page) do
        {path, view} -> if feature_on?(scope, view), do: ~p"/#{organisation}/#{workspace}" <> path
        nil -> nil
      end

    Layouts.switch_target(scope, section, page)
  end

  # Whether the feature of the page's LiveView (`ApiaryWeb.Features`), if it has one, is
  # on in the destination.
  defp feature_on?(scope, view) do
    not (Code.ensure_loaded?(view) and function_exported?(view, :__feature__, 0)) or
      Apiary.Features.on?(scope, view.__feature__())
  end

  @doc """
  landing/4 is where `page`, the path of a reader's page after its `/:org/:workspace`,
  lands in the workspace `workspace_slug` of the organisation `organisation_slug`, by the
  routes of `router`: `{path, live_view}`, the path after `/:org/:workspace` of the page
  kept or of its list page, and the LiveView of that page; nil for a page that is none of
  a workspace's, or has no list page, which leads to its section. The path is the route's
  own, never a part of `page`.
  """
  @spec landing(module, String.t(), String.t(), term) :: {String.t(), module} | nil
  def landing(router, organisation_slug, workspace_slug, page)
      when page == "" or (is_binary(page) and binary_part(page, 0, 1) == "/") do
    base = "/" <> organisation_slug <> "/" <> workspace_slug

    case route(router, base, page) do
      {path, _view, _ids} when is_map_key(@lists, path) -> page_of(router, base, @lists[path])
      {path, view, []} -> {path, view}
      {path, _view, _ids} -> list_page(router, base, path)
      nil -> nil
    end
  end

  def landing(_router, _organisation_slug, _workspace_slug, _page), do: nil

  # The workspace's page `path` matches, `{its route after /:org/:workspace, its LiveView,
  # its other path parameters}`, or nil for a path that is none of the workspace's pages:
  # a route of it that is no LiveView (the palette, a run's log, these links), an
  # organisation's page, or no route at all.
  defp route(router, base, path) do
    with %{
           route: @place <> route,
           plug: Phoenix.LiveView.Plug,
           phoenix_live_view: {view, _action, _opts, _session},
           path_params: %{"org" => organisation, "workspace" => workspace} = params
         } <- Phoenix.Router.route_info(router, "GET", base <> path, nil),
         true <- route == "" or String.starts_with?(route, "/"),
         true <- "/" <> organisation <> "/" <> workspace == base do
      {route, view, Map.keys(params) -- ["org", "workspace"]}
    else
      _none -> nil
    end
  end

  # The page whose route is `path`, with no parameter of its own: `{path, its LiveView}`.
  defp page_of(router, base, path) do
    case route(router, base, path) do
      {^path, view, []} -> {path, view}
      _none -> nil
    end
  end

  # The nearest page above a route with an id: its path cut before the first parameter,
  # then shorter by a segment at a time, down to one segment.
  defp list_page(router, base, path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.take_while(&(not String.starts_with?(&1, [":", "*"])))

    Enum.find_value(length(segments)..1//-1, fn n ->
      page_of(router, base, "/" <> Enum.join(Enum.take(segments, n), "/"))
    end)
  end
end
