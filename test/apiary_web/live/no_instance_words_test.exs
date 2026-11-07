defmodule ApiaryWeb.NoInstanceWordsTest do
  # Texts that differ by reader: an instance admin keeps the fix line that leads to
  # Instance settings; a person of another organisation reads Contact support, which links
  # to the support address where one is set. Not async: the support address and the
  # features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{KeyDerivation, Secrets, SupportAddress}

  @moduletag needs: :factory

  # `Apiary.SupportAddress.parse/1` refuses `<`, `>` and `"` in an address, and accepts
  # these two characters that HTML escapes.
  @address "https://help.example.com/a'b?x=1&y=2"
  @escaped "https://help.example.com/a&#39;b?x=1&amp;y=2"

  setup %{conn: conn} do
    Application.put_env(:apiary, :support_address, nil)
    on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)

    admin = instance_admin_scope()
    %{user: user, scope: scope} = sign_up_fixture()

    %{
      admin: admin,
      admin_conn: log_in_user(conn, admin.user),
      scope: scope,
      owner_conn: log_in_user(conn, user)
    }
  end

  # A person changes a value that the running server cannot read: the value was stored
  # under another encryption secret.
  defp change_unreadable_value(conn, scope) do
    {:ok, secret} = Secrets.create_secret(scope, %{name: "API_KEY", value: "the value"})
    Application.put_env(:apiary, KeyDerivation, secret: :binary.copy(<<3>>, 32))

    {:ok, lv, _html} =
      live(
        conn,
        "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/secrets/" <>
          "#{secret.public_id}/change-value"
      )

    lv |> form("#secret-form", secret_value: %{value: "next value"}) |> render_submit()
    render(lv)
  end

  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/integrations/new"
  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/integrations"

  describe "a value stored under another encryption secret" do
    @describetag needs: :secrets

    setup do
      before = Application.get_env(:apiary, KeyDerivation)
      on_exit(fn -> Application.put_env(:apiary, KeyDerivation, before) end)
    end

    test "an instance admin reads which secret", ctx do
      admin = %{ctx.admin | workspace: workspace_fixture(ctx.admin.organisation, "Build")}

      assert change_unreadable_value(ctx.admin_conn, admin) =~
               "the instance&#39;s encryption secret is not the one they were stored under."
    end

    test "a person of another organisation reads Contact support", ctx do
      html = change_unreadable_value(ctx.owner_conn, ctx.scope)

      assert html =~ "Contact support."
      assert html =~ "they were stored under another encryption secret."
      refute html =~ "nstance"
    end

    test "an address with characters HTML escapes stays escaped in the flash", ctx do
      assert SupportAddress.parse(@address) == {:ok, @address}
      Application.put_env(:apiary, :support_address, @address)

      html = change_unreadable_value(ctx.owner_conn, ctx.scope)

      assert html =~ "Contact support at #{@escaped}."
      refute html =~ @address
    end

    test "with a support address, the flash has the address after the words", ctx do
      Application.put_env(:apiary, :support_address, "support@example.com")

      assert change_unreadable_value(ctx.owner_conn, ctx.scope) =~
               "Contact support at support@example.com."
    end
  end

  describe "an invitation over the day's limit" do
    setup do
      before = Application.fetch_env!(:apiary, :invitations_per_day)
      Application.put_env(:apiary, :invitations_per_day, 0)
      on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, before) end)
    end

    test "an address with characters HTML escapes stays escaped in the form error", ctx do
      assert SupportAddress.parse(@address) == {:ok, @address}
      Application.put_env(:apiary, :support_address, @address)

      {:ok, lv, _html} =
        live(ctx.owner_conn, ~p"/#{ctx.scope.organisation}/settings/people/invite")

      html =
        lv
        |> form("#invitation-form", invitation: %{email: "bee@example.com"})
        |> render_submit()

      assert html =~ "Try again later, or contact support at #{@escaped}."
      refute html =~ @address
    end
  end

  describe "a workspace whose read of the Qory harness failed" do
    test "the flash has the support address after the words, as plain text", %{conn: conn} do
      Application.put_env(:apiary, :support_address, "support@example.com")

      {:ok, %{user: user, organisation: organisation}} =
        Apiary.Organisations.sign_up_user(
          %{email: Apiary.AccountsFixtures.unique_user_email(), organisation_name: "Northwind"},
          nil,
          open: true,
          workspace: false
        )

      Apiary.PublicGitServer.serve(%{},
        answer: fn conn -> Plug.Conn.send_resp(conn, 429, "") end
      )

      {:ok, lv, _html} =
        conn |> log_in_user(user) |> live(~p"/#{organisation}/workspaces/new/qory.software")

      lv |> element("#workspace-type-create") |> render_click()

      flash =
        lv
        |> element("#flash-error")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      # The flash shows the first sentence as its title.
      assert flash =~ "Create the workspace again later."

      assert flash =~
               "Reading the harness from https://github.com/qoryai/harness failed: the host " <>
                 "returned 429 Too Many Requests. If it fails again, contact support at " <>
                 "support@example.com."
    end
  end

  describe "Add an integration" do
    test "with none set up, an instance admin reads where to set one up; an owner reads Contact support",
         ctx do
      {:ok, lv, _html} = live(ctx.admin_conn, new_path(ctx.admin))
      assert render(lv) =~ "An instance admin sets one up in Instance settings › Adapters."

      {:ok, lv, html} = live(ctx.owner_conn, new_path(ctx.scope))
      assert has_element?(lv, "#add-none-set-up", "Contact support to add an integration.")
      refute html =~ "nstance"
    end

    test "the support address links the words", ctx do
      Application.put_env(:apiary, :support_address, "https://help.example.com")

      {:ok, lv, _html} = live(ctx.owner_conn, new_path(ctx.scope))

      assert has_element?(
               lv,
               ~s(#add-none-set-up a[href="https://help.example.com"]),
               "Contact support"
             )
    end
  end

  describe "an integration that cannot be installed yet" do
    test "shows to an instance admin with why, and to no one else", ctx do
      adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})

      {:ok, lv, _html} = live(ctx.owner_conn, list_path(ctx.scope))
      refute render(lv) =~ adapter.name

      {:ok, lv, _html} = live(ctx.admin_conn, list_path(ctx.admin))
      assert render(lv) =~ adapter.name
    end

    test "offered/3 keeps one with a connection, for anyone", ctx do
      adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})
      offered = &ApiaryWeb.IntegrationComponents.offered/3

      assert offered.(ctx.scope, [adapter], []) == []
      assert offered.(ctx.scope, [adapter], [adapter.id]) == [adapter]
      assert offered.(ctx.admin, [adapter], []) == [adapter]
    end

    test "an instance admin keeps the line on its own page", ctx do
      adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})

      {:ok, lv, _html} =
        live(
          ctx.admin_conn,
          ~p"/#{ctx.admin.organisation}/settings/integrations/#{adapter.public_id}"
        )

      assert has_element?(
               lv,
               "#integration-install-not-ready",
               "#{adapter.name} can't be installed yet: this instance's admins are still setting it up."
             )
    end
  end

  describe "the install command's notice on a loopback address" do
    test "an instance admin reads the fix; anyone else reads Contact support" do
      render = fn admin? ->
        render_component(&ApiaryWeb.NodeComponents.unreachable_server/1,
          id: "unreachable",
          url: "http://localhost:4000",
          instance_admin: admin?
        )
      end

      assert render.(true) =~ "Set PUBLIC_URL to the address machines use"

      refute render.(false) =~ "PUBLIC_URL"
      assert render.(false) =~ "Contact support"
      assert render.(false) =~ "Machines can&#39;t reach http://localhost:4000"
    end
  end
end
