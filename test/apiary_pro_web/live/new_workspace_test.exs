defmodule ApiaryProWeb.NewWorkspaceTest do
  @moduledoc """
  New workspace on the edition: every entry for an owner (Workspaces, the organisation's overview,
  New, and the workspace menu) leads to Core's kind cards, `/:org/workspaces/new`
  (`ApiaryWeb.WorkspaceSetupLive`); a card opens the type's page, and Create workspace there
  creates the workspace at once and opens its Name step. What is the edition's on that path: an
  organisation has no limit of workspaces, the cards are an owner's alone, and a workspace
  made there starts under the organisation's policy.
  """
  # Not async: a test that creates a workspace under a policy writes through the node's
  # features.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.{Features, Organisations, Policy, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.{Flags, OrganisationPolicy}

  setup :register_and_log_in_user

  defp cards(scope), do: ~p"/#{scope.organisation}/workspaces/new"

  # The Software factory card is a link to the type's page; Create workspace is there.
  defp open_type(conn, lv) do
    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("#set-up-card-software-link") |> render_click()

    {:ok, page, _html} = live(conn, to)
    page
  end

  defp create(page), do: page |> element("#workspace-type-create") |> render_click()

  defp choose(conn, lv), do: conn |> open_type(lv) |> create()

  defp slugs(scope), do: for(w <- Organisations.list_workspaces(scope), do: w.slug)

  describe "as an owner" do
    test "New workspace on Workspaces and on the overview leads to the cards", ctx do
      for page <- [
            ~p"/#{ctx.scope.organisation}/settings/workspaces",
            ~p"/#{ctx.scope.organisation}"
          ] do
        {:ok, lv, _html} = live(ctx.conn, page)

        assert has_element?(
                 lv,
                 "a#new-workspace.btn-primary[href='#{cards(ctx.scope)}']",
                 "New workspace"
               )
      end
    end

    @tag with_features: Features.all()
    test "from the New workspace entry the owner reaches the cards and chooses Software factory",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.scope.organisation}/settings")

      {:ok, lv, _html} =
        lv
        |> element("#new-menu a#new-menu-workspace")
        |> render_click()
        |> follow_redirect(ctx.conn, cards(ctx.scope))

      assert has_element?(lv, "h1", "What will this workspace do?")
      assert has_element?(lv, "#set-up-card-software")
      assert has_element?(lv, "#set-up-card-software-link[aria-label='Software factory']")

      # The edition has no limit of workspaces: the organisation has one, and the cards show.
      assert [_one] = Organisations.list_workspaces(ctx.scope)
      refute has_element?(lv, "#set-up-limit")

      {:ok, lv, _html} = choose(ctx.conn, lv) |> follow_redirect(ctx.conn)

      # Create workspace created the workspace and opened its Name step, the first of the flow.
      org = ctx.scope.organisation.slug
      assert has_element?(lv, "h1", "Name this workspace")

      assert has_element?(
               lv,
               "#set-up-form input[name='workspace[name]'][value='Software factory']"
             )

      assert %{name: "Software factory", domain: "software"} =
               Enum.find(
                 Organisations.list_workspaces(ctx.scope),
                 &(&1.slug == "software-factory")
               )

      assert has_element?(lv, "#sidebar a[href='/#{org}/software-factory/set-up/sources']")
    end

    test "Create workspace makes a second workspace, which Workspaces lists", ctx do
      org = ctx.scope.organisation.slug
      {:ok, lv, _html} = live(ctx.conn, cards(ctx.scope))

      assert {:error, {:live_redirect, %{to: to}}} = choose(ctx.conn, lv)
      assert to == ~p"/#{org}/software-factory/set-up/name"

      assert %{name: "Software factory", domain: "software", egress_mode: "observe"} =
               Enum.find(
                 Organisations.list_workspaces(ctx.scope),
                 &(&1.slug == "software-factory")
               )

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{org}/settings/workspaces")
      assert has_element?(lv, "#workspaces", "Software factory")

      # A third one is numbered: the edition has no limit.
      {:ok, lv, _html} = live(ctx.conn, cards(ctx.scope))
      assert {:error, {:live_redirect, %{to: to}}} = choose(ctx.conn, lv)
      assert to == ~p"/#{org}/software-factory-2/set-up/name"
      assert length(Organisations.list_workspaces(ctx.scope)) == 3
    end

    @tag with_features: Features.all()
    test "a workspace made there starts in enforce where the organisation's policy requires it",
         ctx do
      {:ok, _} = OrganisationPolicy.set_floor(ctx.scope, true)
      {:ok, lv, _html} = live(ctx.conn, cards(ctx.scope))

      assert {:error, {:live_redirect, _}} = choose(ctx.conn, lv)

      workspace =
        Enum.find(Organisations.list_workspaces(ctx.scope), &(&1.slug == "software-factory"))

      there = workspace_scope(ctx.user, workspace)
      assert %{mode: "enforce"} = Policy.effective(there, nil)
    end
  end

  describe "as an owner demoted while the page is open" do
    test "Create workspace, sent after the owner is demoted, sends them back to the overview and makes nothing",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, cards(ctx.scope))
      page = open_type(ctx.conn, lv)

      # Written straight into the table: the open page hears nothing of it.
      {1, _} =
        Repo.update_all(
          from(m in Membership,
            where: m.user_id == ^ctx.user.id and m.organisation_id == ^ctx.scope.organisation.id
          ),
          set: [level: :member]
        )

      assert {:error, {:live_redirect, %{to: to}}} = create(page)
      assert to == ~p"/#{ctx.scope.organisation}"
      assert slugs(ctx.scope) == [ctx.scope.workspace.slug]
    end
  end

  describe "in an organisation with no workspace yet" do
    @describetag with_features: Features.all()

    test "the owner sees the kind cards and no New workspace button or entry", ctx do
      open!([:organisation])

      {:ok, %{organisation: organisation}} =
        ApiaryPro.Organisations.create_organisation(ctx.scope, %{"name" => "Kestrel Works"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}")
      assert has_element?(lv, "#set-up-card-software-link")
      refute has_element?(lv, "#new-workspace")

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}/settings/workspaces")
      refute has_element?(lv, "#new-workspace")
      refute has_element?(lv, "#new-menu-workspace")
    end

    test "New workspace is there once the owner has chosen a card", ctx do
      open!([:organisation])

      {:ok, %{organisation: organisation}} =
        ApiaryPro.Organisations.create_organisation(ctx.scope, %{"name" => "Kestrel Works"})

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}")
      assert {:error, {:live_redirect, _}} = choose(ctx.conn, lv)

      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}/settings/workspaces")
      assert has_element?(lv, "a#new-workspace.btn-primary", "New workspace")
      assert has_element?(lv, "#new-menu a#new-menu-workspace")
    end
  end

  describe "a client's admin, with a workspace" do
    @describetag needs: :managed_organisations

    for {flag, state} <- [{false, "off"}, {true, "on"}] do
      test "sees New workspace on Workspaces and on the overview, with the flag #{state}" do
        Flags.put_operator_infrastructure(unquote(flag))
        operator = operator_fixture()
        client = client_fixture(operator.scope)
        admin = client_member_fixture(client, :admin)
        conn = log_in_user(build_conn(), admin.user)

        for page <- ["", "/settings/workspaces"] do
          {:ok, lv, _html} = live(conn, "/#{client.organisation.slug}" <> page)

          assert has_element?(
                   lv,
                   "a#new-workspace.btn-primary[href='/#{client.organisation.slug}/workspaces/new']",
                   "New workspace"
                 )
        end
      end
    end
  end

  describe "the dead end of New workspace, for a person who may not create one" do
    # Core's 404 page for the path, with who creates workspaces.
    defp dead_end(conn, organisation) do
      {404, _headers, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/#{organisation}/workspaces/new") end)

      body
      |> LazyHTML.from_document()
      |> LazyHTML.query("#dead-end-line")
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end

    test "says Core's line in an organisation that is no client", ctx do
      %{user: user} = member_fixture(ctx.scope, :member)
      conn = log_in_user(build_conn(), user)

      assert dead_end(conn, ctx.scope.organisation) ==
               "Only owners of #{ctx.scope.organisation.name} create workspaces."
    end

    for {flag, state} <- [{false, "off"}, {true, "on"}] do
      @tag needs: :managed_organisations
      test "names a client's owners and admins, and the operator's owners only while the flag is on, with the flag #{state}" do
        Flags.put_operator_infrastructure(unquote(flag))
        operator = operator_fixture()
        client = client_fixture(operator.scope)
        member = client_member_fixture(client, :member)
        conn = log_in_user(build_conn(), member.user)
        name = client.organisation.name

        expected =
          if unquote(flag),
            do:
              "Only owners and admins of #{name}, and owners of #{operator.organisation.name}, create workspaces.",
            else: "Only owners and admins of #{name} create workspaces."

        assert dead_end(conn, client.organisation) == expected
      end
    end
  end

  describe "as an admin or a member" do
    test "the entries are absent and the cards are no page", ctx do
      for level <- [:admin, :member] do
        %{user: user} = member_fixture(ctx.scope, level)
        conn = log_in_user(build_conn(), user)

        assert_raise ApiaryWeb.NotFound, fn -> live(conn, cards(ctx.scope)) end

        {:ok, lv, _html} = live(conn, ~p"/#{ctx.scope.organisation}")
        refute has_element?(lv, "#new-workspace")
      end

      %{user: admin} = member_fixture(ctx.scope, :admin)

      {:ok, lv, _html} =
        live(log_in_user(build_conn(), admin), ~p"/#{ctx.scope.organisation}/settings/workspaces")

      assert has_element?(lv, "#settings-section-workspaces")
      refute has_element?(lv, "#new-workspace")
      assert slugs(ctx.scope) == [ctx.scope.workspace.slug]
    end
  end
end
