defmodule Mix.Tasks.Apiary.Policy.RerenderTest do
  @moduledoc """
  `mix apiary.policy.rerender`: the versions in force rendered before the document had a
  deny list are rendered again, and only where the bytes change.
  """
  use Apiary.DataCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Change, Render, RunConfiguration}
  alias Apiary.Runs.Target
  alias Mix.Tasks.Apiary.Policy.Rerender

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    %{scope: scope_fixture()}
  end

  defp target_fixture(scope, path \\ "acme/site") do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      system: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp current!(scope, holder) do
    {:ok, configuration} = Policy.current_configuration(scope, holder)
    configuration
  end

  # The version in force as a release before the deny list rendered it: the same policy
  # without `deny`, under its own digest.
  defp age!(scope, holder) do
    effective = Policy.effective(scope, holder)
    document = Render.document(%{effective | deny: []})
    current = current!(scope, holder)

    Repo.update_all(from(c in RunConfiguration, where: c.id == ^current.id),
      set: [document: document, digest: Render.digest(document)]
    )

    refute Jason.decode!(document)["security_policy"]["egress"]["deny"]
    current.version
  end

  defp egress(configuration),
    do: Jason.decode!(configuration.document)["security_policy"]["egress"]

  defp changes(scope, holder) do
    Policy.list_changes(scope, holder).items
  end

  test "a managed hive with deny rules gets a new version per holder whose bytes change, and no more",
       %{scope: scope} do
    target = target_fixture(scope)
    {:ok, _} = Policy.allow(scope, nil, %{host: "*.example"})
    {:ok, _} = Policy.deny(scope, nil, %{host: "tracker.example"})
    {:ok, _} = Policy.allow(scope, target, %{host: "mcp.example"})
    {:ok, _} = Policy.deny(scope, target, %{host: "*.ads.example"})
    Policy.subscribe(scope)

    baseline = age!(scope, nil)
    own = age!(scope, target)
    changes_before = length(changes(scope, nil)) + length(changes(scope, target))

    Rerender.run([])
    assert_received {:mix_shell, :info, ["Rendered 1 hives again: 2 new versions."]}
    assert_received {:policy_changed, %{action: "rerendered"}}

    assert %{version: version} = configuration = current!(scope, nil)
    assert version == baseline + 1

    assert egress(configuration) == %{
             "mode" => "observe",
             "allow" => ["*.example"],
             "deny" => ["tracker.example"]
           }

    assert %{version: version} = configuration = current!(scope, target)
    assert version == own + 1
    assert egress(configuration)["deny"] == ["tracker.example", "*.ads.example"]

    # One change per holder, no change of the rules, and it names the version it made.
    assert [%Change{action: "rerendered", subject: nil, changed_by_id: nil} = change | _] =
             changes(scope, nil)

    assert change.before == change.after
    assert change.version_after == baseline + 1
    assert change.id == current!(scope, nil).policy_change_id
    assert [%Change{action: "rerendered"} | _] = changes(scope, target)

    # Run again: the bytes are current, nothing is written and nothing is announced.
    Rerender.run([])
    assert_received {:mix_shell, :info, ["Rendered 1 hives again: 0 new versions."]}
    refute_received {:policy_changed, _}
    assert current!(scope, nil).version == baseline + 1
    assert current!(scope, target).version == own + 1
    assert length(changes(scope, nil)) + length(changes(scope, target)) == changes_before + 2
  end

  test "a hive without deny rules renders the bytes it had, and an unmanaged hive is untouched",
       %{scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    version = current!(scope, nil).version
    %{scope: unmanaged} = sign_up_fixture()
    refute Policy.managed?(unmanaged)

    Rerender.run([])
    assert_received {:mix_shell, :info, ["Rendered 1 hives again: 0 new versions."]}

    assert current!(scope, nil).version == version
    assert Enum.map(changes(scope, nil), & &1.action) == ["rule_added"]
    refute Policy.managed?(unmanaged)
    assert {:error, _} = Policy.current_configuration(unmanaged, nil)

    assert Repo.aggregate(
             from(c in RunConfiguration, where: c.hive_id == ^unmanaged.hive.id),
             :count
           ) == 0
  end
end
