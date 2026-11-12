defmodule ApiaryProWeb.SuspensionNoticesTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Suspensions

  @moduletag with_features: Features.all()

  setup do
    %{instance: suite_instance_admin().instance_scope}
  end

  test "a suspended organisation's pages say it is read-only, and offer no change", ctx do
    home = sign_up_fixture()
    %{membership: member} = member_fixture(home.scope, :member)
    {:ok, _} = Suspensions.suspend_organisation(ctx.instance, home.organisation.id)

    conn = log_in_user(build_conn(), home.user)
    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings/people")

    assert has_element?(lv, "#organisation-suspended", "#{home.organisation.name} is suspended:")
    assert has_element?(lv, "#organisation-suspended", "access keys are refused")
    assert has_element?(lv, "#organisation-suspended", "Contact support.")
    refute has_element?(lv, "#owner-suspended")
    refute has_element?(lv, "a", "Invite member")
    refute has_element?(lv, "#member-#{member.id}-remove")
    refute has_element?(lv, "#member-#{member.id}-suspend")

    # Every page of it, a workspace's among them.
    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/#{home.workspace}/machines")
    assert has_element?(lv, "#organisation-suspended")

    # Its settings say it is suspended, not that only owners and admins change them.
    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings")
    assert has_element?(lv, "#organisation-suspended")
    refute render(lv) =~ "Only owners and admins can change these settings"

    # And none once it is activated.
    {:ok, _} = Suspensions.activate_organisation(ctx.instance, home.organisation.id)
    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings/people")
    refute has_element?(lv, "#organisation-suspended")
    assert has_element?(lv, "#member-#{member.id}-suspend")
  end

  test "a client of a suspended operator carries no notice: its owners are its own", ctx do
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    %{user: admin} = member_fixture(client.owner.scope, :admin)
    {:ok, _} = Suspensions.suspend_organisation(ctx.instance, operator.organisation.id)

    {:ok, lv, _html} =
      live(log_in_user(build_conn(), admin), ~p"/#{client.organisation}/settings/people")

    refute has_element?(lv, "#owner-suspended")
    refute has_element?(lv, "#organisation-suspended")

    # Its own owner suspended, it says so.
    {:ok, _} = Suspensions.suspend_account(ctx.instance, client.owner.user.id)

    {:ok, lv, _html} =
      live(log_in_user(build_conn(), admin), ~p"/#{client.organisation}/settings/people")

    assert has_element?(lv, "#owner-suspended", "its runs continue")
    assert has_element?(lv, "#owner-suspended", "waits until support acts. Contact support.")
  end

  test "an organisation whose owners are all suspended says so to its admins", ctx do
    home = sign_up_fixture()
    %{user: admin} = member_fixture(home.scope, :admin)
    conn = log_in_user(build_conn(), admin)

    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings/people")
    refute has_element?(lv, "#owner-suspended")

    {:ok, _} = Suspensions.suspend_account(ctx.instance, home.user.id)

    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings/people")
    assert has_element?(lv, "#owner-suspended", "Every owner of #{home.organisation.name}")
  end

  test "the notices stand together above the page, and none leaves no stack", ctx do
    home = sign_up_fixture()
    %{user: admin, membership: membership} = member_fixture(home.scope, :admin)
    conn = log_in_user(build_conn(), admin)

    {:ok, lv, _html} = live(conn, ~p"/#{home.organisation}/settings/people")
    refute has_element?(lv, "#organisation-notices")

    {:ok, _} = Suspensions.suspend_account(ctx.instance, home.user.id)

    {:ok, _} =
      ApiaryPro.Transfers.arbitrate(
        ctx.instance,
        home.organisation.id,
        membership.id,
        "The owner is away."
      )

    {:ok, lv, html} = live(conn, ~p"/#{home.organisation}/settings/people")

    # One stack in the main column, before the page, the core's notices in it.
    assert has_element?(lv, "main #organisation-notices #owner-suspended [role=note]")

    assert has_element?(
             lv,
             "#organisation-notices #ownership-offer-notice [role=note] a[href='/#{home.organisation.slug}/settings/ownership']",
             "see the offer"
           )

    {stack, _} = :binary.match(html, ~s(id="organisation-notices"))
    {page, _} = :binary.match(html, "<h1")
    assert stack < page
  end

  test "a page without an organisation carries no notice", ctx do
    home = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_organisation(ctx.instance, home.organisation.id)

    {:ok, lv, _html} = live(log_in_user(build_conn(), home.user), ~p"/users/organisations")
    refute has_element?(lv, "#organisation-suspended")
    refute has_element?(lv, "#organisation-notices")
  end
end
