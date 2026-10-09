defmodule ApiaryWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ApiaryWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ApiaryWeb.Endpoint

      # Paths verified against the router the endpoint dispatches to, the edition's: the
      # tests reach its pages too.
      unquote(ApiaryWeb.verified_routes(ApiaryWeb.Edition.router()))

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ApiaryWeb.ConnCase
    end
  end

  setup tags do
    Apiary.DataCase.setup_sandbox(tags)
    Apiary.DataCase.setup_features(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  The user is created through `Apiary.Organisations.sign_up_user/2`, so they
  own an organisation and a workspace; the scope in the context is loaded with them.
  It stores an updated connection, the user and the scope in the test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    %{user: user} = Apiary.OrganisationsFixtures.sign_up_fixture()
    scope = Apiary.Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  The path of the scope's workspace, `/<organisation slug>/<workspace slug>`, followed by
  `rest`: for a path a test cannot write with `~p`, such as one inside a selector. A
  path a test visits is written `~p"/\#{scope.organisation}/\#{scope.workspace}/runs"`.
  """
  def workspace_path(%{organisation: organisation, workspace: workspace}, rest \\ "") do
    "/#{organisation.slug}/#{workspace.slug}#{rest}"
  end

  @doc """
  The breadcrumb's segments after the place, of a page (its view or its HTML), each
  `{words, href}`: href is nil where the segment is no link, as the page itself is. The
  place is the organisation and the workspace on a workspace's page (`:workspace`), the
  organisation alone on an organisation's (`:organisation`).
  """
  def crumbs(page, place \\ :workspace)

  def crumbs(%Phoenix.LiveViewTest.View{} = view, place),
    do: crumbs(Phoenix.LiveViewTest.render(view), place)

  def crumbs(html, place) when is_binary(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#breadcrumb ol.q-trail > li")
    |> Enum.drop(if(place == :organisation, do: 1, else: 2))
    |> Enum.map(fn item ->
      segment = LazyHTML.query(item, ".q-trail-link")
      words = segment |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
      href = segment |> LazyHTML.filter("a") |> LazyHTML.attribute("href") |> List.first()
      {words, href}
    end)
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Apiary.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Apiary.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
