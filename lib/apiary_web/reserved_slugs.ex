defmodule ApiaryWeb.ReservedSlugs do
  @moduledoc """
  ReservedSlugs holds the names a slug can never be, beside the router whose paths
  they are: the core's, and those the edition's own paths take
  (`c:ApiaryWeb.Edition.reserved_slugs/0`).

  Every page of a workspace is under `/:org/:workspace/…` and every page of an
  organisation under `/:org/…`, so an organisation slug shares the first segment of the
  path with the instance's own paths (`/users`, `/docs`, `/v1`, the static files, the
  LiveView socket), and a workspace slug shares the second with the organisation's own
  pages (`/:org/settings`, `/:org/activity`). `organisation/0` and `workspace/0` name
  them.

  The core reserves only the paths it serves. An edition reserves the paths it adds, and
  settles for itself a slug an instance of the core gave out before the edition took the
  instance over. The test (`ApiaryWeb.ReservedSlugsCase`) fails when a route of the router the endpoint
  dispatches to, a static path or a socket of the endpoint takes a segment these lists do
  not name: a new top-level path or organisation page is added here, or to the edition's
  list, in the same change, never after an organisation took the name.

  As a plug, first in the pipeline of the organisation's and the workspace's pages, it
  answers as the router answers a path it does not know when a segment in the place of a
  slug can never be one: reserved, or not of a slug's characters and length
  (`Apiary.Organisations.Slug.valid?/1`). `/v1/no-such-endpoint` is not an
  organisation's page, and neither are `/apple-touch-icon.png` or `/.env`: a runner, a
  browser or a scanner asking for one is told so, not sent to log in, and a visitor's
  stored return-to, the page a shared link named, is not overwritten on the way.
  """
  @behaviour Plug

  # The first segments of the instance's own paths: the routes, the endpoint's sockets
  # and static files, and the development routes.
  @instance ~w(
    .well-known assets dev docs favicon-32.png favicon.ico favicon.svg fonts health images
    invitations live phoenix robots.txt users v1
  )

  # The organisation's own pages, the second segment of `/:org/…`, and the palette's
  # answers there.
  @organisation_pages ~w(activity jump members settings)

  @doc """
  organisation/0 lists the names no organisation slug may be: the core's and the
  edition's.
  """
  @spec organisation() :: [String.t()]
  def organisation, do: Enum.sort(@instance ++ edition(:instance))

  @doc """
  workspace/0 lists the names no workspace slug may be, in any organisation: the core's
  and the edition's.
  """
  @spec workspace() :: [String.t()]
  def workspace,
    do: Enum.sort(@organisation_pages ++ edition(:organisation))

  defp edition(list), do: Map.get(ApiaryWeb.Edition.reserved_slugs(), list, [])

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_params: %{"org" => organisation_slug} = params} = conn, _opts) do
    workspace_slug = params["workspace"]

    if slug?(organisation_slug, organisation()) and
         (is_nil(workspace_slug) or slug?(workspace_slug, workspace())),
       do: conn,
       else: raise(Phoenix.Router.NoRouteError, conn: conn, router: ApiaryWeb.Edition.router())
  end

  def call(conn, _opts), do: conn

  defp slug?(segment, reserved),
    do: Apiary.Organisations.Slug.valid?(segment) and segment not in reserved
end
