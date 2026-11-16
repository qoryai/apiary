defmodule ApiaryProWeb.SettingsLive.OperatorRetentionTest do
  @moduledoc """
  The retention of an operated workspace while `ApiaryPro.Flags.operator_infrastructure?/0`
  is on: the operator's owners and admins set it, and so do the organisation's owner and
  admins. With the flag off, a save by the operator's admin is refused and changes nothing.
  """
  # The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  defp params(days),
    do: %{"retention" => %{"events_retention_days" => "#{days}", "log_retention_days" => "7"}}

  # The operator Hive Ops operates the workspace Main of Acme, and the flag is on.
  setup do
    Flags.put_operator_infrastructure(true)
    operator = operator_fixture(%{organisation_name: "Hive Ops"})
    operated = operated_fixture(operator.scope, "Acme")
    admin = organisation_member_fixture(operated, :admin)

    %{operator: operator, operated: operated, admin: admin}
  end

  defp settings(ctx, user) do
    path = "/#{ctx.operated.organisation.slug}/#{ctx.operated.workspace.slug}/settings"
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path)
    lv
  end

  defp days(ctx), do: Repo.reload!(ctx.operated.workspace).events_retention_days

  test "the organisation's owner and admin save it", ctx do
    for {user, days} <- [{ctx.admin.user, 7}, {ctx.operated.owner.user, 14}] do
      lv = settings(ctx, user)
      render_hook(lv, "save_retention", params(days))

      refute has_element?(lv, "#flash-error")
      assert days(ctx) == days
    end
  end

  test "the operator's admin saves it", ctx do
    admin = member_fixture(ctx.operator.scope, :admin)
    lv = settings(ctx, admin.user)
    render_hook(lv, "save_retention", params(7))

    assert days(ctx) == 7
  end

  test "with the flag off, a save by the operator's admin is refused", ctx do
    admin = member_fixture(ctx.operator.scope, :admin)
    Flags.put_operator_infrastructure(false)
    before = days(ctx)
    lv = settings(ctx, admin.user)
    render_hook(lv, "save_retention", params(7))

    assert has_element?(lv, "#flash-error")
    assert days(ctx) == before
  end
end
