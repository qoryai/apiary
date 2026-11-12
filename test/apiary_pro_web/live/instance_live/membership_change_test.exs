defmodule ApiaryProWeb.InstanceLive.MembershipChangeTest do
  @moduledoc """
  An instance admin whose role in the instance organisation changes while Instance
  settings › Accounts (`ApiaryProWeb.InstanceLive.Accounts`) is open: made a member, made
  an admin, or removed, moves to `/`; a change elsewhere keeps the page as it is.
  """
  # Not async: granting an instance admin, a change of level and a removal lock the
  # instance organisation's owner memberships until the test ends.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Organisations}

  @moduletag with_features: Features.all()

  # A fresh instance admin, whose level changes, and the suite's instance admin, who
  # changes it.
  setup %{conn: conn} do
    admin = instance_admin_fixture()

    %{
      conn: log_in_user(conn, admin.user),
      admin: admin,
      here: admin.instance_scope.organisation,
      other: suite_instance_admin().instance_scope
    }
  end

  test "an instance admin made a member moves to / from the open page, without a click", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts")
    render_async(lv)
    assert has_element?(lv, "#account-#{ctx.admin.user.id}", "you")

    {:ok, _member} =
      Organisations.set_member_level(ctx.other, ctx.admin.instance_scope.membership.id, :member)

    assert_redirect(lv, "/")
  end

  test "an owner made an admin moves to / from the open page, without a click", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts")
    render_async(lv)

    {:ok, _admin} =
      Organisations.set_member_level(ctx.other, ctx.admin.instance_scope.membership.id, :admin)

    assert_redirect(lv, "/")
  end

  test "an instance admin removed while their scope is in Web shop moves to /", ctx do
    shop = sign_up_fixture(%{organisation_name: "Web shop"})
    join_fixture(shop.scope, ctx.admin.user)
    conn = put_session(ctx.conn, :last_workspace_id, shop.workspace.id)

    {:ok, lv, _html} = live(conn, ~p"/instance/accounts")
    render_async(lv)

    assert :sys.get_state(lv.pid).socket.assigns.current_scope.organisation.id ==
             shop.organisation.id

    {:ok, _removed} =
      Organisations.remove_member(ctx.other, ctx.admin.instance_scope.membership.id)

    assert_redirect(lv, "/")
  end

  test "an instance admin removed while their scope is in the instance organisation moves to /",
       ctx do
    # The membership of the scope is gone, so `ApiaryWeb.UserAuth.reload_scope/1` sends
    # the page to `/`, before and after the page mounts on Core's Access check.
    workspace = workspace_fixture(ctx.here)
    conn = put_session(ctx.conn, :last_workspace_id, workspace.id)

    {:ok, lv, _html} = live(conn, ~p"/instance/accounts")
    render_async(lv)

    assert :sys.get_state(lv.pid).socket.assigns.current_scope.organisation.id == ctx.here.id

    {:ok, _removed} =
      Organisations.remove_member(ctx.other, ctx.admin.instance_scope.membership.id)

    assert_redirect(lv, "/")
  end

  test "an instance admin who joins Web shop keeps the page and the password link shown", ctx do
    %{user: user} = sign_up_fixture()
    shop = sign_up_fixture(%{organisation_name: "Web shop"})
    Apiary.Mail.put_test_source(:none)

    {:ok, lv, _html} = live(ctx.conn, ~p"/instance/accounts")
    render_async(lv)
    lv |> element("#account-#{user.id}-password-link") |> render_click()
    panel = lv |> element("#password-link") |> render()

    # Accepting an invitation sends no membership message, so the level change sends
    # it. The hook then runs Core's step for the Instance pages, and a redirect there
    # ends the page.
    %{membership: membership} = join_fixture(shop.scope, ctx.admin.user)
    {:ok, _admin} = Organisations.set_member_level(shop.scope, membership.id, :admin)

    # The page lists Web shop only after the hook handled the message.
    assigns = :sys.get_state(lv.pid).socket.assigns
    assert shop.organisation.id in Enum.map(assigns.memberships, & &1.organisation_id)
    # Core's step computed the instance scope again, and the level there is unchanged.
    assert assigns.scope.membership.level == Apiary.Access.instance_admin_level()
    assert lv |> element("#password-link") |> render() == panel
    refute_redirected(lv)
  end
end
