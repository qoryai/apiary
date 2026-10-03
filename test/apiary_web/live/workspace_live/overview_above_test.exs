defmodule ApiaryWeb.WorkspaceLive.OverviewAboveTest do
  @moduledoc """
  Needs attention under a level above the workspace's policy (`Apiary.Policy.Above`), with
  the edition's answer faked: a denied destination only that level could allow, or one its
  own deny holds, offers no allow of the workspace, which would not be in force.
  """
  # Not async: the faked answer is in the application environment, which is global.
  use ApiaryWeb.ConnCase, async: false

  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Above, Rule}

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)
    :ok
  end

  defp rule(action, host) do
    %Rule{
      id: Ecto.UUID.generate(),
      kind: "host",
      action: action,
      host: host,
      locked: false,
      inserted_at: ~U[2026-09-12 10:00:00.000000Z]
    }
  end

  defp above!(rules, opts) do
    above = %Above{
      id: Ecto.UUID.generate(),
      name: "Eight Wonders",
      slug: "8wonders",
      rules: rules,
      floor: false,
      own_allows: Keyword.get(opts, :own_allows, true)
    }

    Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    render_async(view, 5_000)
    view
  end

  defp item(view, host) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#attention-list li[data-kind=denied]")
    |> Enum.find(&(LazyHTML.text(&1) =~ host))
    |> LazyHTML.attribute("id")
    |> hd()
  end

  test "a level that allows only its own hosts: a lock and its reason, never an allow here",
       %{conn: conn, scope: scope} do
    above!([rule("allow", "*.wonders.example")], own_allows: false)

    started_run(scope, shop(),
      egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
    )

    view = open(conn, scope)
    item = item(view, "flags.example")

    # The count stays the reason; the lock says who decides, and nothing opens a popover.
    assert has_element?(view, "##{item} .q-ar-why", "Denied once in 1 run")

    assert has_element?(
             view,
             "##{item} .q-ar-why[title=\"Only Eight Wonders's policy allows a host here\"]"
           )

    assert has_element?(
             view,
             "span##{item}-act.q-act-lock",
             "Only Eight Wonders's policy allows a host here"
           )

    refute has_element?(view, "button##{item}-act")

    # An event that asks anyway is ignored: no popover, no rule, no success.
    render_hook(view, "rule_open", %{"id" => item, "level" => "workspace"})
    refute has_element?(view, "#rule-popover")
    refute has_element?(view, "##{item}-done")
    assert Policy.list_rules(scope, nil) == []
  end

  test "a deny of the level above: its words and a lock, not an allow",
       %{conn: conn, scope: scope} do
    above!([rule("deny", "paste.example")], own_allows: true)

    started_run(scope, shop(),
      egress: [%{"host" => "paste.example", "decision" => "denied", "rule" => "paste.example"}]
    )

    view = open(conn, scope)
    item = item(view, "paste.example")

    assert has_element?(view, "##{item} .q-ar-why", "Denied by Eight Wonders's policy")
    assert has_element?(view, "##{item} .q-amk", "Decided by Eight Wonders's policy")
    assert has_element?(view, "span##{item}-act.q-act-lock")
    refute has_element?(view, "button##{item}-act")
  end

  test "a level that lets the workspace allow keeps the Allow", %{conn: conn, scope: scope} do
    above!([rule("allow", "*.wonders.example")], own_allows: true)

    started_run(scope, shop(),
      egress: [%{"host" => "flags.example", "decision" => "denied", "rule" => ""}]
    )

    view = open(conn, scope)
    item = item(view, "flags.example")
    assert has_element?(view, "button##{item}-act", "Allow")
  end
end
