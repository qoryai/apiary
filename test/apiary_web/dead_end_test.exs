defmodule ApiaryWeb.DeadEndTest do
  # A path under an organisation the person reaches that leads nowhere for them is a `404`
  # inside the app's layout, which lists only the workspaces they reach.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Organisations.Membership
  alias Apiary.Repo

  defp joined(organisation, level) do
    user = user_fixture()

    %Membership{organisation_id: organisation.id, user_id: user.id}
    |> Membership.changeset(%{level: level})
    |> Repo.insert!()

    user
  end

  defp document(body), do: LazyHTML.from_document(body)

  defp texts(document, selector),
    do: document |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1) |> Enum.map(&words/1)

  defp words(text), do: text |> String.split() |> Enum.join(" ")

  defp hrefs(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  describe "an address that matches no workspace" do
    test "is a 404 in the layout, with the workspaces the person reaches", %{conn: conn} do
      %{user: user, organisation: organisation, workspace: main} = sign_up_fixture()
      staging = workspace_fixture(organisation, "Staging")

      conn = conn |> log_in_user(user) |> get(~p"/#{organisation}/software-factory")
      page = document(html_response(conn, 404))

      assert texts(page, "h1") == ["Workspace not found"]

      assert texts(page, "#dead-end-line") == [
               "You have no workspace at this address in #{organisation.name}. Its address changes when the workspace is renamed."
             ]

      assert hrefs(page, "#dead-end-workspaces a") ==
               Enum.map([main, staging], &"/#{organisation.slug}/#{&1.slug}")

      # The organisation's sidebar, as on its other pages.
      assert LazyHTML.query(page, "#sidebar") |> Enum.count() == 1
    end

    test "lists to a member only the workspaces they reach", %{conn: conn} do
      %{scope: owner, organisation: organisation, workspace: main} = sign_up_fixture()
      hidden = workspace_fixture(organisation, "Hidden")
      %{user: member} = member_fixture(owner, :member)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamed)
      Apiary.EditionStubs.MembersReachNamed.put([main.id])
      conn = log_in_user(conn, member)

      # An address that matches nothing, and one of a workspace the member does not reach,
      # get the same page, which names neither.
      for slug <- ["nothing-here", hidden.slug] do
        body = conn |> get(~p"/#{organisation}/#{slug}") |> html_response(404)
        page = document(body)

        assert hrefs(page, "#dead-end-workspaces a") == ["/#{organisation.slug}/#{main.slug}"]
        refute body =~ "Hidden"
      end

      # A member who reaches none gets the line, and no list.
      Apiary.EditionStubs.MembersReachNamed.put([])
      page = conn |> get(~p"/#{organisation}/nothing-here") |> html_response(404) |> document()

      assert texts(page, "#dead-end-line") != []
      assert LazyHTML.query(page, "#dead-end-workspaces") |> Enum.count() == 0
    end

    test "in an organisation the person does not reach is the plain 404", %{conn: conn} do
      %{organisation: other} = sign_up_fixture()
      %{user: user} = sign_up_fixture()
      conn = log_in_user(conn, user)

      for path <- [~p"/#{other}/main", ~p"/no-such-organisation/main"] do
        assert conn |> get(path) |> html_response(404) == "Not Found"
      end
    end
  end

  describe "New workspace for a person workspace.create does not allow" do
    test "at the limit shows everyone the limit's line, not who creates", %{conn: conn} do
      %{organisation: organisation} = sign_up_fixture()
      # The core's edition allows one workspace an organisation, and it has it.
      assert Apiary.Edition.Core.limits().workspaces == 1

      line =
        "Qory Apiary Community allows one workspace per organisation, and #{organisation.name} has it."

      for level <- [:admin, :member] do
        conn = log_in_user(conn, joined(organisation, level))

        {404, _headers, body} =
          assert_error_sent(404, fn -> get(conn, ~p"/#{organisation}/workspaces/new") end)

        page = document(body)
        assert texts(page, "h1") == ["New workspace"], "#{level}"
        assert texts(page, "[role=note] #set-up-limit") == [line], "#{level}"
        refute body =~ "Only owners", "#{level}"
        assert LazyHTML.query(page, "#dead-end-line") |> Enum.count() == 0
        assert LazyHTML.query(page, "#set-up-cards") |> Enum.count() == 0
        assert LazyHTML.query(page, "#sidebar") |> Enum.count() == 1
      end
    end

    test "below the limit is a 404 in the layout with who creates workspaces, and no cards",
         %{conn: conn} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
      %{organisation: organisation} = sign_up_fixture()
      admin = joined(organisation, :admin)
      conn = log_in_user(conn, admin)

      {404, _headers, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/#{organisation}/workspaces/new") end)

      page = document(body)
      assert texts(page, "h1") == ["New workspace"]

      assert texts(page, "#dead-end-line") == [
               "Only owners of #{organisation.name} create workspaces."
             ]

      assert LazyHTML.query(page, "#set-up-limit") |> Enum.count() == 0
      assert LazyHTML.query(page, "#set-up-cards") |> Enum.count() == 0
      assert LazyHTML.query(page, "#sidebar") |> Enum.count() == 1
    end

    test "of an organisation with no workspace shows the overview's waiting line", %{
      conn: conn
    } do
      {:ok, %{organisation: organisation}} =
        Organisations.sign_up_user(
          %{email: unique_user_email(), organisation_name: "Empty Co"},
          nil,
          open: true,
          workspace: false
        )

      admin = joined(organisation, :admin)
      conn = log_in_user(conn, admin)

      {404, _headers, body} =
        assert_error_sent(404, fn -> get(conn, ~p"/#{organisation}/workspaces/new") end)

      assert texts(document(body), "#dead-end-line") == [
               "An owner of Empty Co creates the first workspace."
             ]
    end
  end
end
