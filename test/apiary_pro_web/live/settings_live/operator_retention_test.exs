defmodule ApiaryProWeb.SettingsLive.OperatorRetentionTest do
  @moduledoc """
  A client's retention while the operator owns its clients
  (`ApiaryPro.Flags.operator_infrastructure?/0`): the operator sets it, and a save by the
  client's owner or admin is refused in the words of who sets it, not the core's default.
  """
  # The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  @params %{"retention" => %{"events_retention_days" => "7", "log_retention_days" => "7"}}

  # The operator Hive Ops and its client Acme, made while the flag was off, then the flag
  # on.
  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture(%{organisation_name: "Hive Ops"})
    client = client_fixture(operator.scope, "Acme")
    client_admin = client_member_fixture(client, :admin)
    Flags.put_operator_infrastructure(true)

    %{operator: operator, client: client, client_admin: client_admin}
  end

  defp settings(ctx, user) do
    path = "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}/settings"
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), path)
    lv
  end

  defp days(ctx), do: Repo.reload!(ctx.client.workspace).events_retention_days

  test "a refused save says that the operator sets it", ctx do
    before = days(ctx)

    for user <- [ctx.client_admin.user, ctx.client.owner.user] do
      lv = settings(ctx, user)
      render_hook(lv, "save_retention", @params)

      # The flash puts the sentence's first part in bold and the rest beneath it.
      flash = lv |> element("#flash-error") |> render()
      assert flash =~ "Set by your operator, Hive Ops."
      assert flash =~ "Ask them to change it."
      refute flash =~ "Only owners and admins can change these settings."

      assert days(ctx) == before
    end
  end

  test "the operator's admin saves it", ctx do
    admin = member_fixture(ctx.operator.scope, :admin)
    lv = settings(ctx, admin.user)
    render_hook(lv, "save_retention", @params)

    assert days(ctx) == 7
  end

  test "with the flag off, the client's admin saves it as before", ctx do
    Flags.put_operator_infrastructure(false)
    lv = settings(ctx, ctx.client_admin.user)
    render_hook(lv, "save_retention", @params)

    assert days(ctx) == 7
  end
end
