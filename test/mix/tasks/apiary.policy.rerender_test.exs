defmodule Mix.Tasks.Apiary.Policy.RerenderTest do
  @moduledoc """
  `mix apiary.policy.rerender`: the versions in force rendered before the document had a
  deny list are rendered again, and only where the bytes change.
  """
  use Apiary.DataCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog, only: [with_log: 1]

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
      workspace_id: scope.workspace.id,
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

  test "a managed workspace with deny rules gets a new version per holder whose bytes change, and no more",
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

    # The two: this workspace, and Main of the instance's organisation, which every test sees.
    Rerender.run([])

    assert_received {:mix_shell, :info,
                     ["Rendered 2 workspaces again: 2 new versions, 0 refused, 0 failed."]}

    assert_received {:policy_changed, %{action: "rerendered"}}

    assert %{version: version} = configuration = current!(scope, nil)
    assert version == baseline + 1

    assert egress(configuration) == %{
             "mode" => "observe",
             "allow" => ["*.example"],
             "allow_first" => ["api.anthropic.com"],
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
    assert change.id == current!(scope, nil).audit_entry_id
    assert [%Change{action: "rerendered"} | _] = changes(scope, target)

    # Run again: the bytes are current, nothing is written and nothing is announced.
    Rerender.run([])

    assert_received {:mix_shell, :info,
                     ["Rendered 2 workspaces again: 0 new versions, 0 refused, 0 failed."]}

    refute_received {:policy_changed, _}
    assert current!(scope, nil).version == baseline + 1
    assert current!(scope, target).version == own + 1
    assert length(changes(scope, nil)) + length(changes(scope, target)) == changes_before + 2
  end

  test "a workspace without deny rules renders the bytes it had, and one with no row is untouched",
       %{scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    version = current!(scope, nil).version
    %{scope: unmanaged} = sign_up_fixture()
    no_policy_version!(unmanaged.workspace)
    refute Policy.managed?(unmanaged)

    Rerender.run([])

    assert_received {:mix_shell, :info,
                     ["Rendered 2 workspaces again: 0 new versions, 0 refused, 0 failed."]}

    assert current!(scope, nil).version == version
    assert Enum.map(changes(scope, nil), & &1.action) == ["rule_added", "first_version"]
    refute Policy.managed?(unmanaged)
    assert {:error, _} = Policy.current_configuration(unmanaged, nil)

    assert Repo.aggregate(
             from(c in RunConfiguration, where: c.workspace_id == ^unmanaged.workspace.id),
             :count
           ) == 0
  end

  test "a workspace whose render raises is counted as failed, and the task exits with 1",
       %{scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    raising = scope.workspace.id
    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)

    Application.put_env(:apiary, Apiary.Policy.Above,
      answer: fn workspace -> if workspace.id == raising, do: raise("no level above") end
    )

    {exit, log} = with_log(fn -> catch_exit(Rerender.run([])) end)
    assert exit == {:shutdown, 1}

    assert_received {:mix_shell, :info,
                     ["Rendered 1 workspace again: 0 new versions, 0 refused, 1 failed."]}

    assert log =~ "policy rerender failed workspace=#{raising}: no level above"
  end

  test "says one workspace and one new version in the singular", %{scope: scope} do
    {:ok, _} = Policy.deny(scope, nil, %{host: "tracker.example"})
    age!(scope, nil)

    Rerender.run([])

    assert_received {:mix_shell, :info,
                     ["Rendered 2 workspaces again: 1 new version, 0 refused, 0 failed."]}
  end
end
