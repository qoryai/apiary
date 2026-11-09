defmodule ApiaryWeb.RequiredHostRowsTest do
  @moduledoc """
  The hosts enforce does not deny, on the two pages that read recorded connections: the
  mode card does not count them, and a row of Network access has a lock in place of Deny.
  """
  use ApiaryWeb.ConnCase, async: false

  @moduletag needs: [:security, :secrets]

  import Phoenix.LiveViewTest
  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.RunListFixtures

  alias Apiary.{Connections, ModelChoices, Policy}
  alias ApiaryWeb.RunComponents

  setup :register_and_log_in_user

  @runtime_host "api.anthropic.com"
  @integration_host "api.tracker.example"
  @provider_host "api.deepseek.com"
  @no_rule_host "cdn.example"

  setup %{scope: scope} do
    release =
      ready_release!(
        scope,
        tracker_description(%{
          "name" => "tracker",
          "egress_hosts" => [@integration_host],
          "roles" => %{"credential" => %{"argument" => "[A-Z]+", "hosts" => [@integration_host]}}
        }),
        "codeberg.org/northwind/tracker"
      )

    {:ok, _integration} = Connections.create_integration(scope, release.id, %{})

    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "deepseek",
        keys: [%{value_id: "main", value: "sk-example-model-key-0123456789"}]
      })

    {:ok, _choice} = ModelChoices.put_choice(scope, :workspace, %{provider: provider.public_id})
    :ok
  end

  defp allowed(host, extra \\ %{}),
    do: Map.merge(%{"host" => host, "decision" => "allowed", "rule" => ""}, extra)

  defp open_page(conn, scope, rest) do
    {:ok, view, _html} = live(conn, workspace_path(scope, rest))
    render_async(view, 2_000)
    view
  end

  defp row_id(host, path \\ ""),
    do: RunComponents.destination_id(%{host: host, port: 443, path: path})

  describe "the mode card" do
    test "counts only the host with no rule", %{conn: conn, scope: scope} do
      # The first change: until then the card has no count.
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      started_run(scope, %{},
        egress:
          Enum.map(1..3, fn _ -> allowed(@no_rule_host) end) ++
            [allowed(@runtime_host), allowed(@integration_host), allowed(@provider_host)]
      )

      text = conn |> open_page(scope, "/policy") |> render() |> String.replace(~r/<[^>]+>/, "")

      assert String.replace(text, ~r/\s+/, " ") =~
               "In the last 14 days 3 attempts to 1 destination had no rule."
    end
  end

  describe "a row of Network access" do
    setup %{conn: conn, scope: scope} do
      started_run(scope, %{},
        egress: [
          allowed(@runtime_host),
          allowed(@integration_host),
          allowed(@provider_host),
          allowed(@no_rule_host)
        ]
      )

      %{view: open_page(conn, scope, "/network")}
    end

    test "of a required host has the lock and its hint, above it, and no Allow or Deny", %{
      view: view
    } do
      for host <- [@runtime_host, @integration_host, @provider_host] do
        id = row_id(host)

        assert has_element?(
                 view,
                 ~s(##{id}-lock.tooltip-top.q-tip-inset[data-tip="Allowed for every run"])
               )

        refute has_element?(view, "##{id}-deny")
        refute has_element?(view, "##{id}-allow")
      end
    end

    test "of a host with no rule keeps Allow and Deny", %{view: view} do
      id = row_id(@no_rule_host)

      assert has_element?(view, "##{id}-allow")
      assert has_element?(view, "##{id}-deny")
      refute has_element?(view, "##{id}-lock")
    end

    test "of a required host opens no panel for a crafted event", %{view: view} do
      render_click(view, "rule_open", %{
        "host" => @runtime_host,
        "port" => "443",
        "path" => "",
        "action" => "deny"
      })

      refute has_element?(view, "#rule-panel")
    end
  end

  test "a path a rule holds on an integration's host keeps Allow, with no lock", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _rule} = Policy.allow(scope, nil, %{host: @integration_host, paths: ["/rest/*"]})
    started_run(scope, %{}, egress: [allowed(@integration_host, %{"path" => "/admin"})])

    view = open_page(conn, scope, "/network")
    id = row_id(@integration_host, "/admin")

    assert has_element?(view, "##{id}-allow")
    refute has_element?(view, "##{id}-lock")
  end

  # Held to paths on one target and not on the other: enforce lets the request through for
  # the first target's runs only, so the destination is not one every run is allowed.
  test "an Overview item of a host required for one target's runs only keeps its Allow", %{
    conn: conn,
    scope: scope
  } do
    # The Overview shows its lists once the workspace's set-up is finished.
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

    denied = %{
      "host" => @integration_host,
      "path" => "/admin",
      "decision" => "denied",
      "rule" => ""
    }

    started_run(scope, %{"forge" => "github.example", "repository" => "acme/shop"},
      egress: [denied]
    )

    run =
      started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"},
        egress: [denied]
      )

    target = Apiary.Repo.get!(Apiary.Runs.Target, run.target_id)
    {:ok, _rule} = Policy.allow(scope, target, %{host: @integration_host, paths: ["/rest/*"]})

    view = open_page(conn, scope, "")

    [item] =
      render(view)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#attention-list li[data-kind=denied]")
      |> LazyHTML.attribute("id")

    assert has_element?(view, "button##{item}-act", "Allow")
    refute has_element?(view, "##{item}-act.q-act-lock")
  end
end
