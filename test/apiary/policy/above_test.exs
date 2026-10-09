defmodule Apiary.Policy.AboveTest do
  @moduledoc """
  What `Apiary.Policy` makes of a level above the workspace's policy, with the edition's
  answer faked through `Apiary.Policy.Above.for_workspace/1`'s configuration.
  """
  # Not async: the faked answer is in the application environment, which is global.
  use Apiary.DataCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Above, Change, Error, Render, Resolution, Rule}
  alias Apiary.Runs.Target
  alias Apiary.Variables
  alias Apiary.Variables.Variable

  setup do
    %{scope: scope} = sign_up_fixture()
    on_exit(fn -> Application.delete_env(:apiary, Apiary.Policy.Above) end)
    %{scope: scope}
  end

  defp rule(action, host, opts \\ []) do
    %Rule{
      id: Ecto.UUID.generate(),
      kind: "host",
      action: action,
      host: host,
      paths: opts[:paths],
      locked: false
    }
  end

  # The level above every workspace, as an edition would answer it.
  defp above!(rules, opts \\ []) do
    above = %Above{
      id: Ecto.UUID.generate(),
      name: "Eight Wonders",
      slug: "8wonders",
      rules: rules,
      floor: Keyword.get(opts, :floor, false),
      own_allows: Keyword.get(opts, :own_allows, true)
    }

    Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)
    above
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

  defp egress!(scope, holder) do
    {:ok, configuration} = Policy.current_configuration(scope, holder)
    Jason.decode!(configuration.document)["security_policy"]["egress"]
  end

  test "the core edition keeps no level above a workspace", %{scope: scope} do
    assert Apiary.Edition.Core.above_workspace(scope.workspace) == nil
    assert Above.for_workspace(scope.workspace) == nil
    assert Policy.effective(scope, nil).above == nil
  end

  test "the effective policy carries the level, and a write renders its hosts", %{scope: scope} do
    above =
      above!([rule("deny", "paste.example"), rule("allow", "api.example", paths: ["/v1/*"])])

    target = target_fixture(scope)

    assert %{above: ^above} = Policy.effective(scope, nil)
    assert %{above: ^above} = Policy.effective(scope, target)

    {:ok, _} = Policy.allow(scope, nil, %{host: "paste.example"})
    {:ok, _} = Policy.allow(scope, target, %{host: "cdn.example"})

    assert egress!(scope, nil) == %{
             "mode" => "observe",
             "allow" => ["api.example"],
             "deny" => ["paste.example"],
             "paths" => %{"api.example" => ["/v1/*"]}
           }

    assert egress!(scope, target)["allow"] == ["api.example", "cdn.example"]
    assert egress!(scope, target)["deny"] == ["paste.example"]

    entries = Policy.effective(scope, nil).entries

    assert %{source: :organisation, in_force: true} =
             Enum.find(entries, &(&1.host == "api.example"))

    assert %{source: :workspace, in_force: false, overridden_by: %{source: :organisation}} =
             Enum.find(entries, &(&1.host == "paste.example" and &1.source == :workspace))

    # The export reads the same effective policy.
    assert {:ok, %{forager_file: forager_file}} = Policy.export(scope, nil)
    assert forager_file =~ "paste.example"
  end

  test "the switch off strikes the workspace's allows, and the document says only the level's",
       %{scope: scope} do
    {:ok, _} = Policy.allow(scope, nil, %{host: "cdn.example"})
    {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example"})
    above!([rule("allow", "api.example")], own_allows: false)

    assert %{in_force: false, reason: :only_above_allows} =
             Enum.find(Policy.effective(scope, nil).entries, &(&1.host == "cdn.example"))

    {:ok, _} = Policy.allow(scope, nil, %{host: "mcp.example"})
    assert egress!(scope, nil)["allow"] == ["api.example"]
    assert egress!(scope, nil)["deny"] == ["ads.example"]
  end

  describe "the floor" do
    test "fixes the mode in force, and refuses to set it", %{scope: scope} do
      target = target_fixture(scope)
      {:ok, _} = Policy.set_mode(scope, target, "observe")
      above = above!([], floor: true)

      assert %{mode: "enforce", mode_source: :organisation} = Policy.effective(scope, nil)
      assert %{mode: "enforce", mode_source: :organisation} = Policy.effective(scope, target)
      assert Policy.get_mode(scope) == "observe"

      assert Policy.get_mode(scope, target) == %{
               mode: "enforce",
               own: "observe",
               workspace: "observe",
               floor: true
             }

      assert %{floor: true, mode: "observe"} = Policy.mode_summary(scope)

      assert {:error, %Error{reason: :fixed, field: :mode, message: message}} =
               Policy.set_mode(scope, "enforce")

      assert message == "Enforce is required by #{above.name}: the mode is not set here."

      assert {:error, %Error{reason: :fixed}} = Policy.set_mode(scope, "observe")
      assert {:error, %Error{reason: :fixed}} = Policy.set_mode(scope, target, "enforce")
      assert {:error, %Error{reason: :fixed}} = Policy.set_mode(scope, target, :inherit)
      assert Policy.get_mode(scope) == "observe"
    end

    test "renders enforce into every document", %{scope: scope} do
      above!([], floor: true)
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      assert egress!(scope, nil)["mode"] == "enforce"
    end

    test "requested changes: observe is refused with the floor's sentence, enforce is what holds",
         %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      above!([], floor: true)
      {:ok, observe} = Policy.requested_changes(%{"mode" => "observe"})

      {:ok, enforce} =
        Policy.requested_changes(%{
          "mode" => "enforce",
          "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "cdn.example"}]
        })

      assert {:error, %Error{reason: :fixed, message: message}} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.apply_requested(scope, [workspace], observe)
               end)

      assert message =~ "Eight Wonders"
      assert message =~ "In #{scope.workspace.name}:"

      assert {:ok, [%Change{action: "rule_added"}]} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.apply_requested(scope, [workspace], enforce)
               end)

      assert Policy.get_mode(scope) == "observe"
      assert egress!(scope, nil)["mode"] == "enforce"
    end
  end

  describe "a host the level decides" do
    test "has no paths changed in the workspace or in a target", %{scope: scope} do
      above!([rule("allow", "git.example", paths: ["/a"])])
      target = target_fixture(scope)

      assert {:error, %Error{reason: :locked, message: message}} =
               Policy.allow_path(scope, nil, "git.example", "/b")

      assert message =~ "Eight Wonders's rule for git.example decides it here"

      assert {:error, %Error{reason: :locked}} =
               Policy.deny_path(scope, target, "git.example", "/a")

      # A host of its own is still the workspace's to hold to paths.
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/a"]})

      assert {:ok, %Rule{paths: ["/a", "/b"]}} =
               Policy.allow_path(scope, nil, "api.example", "/b")
    end

    test "is counted as decided by it, and a deny of it is marked on a denied destination",
         %{scope: scope} do
      above!([rule("deny", "ads.example"), rule("allow", "api.example")])
      target = target_fixture(scope)

      run =
        started_run(scope, %{"forge" => "github.example", "repository" => "acme/site"},
          egress: [
            %{"host" => "api.example", "decision" => "allowed"},
            %{"host" => "ads.example", "decision" => "denied"},
            %{"host" => "new.example", "decision" => "allowed"}
          ]
        )

      assert run.target_id == target.id
      since = DateTime.add(DateTime.utc_now(), -1, :day)

      assert {:ok, [%{host: "ads.example", above: "ads.example", locked: nil}]} =
               Policy.denied_destinations(scope, since)

      assert {:ok, [%{host: "new.example"}]} = Policy.uncovered(scope, since)

      assert {:ok, counts} = Policy.rule_activity(scope, nil, since)
      [deny, allow] = Enum.map(Above.for_workspace(scope.workspace).rules, & &1.id)
      assert counts[deny] == %{allowed: 0, denied: 1}
      assert counts[allow] == %{allowed: 1, denied: 0}

      # Under the floor nothing would start being denied: enforce holds already.
      above!([rule("deny", "ads.example"), rule("allow", "api.example")], floor: true)
      assert {:ok, []} = Policy.uncovered(scope, since)
    end

    test "is left out of the suggestions, and a covered host names the level", %{scope: scope} do
      above!([rule("deny", "ads.example"), rule("allow", "*.api.example")])
      run = started_run(scope, %{"forge" => "github.example", "repository" => "acme/site"})
      target = Repo.get!(Target, run.target_id)

      event_fixture(run, 10, "run.policy_applied", %{
        "harness_hosts" => ["ads.example", "a.api.example", "new.example"]
      })

      assert %{hosts: 1, targets: 1} = Policy.suggestion_counts(scope)

      assert %{
               suggested: [%{host: "new.example"}],
               covered: [%{host: "a.api.example", by: "*.api.example", source: :organisation}]
             } = Policy.declared_hosts(scope, target)
    end
  end

  describe "rerender_in/3" do
    test "renders an unmanaged workspace with all: true, as the level's change, and announces it",
         %{scope: scope} do
      above!([rule("deny", "paste.example")])
      target = target_fixture(scope)
      Repo.update_all(from(p in Target, where: p.id == ^target.id), set: [egress_mode: "enforce"])
      refute Policy.managed?(scope)
      cause = Ecto.UUID.generate()
      Policy.subscribe(scope)

      # Not rendered without `all`: the workspace is nobody's yet.
      assert {:ok, []} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.rerender_in(workspace, scope, action: "above_changed", cause: cause)
               end)

      refute Policy.managed?(scope)

      assert {:ok, [baseline, own] = changes} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])

                 Policy.rerender_in(workspace, scope,
                   action: "above_changed",
                   cause: cause,
                   all: true
                 )
               end)

      assert %Change{action: "above_changed", target_id: nil, version_after: 1, cause: ^cause} =
               baseline

      assert baseline.changed_by_id == scope.user.id
      assert baseline.before == baseline.after
      assert %Change{action: "above_changed", version_after: 1} = own
      assert own.target_id == target.id
      assert Policy.managed?(scope)

      assert egress!(scope, nil) == %{
               "mode" => "observe",
               "allow" => [],
               "deny" => ["paste.example"]
             }

      assert egress!(scope, target)["mode"] == "enforce"

      # The history holds it, with its cause, and the pages hear of it once announced.
      assert [%Change{action: "above_changed", cause: ^cause, version_after: 1}] =
               Policy.list_changes(scope, nil).items

      refute_received {:policy_changed, _}
      :ok = Policy.announce(changes)
      workspace_id = scope.workspace.id

      assert_receive {:policy_changed,
                      %{workspace_id: ^workspace_id, target_id: nil, action: "above_changed"}}

      # The same bytes again write nothing.
      assert {:ok, []} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.rerender_in(workspace, scope, action: "above_changed", all: true)
               end)

      assert {:ok, %{version: 1}} = Policy.current_configuration(scope, nil)
    end

    test "a render the resolution refuses rolls back, naming the holder", %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.example", paths: ["/a"]})
      above!([rule("allow", "git.example")])

      assert {:error, %Error{reason: :conflict, message: message}} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.rerender_in(workspace, scope, action: "above_changed")
               end)

      assert message =~ "Eight Wonders's policy"
      assert {:ok, %{version: 1}} = Policy.current_configuration(scope, nil)
    end
  end

  describe "a level that carries variables only" do
    # What an edition answers for a level with variables and no policy of its own.
    defp variables_only!(opts \\ []) do
      above = %Above{
        id: Ecto.UUID.generate(),
        name: "Eight Wonders",
        slug: "8wonders",
        policy: false,
        variables: [
          %Variable{name: "REGION", value: "eu-west-1", locked: true},
          %Variable{name: "LOG_LEVEL", value: "info"}
        ]
      }

      above = struct!(above, opts)
      Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)
      above
    end

    # Everything the policy says of the workspace and of `target`, to compare with and
    # without the level.
    defp policy_reads(scope, target) do
      {:ok, baseline} = Policy.current_configuration(scope, nil)
      {:ok, own} = Policy.current_configuration(scope, target)
      {:ok, export} = Policy.export(scope, nil)
      {:ok, target_export} = Policy.export(scope, target)

      %{
        effective: Policy.effective(scope, nil),
        target_effective: Policy.effective(scope, target),
        mode: Policy.get_mode(scope, target),
        summary: Policy.mode_summary(scope),
        digests: {baseline.digest, own.digest},
        documents: {baseline.document, own.document},
        exports: {export, target_export}
      }
    end

    test "is a level, and the policy's unless it says otherwise" do
      assert %Above{}.policy
      above = %Above{name: "Eight Wonders", rules: [rule("deny", "paste.example")]}
      assert Above.for_policy(above) == above
      assert Above.for_policy(%Above{name: "Eight Wonders", policy: false}) == nil
      assert Above.for_policy(nil) == nil
    end

    test "leaves the effective policy, the resolution, the render and the export as with none",
         %{scope: scope} do
      target = target_fixture(scope)
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example", paths: ["/v1/*"]})
      {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example", locked: true})
      {:ok, _} = Policy.allow(scope, target, %{host: "cdn.example"})
      {:ok, _} = Policy.set_mode(scope, target, "enforce")

      none = policy_reads(scope, target)
      variables_only!()

      assert policy_reads(scope, target) == none
      assert Policy.effective(scope, nil).above == nil
      refute Policy.get_mode(scope, target).floor

      # The mode is the workspace's to set: nothing requires enforce.
      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
    end

    test "resolves as nil, whatever rules it holds when handed to the resolution itself" do
      rules = [rule("allow", "api.example"), rule("allow", "cdn.example")]

      above = %Above{
        name: "Eight Wonders",
        policy: false,
        rules: [rule("deny", "api.example")],
        floor: true,
        own_allows: false
      }

      assert {:ok, none} = Resolution.resolve_for("observe", nil, rules, [], nil, nil)
      assert {:ok, ^none} = Resolution.resolve_for("observe", nil, rules, [], nil, above)
      assert {:ok, ^none} = Resolution.resolve("observe", rules, [], nil, nil)
      assert {:ok, ^none} = Resolution.resolve("observe", rules, [], nil, above)
      assert none.above == nil
      assert none.mode_source == :workspace
      assert Render.document(none) =~ "cdn.example"
    end

    test "decides no connection in the record and leaves the history alone", %{scope: scope} do
      {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example"})
      target = target_fixture(scope)

      started_run(scope, %{"forge" => "github.example", "repository" => "acme/site"},
        egress: [
          %{"host" => "api.example", "decision" => "allowed"},
          %{"host" => "ads.example", "decision" => "denied"}
        ]
      )

      since = DateTime.add(DateTime.utc_now(), -1, :day)

      record = fn ->
        {Policy.denied_destinations(scope, since), Policy.uncovered(scope, since),
         Policy.rule_activity(scope, nil, since), Policy.suggestion_counts(scope),
         Policy.declared_hosts(scope, target)}
      end

      none = record.()
      variables_only!()
      assert record.() == none

      assert {:ok, [%{host: "ads.example", above: nil}]} =
               Policy.denied_destinations(scope, since)

      # A render again under it gives the same bytes: no version, no change of the level.
      assert {:ok, []} =
               Repo.transact(fn ->
                 {:ok, [workspace]} = Policy.lock_workspaces(scope, [scope.workspace.id])
                 Policy.rerender_in(workspace, scope, action: "above_changed", all: true)
               end)

      refute Enum.any?(Policy.list_changes(scope, nil).items, &(&1.action == "above_changed"))
    end

    test "is still the top of the variables' chain", %{scope: scope} do
      variables_only!()

      assert {:ok, resolution} = Variables.resolve(scope, :workspace)

      assert Variables.Resolution.values(resolution) == %{
               "REGION" => "eu-west-1",
               "LOG_LEVEL" => "info"
             }

      assert %{set_by: :above, locked_by: :above} =
               Variables.Resolution.entry(resolution, "REGION")

      assert {:error, changeset} =
               Variables.create_variable(scope, :workspace, %{name: "REGION", value: "x"})

      assert {"is locked above, so it cannot be set here", _} = changeset.errors[:name]
    end

    test "with rules, a floor or the switch off, is an edition's mistake said at once",
         %{scope: scope} do
      for opts <- [[rules: [rule("deny", "ads.example")]], [floor: true], [own_allows: false]] do
        variables_only!(opts)

        assert_raise ArgumentError, ~r/policy: false carries variables only/, fn ->
          Policy.effective(scope, nil)
        end
      end
    end
  end

  test "a level with a policy and variables holds both", %{scope: scope} do
    above = %Above{
      id: Ecto.UUID.generate(),
      name: "Eight Wonders",
      slug: "8wonders",
      policy: true,
      rules: [rule("deny", "paste.example")],
      variables: [%Variable{name: "REGION", value: "eu-west-1"}]
    }

    Application.put_env(:apiary, Apiary.Policy.Above, answer: fn _workspace -> above end)

    assert %{above: ^above} = Policy.effective(scope, nil)
    assert {:ok, resolution} = Variables.resolve(scope, :workspace)
    assert Variables.Resolution.values(resolution) == %{"REGION" => "eu-west-1"}
  end
end
