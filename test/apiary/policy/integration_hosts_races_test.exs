defmodule Apiary.Policy.IntegrationHostsRacesTest do
  # A write to an integration against a save of a rule of a workspace it reaches, racing.
  # Each side runs on a separate database connection, outside the SQL sandbox, so each
  # commits and each waits on the other's locks as it would in production. Not async: what these
  # tests commit is visible to every other test while they run, and they delete it again
  # before they end.
  #
  # The rule under test (docs/access.md, The lock order): the integration's write takes
  # the integrations lock, then every workspace of the organisation, then renders the
  # workspaces it reaches; a rule's save takes its workspace. Whichever comes second waits
  # for the first, and its render, or its check of a deny, has what the first wrote.
  use ExUnit.Case, async: false

  import Apiary.DescriptionFixtures
  import Apiary.Races

  alias Apiary.{Connections, Policy}
  alias Apiary.Connections.Connection
  alias Apiary.Policy.RunConfiguration

  @moduletag needs: :secrets

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

    release =
      Apiary.ConnectionsFixtures.ready_release!(
        scope,
        tracker_description(%{"egress_hosts" => ["api.example.com"]}),
        "codeberg.org/acme/tracker"
      )

    %{scope: scope, release: release}
  end

  defp served(scope) do
    {:ok, %RunConfiguration{document: document}} = Policy.current_configuration(scope, nil)
    Jason.decode!(document)["security_policy"]["egress"]
  end

  test "an integration's write first: the rule's save waits, and its render has the host",
       %{scope: scope, release: release} do
    {first, first_pid} = hold(fn -> Connections.create_integration(scope, release.id, %{}) end)
    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Policy.deny(scope, nil, %{host: "*.example.com"}) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, _rule} = Task.await(second.task)
    assert served(scope)["allow_first"] == ["api.example.com"]
    assert served(scope)["deny"] == ["*.example.com"]
  end

  test "an integration's write first: a deny of its host waits, and is refused",
       %{scope: scope, release: release} do
    {first, first_pid} = hold(fn -> Connections.create_integration(scope, release.id, %{}) end)
    assert {:ok, %Connection{}} = first.result

    second = start(fn -> Policy.deny(scope, nil, %{host: "api.example.com"}) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, %Policy.Error{reason: :integration_host, details: %{host: "api.example.com"}}} =
             Task.await(second.task)

    assert served(scope)["allow_first"] == ["api.example.com"]
    assert scope |> Policy.list_rules(nil) |> Enum.map(& &1.host) == ["docs.example.com"]
  end

  test "a rule's save first: the integration's write waits, and its render has the rule",
       %{scope: scope, release: release} do
    {first, first_pid} = hold(fn -> Policy.deny(scope, nil, %{host: "*.example.com"}) end)
    assert {:ok, _rule} = first.result

    second = start(fn -> Connections.create_integration(scope, release.id, %{}) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, %Connection{}} = Task.await(second.task)
    assert served(scope)["allow_first"] == ["api.example.com"]
    assert served(scope)["deny"] == ["*.example.com"]

    assert scope |> Policy.list_rules(nil) |> Enum.map(& &1.host) |> Enum.sort() ==
             ["*.example.com", "docs.example.com"]
  end
end
