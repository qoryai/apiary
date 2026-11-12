defmodule ApiaryProWeb.InstanceLive.AccountsTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Accounts, Features}
  alias ApiaryPro.Suspensions

  @moduletag with_features: Features.all()

  setup %{conn: conn} do
    admin = suite_instance_admin()
    here = admin.instance_scope.organisation
    %{conn: log_in_user(conn, admin.user), admin: admin, here: here}
  end

  test "a section of Instance settings of its own, beside Organisations", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts")
    render_async(lv)

    # The Instance settings level: its sections are the second column, the sidebar the one
    # the person came from, and the organisation's has no Instance settings entry.
    assert has_element?(lv, "#settings-section-accounts.q-settings-main-list")
    assert has_element?(lv, "h1#settings-section-title", "Accounts")
    assert has_element?(lv, "#instance-tabs-heading", "Instance settings")
    assert has_element?(lv, "#instance-tabs #instance-tab-accounts[aria-current=page]")

    assert has_element?(
             lv,
             ~s(#instance-tabs a#instance-tab-organisations[href="/instance/organisations"])
           )

    refute has_element?(lv, "#nav-instance")
    assert has_element?(lv, "#breadcrumb a", "Instance settings")
    assert has_element?(lv, "#breadcrumb [aria-current=page]", "Accounts")
    refute has_element?(lv, "#organisations")
    assert page_title(lv) == "Accounts · Instance settings · Qory Apiary"
  end

  test "lists every account, and suspends one, ending its sessions", ctx do
    %{user: user} = sign_up_fixture()
    token = Accounts.generate_user_session_token(user)
    ApiaryWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts")
    render_async(lv)

    assert has_element?(lv, "#account-#{user.id}", user.email)
    assert has_element?(lv, "#account-#{user.id}-memberships", "1 membership")
    # Under the email too, for a table too narrow for the column.
    assert has_element?(lv, "#account-#{user.id} .q-fold-line .q-fold", "1 membership")
    assert has_element?(lv, "#account-#{user.id}-status", "Active")
    # Not their own.
    assert has_element?(lv, "#account-#{ctx.admin.user.id}", "you")
    refute has_element?(lv, "#account-#{ctx.admin.user.id}-suspend-button")

    lv |> element("#account-#{user.id}-suspend-button") |> render_click()
    assert_patch(lv, ~p"/instance/accounts/#{user.id}/suspend")

    assert has_element?(
             lv,
             "#account-#{user.id}.q-confirming #suspend-account",
             "signed out everywhere"
           )

    # Nothing it holds is removed: a key belongs to its node, and the keys it added work on.
    assert has_element?(lv, "#suspend-account", "and the access keys they added keep working.")
    assert has_element?(lv, "#suspend-account-confirm", "Yes, suspend")

    lv |> element("#suspend-account-confirm") |> render_click()
    assert_patch(lv, ~p"/instance/accounts")
    assert render(lv) =~ "#{user.email} is suspended."
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    refute Accounts.get_user_by_session_token(token)
    assert Suspensions.account_suspended?(user.id)

    render_async(lv)
    assert has_element?(lv, "#account-#{user.id}-status", "Suspended")

    lv |> element("#account-#{user.id}-activate-button") |> render_click()
    assert render(lv) =~ "#{user.email} is active again."
    refute Suspensions.account_suspended?(user.id)
  end

  test "the confirmation names the organisations left without an owner who can act", ctx do
    %{user: user, organisation: organisation} = sign_up_fixture()

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts/#{user.id}/suspend")
    render_async(lv)

    assert has_element?(lv, "#suspend-account-sole-owner", organisation.name)

    # Cancel gives the row back.
    lv |> element("#suspend-account-cancel") |> render_click()
    assert_patch(lv, ~p"/instance/accounts")
    refute has_element?(lv, "#suspend-account")
    refute Suspensions.account_suspended?(user.id)
  end

  test "their own account is not suspended by its path", ctx do
    {:ok, lv, _html} =
      live(ctx.conn, ~p"/instance/accounts/#{ctx.admin.user.id}/suspend")

    render_async(lv)
    refute has_element?(lv, "#suspend-account")
  end

  test "the server refuses an instance admin's suspension of their own account", ctx do
    # Another instance admin, so the instance would keep an owner who can act: what is
    # refused is the account being their own.
    instance_admin_fixture()
    own = ctx.admin.user.id

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts/#{own}/suspend")
    render_async(lv)
    refute has_element?(lv, "#suspend-account-confirm")

    # The confirmation's event, sent as a page that offered it would.
    render_hook(lv, "suspend_account", %{})
    assert_patch(lv, ~p"/instance/accounts")
    assert render(lv) =~ "That is no longer possible."
    refute Suspensions.account_suspended?(own)
  end

  test "the views and the search narrow the list, in the URL", ctx do
    %{user: kept} = sign_up_fixture(%{email: "kept@example.com"})
    %{user: gone} = sign_up_fixture(%{email: "gone@example.com"})
    {:ok, _} = Suspensions.suspend_account(ctx.admin.instance_scope, gone.id)

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts?view=suspended")
    render_async(lv)
    assert has_element?(lv, "#accounts-view-suspended[aria-current=page]", "1")
    assert has_element?(lv, "#account-#{gone.id}")
    refute has_element?(lv, "#account-#{kept.id}")

    lv |> element("#accounts-view-all") |> render_click()
    assert_patch(lv, ~p"/instance/accounts")
    assert has_element?(lv, "#account-#{kept.id}")

    lv |> form("#accounts-search", q: "kept@") |> render_change()
    assert_patch(lv, ~p"/instance/accounts?q=kept%40")
    assert has_element?(lv, "#account-#{kept.id}")
    refute has_element?(lv, "#account-#{gone.id}")
    assert has_element?(lv, "#accounts-status", "1 account matches")

    lv |> form("#accounts-search", q: "nobody-here") |> render_change()
    refute has_element?(lv, "#accounts")
    assert has_element?(lv, "#accounts-none", "No account matches")
    lv |> element("#accounts-clear") |> render_click()
    assert_patch(lv, ~p"/instance/accounts")
    assert has_element?(lv, "#account-#{gone.id}")
  end

  test "an empty view says what it keeps, an empty search that nothing matches", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts?view=suspended")
    render_async(lv)
    assert has_element?(lv, "#accounts-none", "No account is suspended")
    refute has_element?(lv, "#accounts-clear")

    lv |> form("#accounts-search", q: "nobody-here") |> render_change()
    assert has_element?(lv, "#accounts-none", "No account matches")
  end

  test "the page is not there for the instance organisation's admins, nor anyone else", ctx do
    %{user: admin} = member_fixture(ctx.admin.instance_scope, :admin)

    assert_raise ApiaryWeb.NotFound, fn ->
      live(log_in_user(build_conn(), admin), ~p"/instance/accounts")
    end

    %{user: stranger} = sign_up_fixture()

    assert_raise ApiaryWeb.NotFound, fn ->
      live(log_in_user(build_conn(), stranger), ~p"/instance/accounts")
    end
  end
end
