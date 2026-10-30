defmodule ApiaryWeb.PolicyLive.RequiredHostsTest do
  # "Allowed for every run" on the Policy page: the hosts Qory Apiary allows for every run
  # of the workspace (`Apiary.Policy.RequiredHosts`), read only, each locked, apart from
  # the workspace's rules. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]

  alias Apiary.{Connections, Organisations, Repo}

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/policy"))
    render_async(view, 5_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace("&#39;", "'")
    |> String.trim()
  end

  defp integration!(scope, name, hosts, attrs \\ %{}) do
    release =
      ready_release!(
        scope,
        tracker_description(%{
          "name" => name,
          "egress_hosts" => hosts,
          "roles" => %{"credential" => %{"argument" => "[A-Z]+", "hosts" => hosts}}
        }),
        "codeberg.org/acme/#{name}"
      )

    {:ok, _connection} = Connections.create_integration(scope, release.id, attrs)
  end

  describe "the integrations" do
    @describetag needs: :secrets

    test "are listed with their source and who chose them, locked, and not among the rules",
         %{conn: conn, scope: scope} do
      integration!(scope, "tracker", ["api.tracker.example"])

      integration!(scope, "chat", ["hooks.chat.example"], %{
        applies_to: "selected",
        workspace_ids: [scope.workspace.id]
      })

      view = open(conn, scope)

      assert has_element?(view, "#required-hosts-h", "Allowed for every run")

      assert has_element?(
               view,
               "#required-hosts-line",
               "Qory Apiary allows these hosts for every run. Host rules do not remove them."
             )

      list = text(view, "#required-hosts-integrations")
      assert list =~ "Integrations"
      assert list =~ "api.tracker.example The integration tracker The organisation's choice"
      assert list =~ "hooks.chat.example The integration chat This workspace's choice"

      assert has_element?(
               view,
               "#required-hosts-integrations [aria-label='Host rules do not remove this host.']"
             )

      refute has_element?(view, "#required-hosts button")
      refute has_element?(view, "#required-hosts a")
      refute has_element?(view, "#policy-rules", "api.tracker.example")
    end

    test "shows an IP address to an instance admin alone", %{conn: conn, scope: scope} do
      integration!(scope, "tracker", ["203.0.113.7"])

      view = open(conn, scope)
      refute render(view) =~ "203.0.113.7"
      assert has_element?(view, "#required-hosts-integrations", "Address hidden")

      {:ok, _grant} = Organisations.grant_instance_admin(scope.user)
      assert has_element?(open(conn, scope), "#required-hosts-integrations", "203.0.113.7")
    end
  end

  describe "the harness sources" do
    @describetag needs: :factory

    test "are the Qory harness, required by the instance", %{conn: conn, scope: scope} do
      view = open(conn, scope)

      assert text(view, "#required-hosts-harness") =~
               "Harness sources github.com The Qory harness The instance"
    end

    defp harness_document(git), do: "extends:\n  git: \"#{git}\"\n  ref: \"main\"\n"

    test "name who chose the harness: the workspace, the organisation, or a target's choice",
         %{conn: conn, scope: scope} do
      git = "https://code.example/acme/harness"

      {:ok, _} =
        Apiary.Stacks.put_stack(scope, {:workspace, scope.workspace}, harness_document(git),
          choice: :repository
        )

      assert text(open(conn, scope), "#required-hosts-harness") =~
               "code.example The harness source acme/harness This workspace's choice"

      Repo.delete_all(Apiary.Stacks.Stack)

      {:ok, _} =
        Apiary.Stacks.put_stack(
          scope,
          {:organisation, scope.organisation},
          harness_document("https://code.example/acme/shared"),
          choice: :repository
        )

      assert text(open(conn, scope), "#required-hosts-harness") =~
               "code.example The harness source acme/shared The organisation's choice"

      Repo.delete_all(Apiary.Stacks.Stack)

      :ok =
        Apiary.Runs.Target.insert_new(scope.organisation.id, scope.workspace.id, [
          %{system: "forge.example.com", path: "acme/shop"}
        ])

      target = Apiary.Runs.fetch_target(scope, "forge.example.com", "acme/shop")

      {:ok, _} =
        Apiary.Stacks.put_stack(
          scope,
          {:target, target},
          harness_document("https://tools.example/acme/target-harness"),
          choice: :repository
        )

      view = open(conn, scope)

      assert text(view, "#required-hosts-harness") =~
               "github.com The Qory harness The instance"

      assert text(view, "#required-hosts-harness") =~
               "tools.example The harness source acme/target-harness This workspace's choice"
    end

    test "end with the line of what a run adds, for a workspace whose work item needs a target",
         %{conn: conn, scope: scope} do
      assert text(open(conn, scope), "#required-hosts-run") ==
               "A run also reaches the hosts of its repository's forge, of the harness sources its repository adds, and of the model provider it uses."
    end
  end
end
