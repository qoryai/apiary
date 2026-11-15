defmodule ApiaryProWeb.ClientLive.FirstWorkspaceSetUpTest do
  @moduledoc """
  A client of an operator starts with no workspace, and its first person's invitation is to
  the organisation alone: accepting it lands on the client's overview, `/:org`, which shows
  the kind cards. A card opens the type's page, and Create workspace there creates the first
  workspace and opens its Name step.
  With `ApiaryPro.Flags.operator_infrastructure?/0` off the first person is the owner; with
  it on they are the admin. Both create the workspace. The operator's people, who reach
  only the workspaces the operator operates, do not reach a client with none, and a member
  of the client reads the line on who creates it.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures, only: [user_fixture: 1, unique_user_email: 0]
  import ApiaryPro.OperatorsFixtures
  import Apiary.OrganisationsFixtures, only: [member_fixture: 2]
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Features, Organisations, Repo}
  alias Apiary.Organisations.{Membership, Workspace}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture()
    address = unique_user_email()

    {%{organisation: client}, token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => address})

    %{operator: operator, client: client, address: address, token: token}
  end

  # The first person signed in and the invitation's page opened and accepted: where it leads.
  defp accept(conn, ctx) do
    user = user_fixture(%{email: ctx.address})
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/invitations/#{ctx.token}")
    overview = ~p"/#{ctx.client}"

    assert {:error, {:redirect, %{to: ^overview}}} =
             lv |> element("button", "Accept invitation") |> render_click()

    {conn, user}
  end

  # The Software factory card links to the type's page; Create workspace there creates the
  # workspace and opens its Name step.
  defp choose(conn, lv) do
    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("#set-up-card-software-link") |> render_click()

    {:ok, page, _html} = live(conn, to)

    {:ok, name, _html} =
      page |> element("#workspace-type-create") |> render_click() |> follow_redirect(conn)

    name
  end

  defp workspaces(client),
    do: Repo.all(from w in Workspace, where: w.organisation_id == ^client.id)

  test "the sign-up page says the invitation is to the organisation", %{conn: conn} = ctx do
    {:ok, lv, _html} = live(conn, ~p"/users/register?invitation=#{ctx.token}")

    assert render(lv) =~ "You are invited to"
    assert render(lv) =~ ctx.client.name
    refute render(lv) =~ "workspace at"
  end

  describe "with the flag off" do
    test "the owner accepts, lands on the overview and chooses the card", %{conn: conn} = ctx do
      {conn, user} = accept(conn, ctx)

      assert [membership] = Organisations.list_memberships(user)
      assert {membership.organisation_id, membership.level} == {ctx.client.id, :owner}

      # The landing sends them there as well.
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{ctx.client}"

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client}")
      assert has_element?(lv, "#set-up-card-software-link")
      refute has_element?(lv, "#first-workspace-waiting")

      name = choose(conn, lv)
      assert has_element?(name, "h1", "Name this workspace")

      assert [%Workspace{name: "Software factory", slug: "software-factory"}] =
               workspaces(ctx.client)

      assert Organisations.has_workspace?(ctx.client)
    end
  end

  describe "with the flag on" do
    test "the first person is the admin, sees the cards and chooses one", %{conn: conn} = ctx do
      Flags.put_operator_infrastructure(true)
      {conn, user} = accept(conn, ctx)

      assert [membership] = Organisations.list_memberships(user)
      assert {membership.organisation_id, membership.level} == {ctx.client.id, :admin}
      assert redirected_to(get(conn, ~p"/")) == ~p"/#{ctx.client}"

      {:ok, lv, _html} = live(conn, ~p"/#{ctx.client}")
      assert has_element?(lv, "#set-up-card-software-link")
      refute has_element?(lv, "#first-workspace-waiting")
      refute render(lv) =~ "does this"
      refute render(lv) =~ "its operator, sets up"

      name = choose(conn, lv)
      assert has_element?(name, "h1", "Name this workspace")
      assert [%Workspace{name: "Software factory"}] = workspaces(ctx.client)
    end

    test "the operator's owner and admin, with no workspace of it to operate, do not reach it",
         %{conn: conn} = ctx do
      Flags.put_operator_infrastructure(true)
      %{user: admin} = member_fixture(ctx.operator.scope, :admin)

      for user <- [ctx.operator.user, admin] do
        assert scope_in(user, ctx.client) == nil
        assert html_response(get(log_in_user(conn, user), ~p"/#{ctx.client}"), 404)
      end

      refute Organisations.has_workspace?(ctx.client)
    end

    test "an ordinary member of the client reads who creates the first workspace",
         %{conn: conn} = ctx do
      Flags.put_operator_infrastructure(true)
      member = user_fixture(%{})

      Repo.insert!(%Membership{
        organisation_id: ctx.client.id,
        user_id: member.id,
        level: :member
      })

      {:ok, lv, _html} = live(log_in_user(conn, member), ~p"/#{ctx.client}")

      assert has_element?(
               lv,
               "#first-workspace-waiting",
               "An owner or an admin of #{ctx.client.name} creates the first workspace."
             )

      refute has_element?(lv, "#set-up-cards")
      refute has_element?(lv, "#set-up-card-software-link")
      refute render(lv) =~ "its operator"

      # The type's page, opened by its path, is refused to them like a page that does not exist.
      assert_raise ApiaryWeb.NotFound, fn ->
        live(log_in_user(conn, member), ~p"/#{ctx.client}/workspaces/new/qory.software")
      end

      refute Organisations.has_workspace?(ctx.client)
    end

    test "the dead end of New workspace says the same, before the client has a workspace",
         %{conn: conn} = ctx do
      member = user_fixture(%{})

      Flags.put_operator_infrastructure(false)

      Repo.insert!(%Membership{
        organisation_id: ctx.client.id,
        user_id: member.id,
        level: :member
      })

      dead_end = fn ->
        {404, _headers, body} =
          assert_error_sent(404, fn ->
            get(log_in_user(conn, member), ~p"/#{ctx.client}/workspaces/new")
          end)

        body
        |> LazyHTML.from_document()
        |> LazyHTML.query("#dead-end-line")
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end

      assert dead_end.() ==
               "An owner or an admin of #{ctx.client.name} creates the first workspace."

      Flags.put_operator_infrastructure(true)

      assert dead_end.() ==
               "An owner or an admin of #{ctx.client.name} creates the first workspace."
    end
  end
end
