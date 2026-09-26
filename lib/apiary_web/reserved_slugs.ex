defmodule ApiaryWeb.ReservedSlugs do
  @moduledoc """
  ReservedSlugs holds the names a slug can never be, beside the router whose paths
  they are.

  Every page of a workspace is under `/:org/:workspace/…` and every page of an
  organisation under `/:org/…`, so an organisation slug shares the first segment of the
  path with the instance's own paths (`/users`, `/docs`, `/v1`, the static files, the
  LiveView socket), and a workspace slug shares the second with the organisation's own
  pages (`/:org/settings`, `/:org/members`). `organisation/0` and `workspace/0` name
  them, and names Qory may want later, reserved while no organisation holds them.

  The router's test fails when a route, a static path or a socket of the endpoint takes
  a segment these lists do not name: a new top-level path or organisation page is added
  here in the same change, never after an organisation took the name.

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
  # and static files, the development routes, and the paths of earlier releases.
  @instance ~w(
    .well-known assets dev docs favicon-32.png favicon.ico favicon.svg fonts health images
    invitations live organisations phoenix robots.txt users v1 workspace
  )

  # Names a later release may want at the top level. Not `organisation`: it is the slug a
  # name with no letter or digit gets.
  @instance_later ~w(
    about account accounts admin api app auth billing blog help home login logout new
    oauth operator register settings signin signout signup static status support
    workspaces www
  )

  # The organisation's own pages, the second segment of `/:org/…`.
  @organisation_pages ~w(activity members settings)

  # Names a later release may want among an organisation's pages. Not `workspace`: it is
  # the slug a name with no letter or digit gets.
  @organisation_pages_later ~w(
    access api audit billing grants invitations keys new workspaces
  )

  @doc "organisation/0 lists the names no organisation slug may be."
  @spec organisation() :: [String.t()]
  def organisation, do: Enum.sort(@instance ++ @instance_later)

  @doc "workspace/0 lists the names no workspace slug may be, in any organisation."
  @spec workspace() :: [String.t()]
  def workspace, do: Enum.sort(@organisation_pages ++ @organisation_pages_later)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_params: %{"org" => organisation_slug} = params} = conn, _opts) do
    workspace_slug = params["workspace"]

    if slug?(organisation_slug, organisation()) and
         (is_nil(workspace_slug) or slug?(workspace_slug, workspace())),
       do: conn,
       else: raise(Phoenix.Router.NoRouteError, conn: conn, router: ApiaryWeb.Router)
  end

  def call(conn, _opts), do: conn

  defp slug?(segment, reserved),
    do: Apiary.Organisations.Slug.valid?(segment) and segment not in reserved
end
