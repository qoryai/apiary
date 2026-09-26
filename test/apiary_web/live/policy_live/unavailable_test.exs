defmodule ApiaryWeb.PolicyLive.UnavailableTest do
  @moduledoc """
  What the record says about the rules is read within a bound; past it the answer is
  `:unavailable`, and the pages leave the fact line and the "Last 7 days" column out
  rather than show a count of a part. The cap is set to nothing here, so one connection
  is past it; that is a global setting, hence no `async`.
  """
  use ApiaryWeb.ConnCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user

  setup %{scope: scope} do
    was = Application.get_env(:apiary, Apiary.Policy.Activity)
    Application.put_env(:apiary, Apiary.Policy.Activity, cap: 0)
    on_exit(fn -> restore(was) end)

    {:ok, _} = Policy.allow(scope, nil, %{host: "registry.example"})

    started_run(scope, shop(),
      egress: [%{"host" => "registry.example", "rule" => "registry.example"}]
    )

    [%{target: target}] = Policy.list_targets(scope)
    %{target: target}
  end

  defp restore(nil), do: Application.delete_env(:apiary, Apiary.Policy.Activity)
  defp restore(was), do: Application.put_env(:apiary, Apiary.Policy.Activity, was)

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  test "the count is unavailable, so the fact line and the column are left out",
       %{conn: conn, scope: scope, target: target} do
    assert Policy.rule_activity(scope, nil, DateTime.add(DateTime.utc_now(), -7, :day)) ==
             :unavailable

    view = open(conn, "/hive/policy")
    assert has_element?(view, "#policy-rules .q-host", "registry.example")
    refute has_element?(view, "#policy-rules th", "Last 7 days")
    refute has_element?(view, "#policy-mode-fact")
    refute has_element?(view, "#policy-rules td.q-c-seen")
    refute view |> element("#policy-rules") |> render() =~ "not seen"

    view = open(conn, "/hive/policy/targets/#{target.id}")
    assert has_element?(view, "#policy-rules .q-host", "registry.example")
    refute has_element?(view, "#policy-rules th", "Last 7 days")

    # The enforce confirm has no list to show, and says nothing in its place.
    view = open(conn, "/hive/policy")
    view |> element("#policy-mode-enforce") |> render_click()
    assert has_element?(view, "#mode-enforce")
    refute has_element?(view, "#mode-would")
    refute has_element?(view, "#mode-would-none")
  end
end
