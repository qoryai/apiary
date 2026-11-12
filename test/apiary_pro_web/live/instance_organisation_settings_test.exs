defmodule ApiaryProWeb.InstanceOrganisationSettingsTest do
  @moduledoc """
  The settings of the instance organisation: its owners manage it as any organisation, and
  are told why it has no Delete. And an operator with clients, whose owner is told why it
  is not deleted, and what to do first.
  """
  # Not async: its owners' rows are the suite's instance organisation's, which every test
  # shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  setup %{conn: conn} do
    %{user: user} = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(user)
    instance = ApiaryPro.Organisations.instance_organisation()
    {:ok, scope} = Organisations.resolve_scope(Scope.for_user(user), instance.slug)
    %{conn: log_in_user(conn, user), instance: instance, scope: scope}
  end

  test "an owner sees why it cannot be deleted, and no Delete", %{conn: conn, instance: instance} do
    # The danger zone at the end of General says why, in place of the button.
    {:ok, lv, _html} = live(conn, ~p"/#{instance}/settings")

    assert has_element?(
             lv,
             "#danger-zone #delete-organisation-kept",
             "#{instance.name} runs this Qory Apiary, so it cannot be deleted."
           )

    refute has_element?(lv, "#delete-organisation")
    refute has_element?(lv, "#delete-organisation-button")
    # It is renamed as any organisation is.
    assert has_element?(lv, "#organisation-form")
  end

  test "its delete paths are refused, and nothing is marked", %{conn: conn, instance: instance} do
    {:ok, lv, _html} = live(conn, ~p"/#{instance}/settings")
    refute has_element?(lv, "#delete-organisation-form")
    general = ~p"/#{instance}/settings"

    for path <- [~p"/#{instance}/settings/danger", ~p"/#{instance}/settings/delete"] do
      assert {:error, {:live_redirect, %{to: ^general, flash: flash}}} = live(conn, path)
      assert flash["error"] =~ "#{instance.name} runs this Qory Apiary, so it cannot be deleted."
    end

    assert ApiaryPro.Organisations.instance_organisation().deletion_marked_at == nil
  end

  test "an ordinary organisation's owner keeps Delete, and no such line", %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_fixture()
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/#{organisation}/settings")

    assert has_element?(lv, "#danger-zone #delete-organisation-button")
    refute has_element?(lv, "#delete-organisation-kept")
  end

  @tag with_features: Apiary.Features.all()
  test "an operator with clients is not deleted, and its owner is told what to do first", %{
    conn: conn
  } do
    operator = ApiaryPro.OperatorsFixtures.operator_fixture()
    ApiaryPro.OperatorsFixtures.client_fixture(operator.scope)
    organisation = operator.organisation
    conn = log_in_user(conn, operator.user)

    {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/delete")

    lv
    |> form("#delete-organisation-form", confirm: %{slug: organisation.slug})
    |> render_submit()

    assert_patch(lv, ~p"/#{organisation}/settings")

    assert has_element?(lv, "#flash-error", "An operator with clients cannot be deleted.")

    assert has_element?(
             lv,
             "#flash-error",
             "On Clients, delete each client that has no owner and drop each one that has"
           )

    assert has_element?(lv, "#flash-error", "a deleted client counts until it is purged.")

    assert Apiary.Repo.get!(Apiary.Organisations.Organisation, organisation.id).deletion_marked_at ==
             nil
  end
end
