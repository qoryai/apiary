defmodule ApiaryProWeb.StagesLive.TimeLimitOperatedTest do
  # A workflow's time limit on Workspace settings › Workflows in a workspace an operator
  # operates: while `ApiaryPro.Flags.operator_infrastructure?/0` is on, the operator sets
  # the time limits there, so a person of the organisation sees the saved limit in a
  # disabled field with the operator's name, no button, and a save changes nothing; the
  # operator's owner changes it. With the flag off, the organisation's owner changes it.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  alias Apiary.TimeLimits
  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  @field "#stage-entry-0-time-limit"

  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture(%{organisation_name: "Contoso"})
    operated = operated_fixture(operator.scope, "Northwind")
    {:ok, _} = TimeLimits.put_limit(operated.owner.scope, :workspace, "explore-a-ticket", 240)
    Flags.put_operator_infrastructure(true)

    %{operator: operator, operated: operated}
  end

  defp path(%{organisation: organisation, workspace: workspace}),
    do: ~p"/#{organisation}/#{workspace}/settings/workflows"

  defp limits(scope) do
    {:ok, limits} = TimeLimits.list_limits(scope)
    Enum.map(limits, &{&1.workflow, &1.minutes})
  end

  test "the organisation's owner sees the operator's name and no way to change the limit", %{
    conn: conn,
    operated: operated
  } do
    {:ok, view, _html} = live(log_in_user(conn, operated.owner.user), path(operated))

    assert has_element?(view, ~s{#{@field}[value="240"][disabled]})
    refute has_element?(view, "#stage-entry-0-time-limit-save")
    refute has_element?(view, "#stage-entry-0-time-limit-hint")

    assert has_element?(
             view,
             "#stage-entry-0-time-limit-note",
             "Set by your operator, Contoso. Ask them to change it."
           )

    assert has_element?(view, "#stage-entry-0-time-limit-line", "Time limit: 240 minutes")

    view
    |> element("#stage-entry-0-time-limit-form")
    |> render_submit(%{"time_limit" => %{"minutes" => "30"}})

    assert limits(operated.owner.scope) == [{"explore-a-ticket", 240}]
  end

  test "the operator's owner changes the limit", %{
    conn: conn,
    operator: operator,
    operated: operated
  } do
    {:ok, view, _html} = live(log_in_user(conn, operator.user), path(operated))

    refute has_element?(view, "#stage-entry-0-time-limit-note")
    assert has_element?(view, "#stage-entry-0-time-limit-save[disabled]", "Save time limit")

    view
    |> element("#stage-entry-0-time-limit-form")
    |> render_submit(%{"time_limit" => %{"minutes" => "30"}})

    assert limits(operated.owner.scope) == [{"explore-a-ticket", 30}]
  end

  test "with the flag off, the organisation's owner changes the limit", %{
    conn: conn,
    operated: operated
  } do
    Flags.put_operator_infrastructure(false)
    {:ok, view, _html} = live(log_in_user(conn, operated.owner.user), path(operated))

    refute has_element?(view, "#stage-entry-0-time-limit-note")
    refute has_element?(view, ~s{#{@field}[disabled]})

    view
    |> element("#stage-entry-0-time-limit-form")
    |> render_submit(%{"time_limit" => %{"minutes" => "30"}})

    assert limits(operated.owner.scope) == [{"explore-a-ticket", 30}]
  end
end
