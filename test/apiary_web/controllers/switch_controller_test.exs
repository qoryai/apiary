defmodule ApiaryWeb.SwitchControllerTest do
  @moduledoc """
  The switcher's links keep the reader's page: the same page in the other workspace, or,
  where the page names one thing by its id, its list page; and only where that workspace
  has it: a section of a feature that is off there leads to the workspace's overview, never
  to a page that is not found. The link to an organisation lands in the workspace the
  person last used there. The answer is always a page of that workspace.
  """
  # Not async: one test switches the node's features.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Organisations.Workspace
  alias ApiaryWeb.SwitchController

  setup :register_and_log_in_user

  defp other_place(user) do
    other = sign_up_fixture()
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, _membership} = Organisations.accept_invitation(user, token)
    other
  end

  @tag needs: :security
  test "a section of a feature leads through the destination, which keeps it where it has it",
       %{conn: conn, user: user, scope: scope} do
    other = other_place(user)
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy")

    switch = workspace_path(other, "/switch/policy")
    assert has_element?(view, "#organisation-menu a[data-switch][href='#{switch}']")

    assert redirected_to(get(conn, switch)) == workspace_path(other, "/policy")
  end

  @tag with_features: [:observability]
  test "where the destination lacks the section's feature, its overview", %{
    conn: conn,
    user: user
  } do
    other = other_place(user)

    assert redirected_to(get(conn, workspace_path(other, "/switch/policy"))) ==
             workspace_path(other)
  end

  test "a section nobody has leads to the overview, and a place the reader does not reach is not found",
       %{conn: conn, user: user} do
    other = other_place(user)

    assert redirected_to(get(conn, workspace_path(other, "/switch/nothing"))) ==
             workspace_path(other)

    stranger = sign_up_fixture()
    assert conn |> get(workspace_path(stranger, "/switch/runs")) |> response(404)
  end

  test "the overview, a section of no feature, leads through the destination too, to its overview",
       %{conn: conn, user: user, scope: scope} do
    other = other_place(user)
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

    switch = workspace_path(other, "/switch/overview")
    assert has_element?(view, "#organisation-menu a[data-switch][href='#{switch}']")
    assert redirected_to(get(conn, switch <> "?page=")) == workspace_path(other)
  end

  # Where switching workspace lands, by the page the reader is on: `{section, page after
  # /:org/:workspace, where it lands}`. The ids name nothing: a page with an id is never
  # kept, so none is read.
  @landings [
    {"overview", "", ""},
    {"runs", "/runs", "/runs"},
    {"runs", "/runs/run-1", "/runs"},
    {"runs", "/runs/run-1/terminal", "/runs"},
    {"runs", "/runs/run-1/network", "/runs"},
    {"runs", "/runs/run-1/details", "/runs"},
    {"network", "/network", "/network"},
    {"targets", "/targets", "/targets"},
    {"targets", "/targets/src/app", "/targets"},
    {"targets", "/targets/src/app/-/policy/history", "/targets"},
    {"nodes", "/nodes", "/nodes"},
    {"nodes", "/nodes/new", "/nodes/new"},
    {"nodes", "/nodes/new-pool", "/nodes/new-pool"},
    {"nodes", "/nodes/nd_1", "/nodes"},
    {"nodes", "/nodes/nd_1/instances/i-1/clear", "/nodes"},
    {"nodes", "/nodes/nd_1/settings", "/nodes"},
    {"nodes", "/nodes/nd_1/settings/delete", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/generate", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/new-code", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/keys/ak_1/revoke", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/keys/ak_1/forager-file", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/keys/ak_1/generated", "/nodes"},
    {"nodes", "/nodes/nd_1/access-key/codes/c-1/revoke", "/nodes"},
    {"policy", "/policy", "/policy"},
    {"policy", "/policy/targets", "/policy/targets"},
    {"policy", "/policy/history", "/policy/history"},
    {"policy", "/policy/document", "/policy/document"},
    {"policy", "/policy/versions/3", "/policy/history"},
    {"policy", "/policy/versions/3/export", "/policy/history"},
    {"settings", "/settings", "/settings"},
    {"settings", "/settings/danger", "/settings"},
    {"settings", "/settings/delete", "/settings"},
    {"settings", "/settings/people", "/settings/people"},
    {"settings", "/settings/runs", "/settings/runs"},
    {"settings", "/settings/secrets", "/settings/secrets"},
    {"settings", "/settings/secrets/new", "/settings/secrets/new"},
    {"settings", "/settings/secrets/sec_1/edit", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/add-value", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/change-value", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/values/v-1/change", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/values/v-1/rename", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/values/v-1/delete", "/settings/secrets"},
    {"settings", "/settings/secrets/sec_1/delete", "/settings/secrets"},
    {"settings", "/settings/variables", "/settings/variables"},
    {"settings", "/settings/variables/new", "/settings/variables/new"},
    {"settings", "/settings/variables/var-1/change", "/settings/variables"},
    {"settings", "/settings/variables/var-1/lock", "/settings/variables"},
    {"settings", "/settings/variables/var-1/unlock", "/settings/variables"},
    {"settings", "/settings/variables/var-1/delete", "/settings/variables"},
    {"settings", "/settings/variables/var-1/targets", "/settings/variables"},
    {"settings", "/settings/integrations", "/settings/integrations"},
    {"settings", "/settings/integrations/add", "/settings/integrations/add"},
    {"settings", "/settings/integrations/new-runtime", "/settings/integrations/new-runtime"},
    {"settings", "/settings/integrations/new-service", "/settings/integrations/new-service"},
    {"settings", "/settings/integrations/definitions/new",
     "/settings/integrations/definitions/new"},
    {"settings", "/settings/integrations/releases/rel-1", "/settings/integrations"},
    {"settings", "/settings/integrations/definitions/svc_1", "/settings/integrations"},
    {"settings", "/settings/integrations/definitions/svc_1/edit", "/settings/integrations"},
    {"settings", "/settings/integrations/definitions/svc_1/delete", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/targets", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/targets/add", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/targets/t-1/remove", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/settings", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/version", "/settings/integrations"},
    {"settings", "/settings/integrations/con_1/delete", "/settings/integrations"},
    # From an organisation's page: no page, and a section no workspace has.
    {"members", nil, ""}
  ]

  defp switch(conn, place, section, page) do
    query = if page, do: "?" <> URI.encode_query(%{"page" => page}), else: ""
    conn |> get(workspace_path(place, "/switch/#{section}#{query}")) |> redirected_to()
  end

  defp organisation_switch(conn, organisation, section, page \\ nil) do
    query = if page, do: "?" <> URI.encode_query(%{"page" => page}), else: ""
    conn |> get("/#{organisation.slug}/-/switch/#{section}#{query}") |> redirected_to()
  end

  describe "the page kept" do
    setup %{scope: scope} do
      %{
        place: %{
          organisation: scope.organisation,
          workspace: workspace_fixture(scope.organisation, "Staging")
        }
      }
    end

    @tag with_features: Apiary.Features.all()
    test "lands on the same page, or the list page of the one thing it names", %{
      conn: conn,
      place: place
    } do
      for {section, page, lands} <- @landings do
        assert switch(conn, place, section, page) == workspace_path(place, lands),
               "#{section} #{inspect(page)}"
      end
    end

    @tag with_features: [:observability]
    test "with the record alone: a secret's page leads to the settings, the policy's to the overview",
         %{conn: conn, place: place} do
      assert switch(conn, place, "settings", "/settings/secrets/sec_1/edit") ==
               workspace_path(place, "/settings")

      assert switch(conn, place, "settings", "/settings/integrations") ==
               workspace_path(place, "/settings")

      assert switch(conn, place, "policy", "/policy/history") == workspace_path(place)
      assert switch(conn, place, "runs", "/runs") == workspace_path(place, "/runs")
    end

    test "a section nobody has, or an organisation's, leads to the overview whatever the page",
         %{conn: conn, place: place} do
      assert switch(conn, place, "nothing", "/runs") == workspace_path(place)
      assert switch(conn, place, "members", "/runs") == workspace_path(place)
    end

    test "a page that is none of a workspace's is ignored: the section, under that workspace",
         %{conn: conn, place: place} do
      for page <- [
            "//evil.example",
            "//evil.example/runs",
            "https://evil.example",
            "evil.example",
            "/../other-org/production/runs",
            "/../../evil.example",
            "/%2F%2Fevil.example",
            "/%2e%2e/%2e%2e/evil.example",
            "/\\evil.example",
            "/runs/../../../evil.example",
            "/runs/run-1/log",
            "/jump",
            "/switch/runs",
            "/connections",
            "/settings/retention",
            "/policy/targets/t-1",
            "/other-org/production/runs"
          ] do
        assert switch(conn, place, "runs", page) == workspace_path(place, "/runs"), page
      end

      # Not a string at all.
      assert conn
             |> get(workspace_path(place, "/switch/runs?page[]=//evil.example"))
             |> redirected_to() == workspace_path(place, "/runs")
    end

    test "a page with dots that matches a page with an id still lands on its list", %{
      conn: conn,
      place: place
    } do
      assert switch(conn, place, "targets", "/targets/../../../evil.example") ==
               workspace_path(place, "/targets")
    end
  end

  describe "the router's every workspace page" do
    # A path of the route, with a value in place of each parameter.
    defp sample(route) do
      route
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":" <> name -> "#{name}-1"
        "*" <> _glob -> "src/app"
        segment -> segment
      end)
    end

    test "a route with an id is never kept; one without is, but the confirmation of deleting the workspace" do
      routes =
        for %{path: "/:org/:workspace" <> rest, plug: Phoenix.LiveView.Plug} = route <-
              Phoenix.Router.routes(ApiaryWeb.Router),
            do: {rest, route}

      assert length(routes) > 60

      for {rest, %{metadata: %{phoenix_live_view: {view, _, _, _}}}} <- routes do
        ids? = String.contains?(rest, [":", "*"])
        landing = SwitchController.landing(ApiaryWeb.Router, "acme", "production", sample(rest))

        cond do
          rest in ["/settings/danger", "/settings/delete"] ->
            assert {"/settings", ApiaryWeb.SettingsLive} = landing

          ids? ->
            assert {path, _list} = landing, "#{rest} has a list page"
            refute path == rest
            refute String.contains?(path, [":", "*"]), "#{rest} lands on #{path}"

            assert {^path, _} =
                     SwitchController.landing(ApiaryWeb.Router, "acme", "production", path),
                   "#{rest} lands on #{path}, a page that is kept"

          true ->
            assert landing == {rest, view}, rest
        end
      end
    end
  end

  describe "the link to an organisation" do
    setup %{scope: scope} do
      organisation = scope.organisation
      alpha = workspace_fixture(organisation, "Alpha")
      beta = workspace_fixture(organisation, "Beta")
      # Alpha the oldest, Beta the youngest.
      for {w, at} <- [
            {alpha, ~U[2026-01-01 09:00:00Z]},
            {scope.workspace, ~U[2026-01-01 10:00:00Z]},
            {beta, ~U[2026-01-01 11:00:00Z]}
          ] do
        Apiary.Repo.update_all(from(x in Workspace, where: x.id == ^w.id), set: [inserted_at: at])
      end

      %{organisation: organisation, alpha: alpha, beta: beta}
    end

    test "lands in the oldest workspace, then the one used last there, at the page", %{
      conn: conn,
      user: user,
      organisation: organisation,
      alpha: alpha,
      beta: beta
    } do
      at = &workspace_path(%{organisation: organisation, workspace: &1}, &2)

      assert organisation_switch(conn, organisation, "runs", "/runs/run-1/terminal") ==
               at.(alpha, "/runs")

      # A page of the workspace used last, in a session of its own.
      {:ok, _view, _html} = live(conn, at.(beta, "/nodes"))

      fresh = log_in_user(build_conn(), user)
      assert organisation_switch(fresh, organisation, "runs", "/runs") == at.(beta, "/runs")

      assert organisation_switch(fresh, organisation, "nodes", "/nodes/nd_1/settings") ==
               at.(beta, "/nodes")

      # The organisation's own page opens the same workspace.
      conn = get(fresh, ~p"/#{organisation}")
      assert get_session(conn, :last_workspace_id) == beta.id

      # From an organisation's page: the workspace's overview.
      assert organisation_switch(fresh, organisation, "members") == at.(beta, "")
    end

    test "a page that is none of a workspace's is ignored there too", %{
      conn: conn,
      organisation: organisation,
      alpha: alpha
    } do
      for page <- ["//evil.example", "https://evil.example", "/../other-org/production/runs"] do
        assert organisation_switch(conn, organisation, "runs", page) ==
                 workspace_path(%{organisation: organisation, workspace: alpha}, "/runs")
      end
    end

    test "with no workspace reached, the organisation's own path; another's is not found", %{
      conn: conn,
      organisation: organisation
    } do
      Apiary.Repo.update_all(from(w in Workspace, where: w.organisation_id == ^organisation.id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), 30, :day),
          purge_trigger: "grace_period"
        ]
      )

      assert organisation_switch(conn, organisation, "runs", "/runs") == ~p"/#{organisation}"

      stranger = sign_up_fixture()
      assert conn |> get("/#{stranger.organisation.slug}/-/switch/runs") |> response(404)
    end
  end
end
