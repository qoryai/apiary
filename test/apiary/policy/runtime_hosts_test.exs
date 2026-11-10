defmodule Apiary.Policy.RuntimeHostsTest do
  @moduledoc """
  The hosts a runtime needs (`egress_hosts` of the contract's `runtimes.json`), in the
  documents of every workspace: in `egress.allow_first` of each version, on every path,
  with no rule able to remove or limit them at any route that writes one.
  """
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures, only: [ready_release!: 3, target!: 2]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Policy, Repo}
  alias Apiary.Kinds.{Runtime, Runtimes}
  alias Apiary.Policy.{Change, Entry, Error, Grammar, RequiredHosts, Resolution, Rule}
  alias Apiary.Policy.RunConfiguration

  @moduletag needs: :security

  @host "api.anthropic.com"
  @deny_sentence "Remove api.anthropic.com from the rule. Claude Code needs this host, so no rule can deny it."
  @paths_sentence "Remove the paths from the rule. Claude Code needs every path on this host, so no rule can limit it."
  @runtime %{name: "claude", title: "Claude Code"}

  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    %{scope: scope, user: user}
  end

  defp document(scope, holder) do
    {:ok, %RunConfiguration{document: document}} = Policy.current_configuration(scope, holder)
    assert Policy.valid_document(document) == :ok
    document
  end

  defp egress(scope, holder),
    do: Jason.decode!(document(scope, holder))["security_policy"]["egress"]

  defp versions(scope, holder) do
    Policy.list_configurations(scope, holder).total
  end

  # A rule saved before its host became a runtime's: past the writes that refuse it.
  defp saved_rule!(scope, attrs) do
    %Rule{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      kind: "host",
      locked: false
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp stub!(runtimes), do: :ok = Runtimes.put_test_list(runtimes)

  defp runtime(name, hosts, attrs \\ []) do
    struct!(%Runtime{name: name, title: String.capitalize(name), egress_hosts: hosts}, attrs)
  end

  describe "the vendored contract" do
    test "lists Claude Code's host" do
      assert {:ok, %Runtime{title: "Claude Code", egress_hosts: [@host]}} =
               Runtimes.fetch("claude")
    end

    test "has exact hosts only: a *. entry fails here" do
      for %Runtime{egress_hosts: hosts} <- Runtimes.list(), host <- hosts do
        assert Grammar.exact_host?(host), host
      end
    end
  end

  describe "a document" do
    test "of a workspace with no rules allows the runtime's host, as version 1 of a first change",
         %{scope: scope} do
      assert Policy.default_document(scope.workspace.id) ==
               {:ok,
                ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[],"allow_first":["api.anthropic.com"]}}})}

      {:ok, _mode} = Policy.set_mode(scope, "enforce")

      assert document(scope, nil) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":[],"allow_first":["api.anthropic.com"]}}})
    end

    test "of a target allows it too, beside the target's rule", %{scope: scope} do
      target = target!(scope, "acme/site")
      {:ok, _rule} = Policy.allow(scope, target, %{host: "docs.example.com"})

      assert %{"allow" => ["docs.example.com"], "allow_first" => [@host]} = egress(scope, target)
    end

    @tag needs: :secrets
    test "has the host once beside an integration that lists it, and both entries in force",
         %{scope: scope} do
      release =
        ready_release!(
          scope,
          tracker_description(%{
            "name" => "acme-tracker",
            "egress_hosts" => [@host, "api.example.com"],
            "roles" => %{"credential" => %{"argument" => "[A-Z]+", "hosts" => ["example.net"]}}
          }),
          "codeberg.org/acme/acme-tracker"
        )

      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      {:ok, _connection} = Connections.create_integration(scope, release.id, %{})

      assert egress(scope, nil)["allow_first"] == [@host, "api.example.com"]

      entries = Policy.effective(scope, nil, integrations: true).entries

      assert [%Entry{source: :integration, in_force: true}, %Entry{source: :runtime} = runtime] =
               Enum.filter(entries, &(&1.host == @host))

      assert runtime.in_force
      assert runtime.runtime == @runtime
    end

    test "leaves the rule lists of the pages as they were", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      effective = Policy.effective(scope, nil)
      assert effective.allow_first == []
      assert Enum.map(effective.entries, & &1.host) == ["docs.example.com"]

      assert [%Entry{source: :runtime, host: @host, connection: nil, rule: nil}] =
               Enum.filter(
                 Policy.effective(scope, nil, integrations: true).entries,
                 &(&1.source == :runtime)
               )
    end
  end

  describe "a deny attempt" do
    test "is refused at the workspace, at a target, locked, and at the level above", %{
      scope: scope
    } do
      target = target!(scope, "acme/site")

      for {holder, attrs} <- [
            {nil, %{host: @host}},
            {nil, %{host: @host, locked: true}},
            {target, %{host: @host}}
          ] do
        assert {:error,
                %Error{
                  reason: :runtime_host,
                  message: @deny_sentence,
                  field: :host,
                  details: %{runtime: @runtime, host: @host}
                }} = Policy.deny(scope, holder, attrs)
      end

      assert {:error, %Error{reason: :runtime_host, message: @deny_sentence}} =
               Policy.check_deny(scope, :workspace, @host)

      assert {:error, %Error{reason: :runtime_host, message: @deny_sentence}} =
               Policy.check_deny(scope, :above, @host)

      assert Policy.list_rules(scope, nil) == []
      assert Policy.check_deny(scope, :workspace, "docs.example.com") == :ok
    end

    test "turning an allow into a deny is refused, and the allow stays", %{scope: scope} do
      {:ok, allowed} = Policy.allow(scope, nil, %{host: @host})

      assert {:error, %Error{reason: :runtime_host}} = Policy.deny(scope, nil, %{host: @host})
      assert Repo.reload!(allowed).action == "allow"
    end

    @tag needs: :factory
    test "of a model provider's host has the runtime's title", %{scope: scope} do
      {:ok, _provider} =
        Connections.create_provider(scope, %{
          provider: "anthropic",
          keys: [%{value_id: "main", value: "sk-hosts-test-0123456789"}]
        })

      assert {:error, %Error{reason: :runtime_host, message: @deny_sentence}} =
               Policy.deny(scope, nil, %{host: @host})
    end

    test "through a request of changes is refused", %{scope: scope} do
      {:ok, requested} =
        Policy.requested_changes(%{
          "rules" => [
            %{"change" => "rule_added", "rule" => %{"action" => "deny", "host" => @host}}
          ]
        })

      assert {:error, %Error{reason: :runtime_host}} =
               Repo.transact(fn ->
                 Policy.apply_requested(scope, [scope.workspace], requested)
               end)
    end

    test "with a *. suffix saves: it blocks a sibling and the runtime's host stays first", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})

      assert %{"deny" => ["*.anthropic.com"], "allow_first" => [@host]} = egress(scope, nil)

      runtime =
        Enum.find(
          Policy.effective(scope, nil, integrations: true).entries,
          &(&1.source == :runtime)
        )

      assert runtime.in_force
      assert [%Entry{host: "*.anthropic.com"}] = runtime.overrides
    end
  end

  describe "a path attempt" do
    test "is refused at the workspace and at a target, by every write of a rule", %{scope: scope} do
      target = target!(scope, "acme/site")

      attempts = [
        fn -> Policy.allow(scope, nil, %{host: @host, paths: ["/v1/*"]}) end,
        fn -> Policy.allow(scope, nil, %{host: @host, paths: "/v1/*"}) end,
        fn -> Policy.allow(scope, target, %{host: @host, paths: ["/v1/*"]}) end,
        fn -> Policy.allow_path(scope, nil, @host, "/v1/messages") end,
        fn -> Policy.allow_path(scope, target, @host, "/v1/messages") end
      ]

      for attempt <- attempts do
        assert {:error,
                %Error{
                  reason: :runtime_host,
                  message: @paths_sentence,
                  field: :paths,
                  details: %{runtime: @runtime, host: @host}
                }} = attempt.()
      end

      assert Policy.list_rules(scope, nil) == []
    end

    test "through a request of changes is refused", %{scope: scope} do
      {:ok, requested} =
        Policy.requested_changes(%{
          "rules" => [
            %{
              "change" => "rule_added",
              "rule" => %{"action" => "allow", "host" => @host, "paths" => ["/v1/*"]}
            }
          ]
        })

      assert {:error, %Error{reason: :runtime_host, message: message}} =
               Repo.transact(fn ->
                 Policy.apply_requested(scope, [scope.workspace], requested)
               end)

      assert message =~ @paths_sentence
    end

    test "check_paths/1 is what an edition calls at the level above" do
      assert {:error, %Error{reason: :runtime_host, message: @paths_sentence}} =
               Policy.check_paths(@host)

      assert Policy.check_paths("docs.example.com") == :ok
      assert Policy.check_paths("*.anthropic.com") == :ok
    end

    test "on another host saves, and an allow of the runtime's host on every path saves", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com", paths: ["/v1/*"]})
      {:ok, rule} = Policy.allow(scope, nil, %{host: @host})

      assert rule.paths == nil

      assert %{
               "allow" => ["api.anthropic.com", "docs.example.com"],
               "allow_first" => [@host],
               "paths" => %{"docs.example.com" => ["/v1/*"]}
             } = egress(scope, nil)
    end

    test "a *. allow held to paths saves, and the runtime's host stays on every path", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "*.anthropic.com", paths: ["/v1/*"]})

      assert egress(scope, nil)["paths"] == %{
               "*.anthropic.com" => ["/v1/*"],
               @host => ["/*"]
             }
    end

    test "the export of a *. allow held to paths has the host on every path, as the document",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "*.anthropic.com", paths: ["/v1/*"]})
      assert {:ok, %{policy_file: policy_file}} = Policy.export(scope, nil)

      assert policy_file =~ """
               paths:
                 "*.anthropic.com":
                   - "/v1/*"
                 "api.anthropic.com":
                   - "/*"
             """
    end
  end

  describe "the resolution" do
    @runtime_host %{host: @host, runtime: @runtime}

    defp above_allow(host, paths) do
      %Apiary.Policy.Above{
        name: "Northwind",
        rules: [%Rule{kind: "host", action: "allow", host: host, paths: paths}],
        floor: false
      }
    end

    test "every_path covers a runtime's host whose rule a *. allow above overrode" do
      rule = %Rule{id: Ecto.UUID.generate(), kind: "host", action: "allow", host: @host}

      {:ok, effective} =
        Resolution.resolve(
          "enforce",
          [rule],
          [],
          nil,
          above_allow("*.anthropic.com", ["/v1/*"]),
          [@runtime_host]
        )

      assert effective.allow_first == [@host]
      assert effective.paths[@host] == ["/*"]
    end

    test "an exact allow of the level above held to paths limits nothing" do
      {:ok, effective} =
        Resolution.resolve("enforce", [], [], nil, above_allow(@host, ["/v1/*"]), [@runtime_host])

      assert effective.allow == [@host]
      assert effective.allow_first == [@host]
      assert effective.paths == %{}
    end

    test "a *. allow above held to paths does not take the runtime's entry out of force" do
      {:ok, effective} =
        Resolution.resolve(
          "enforce",
          [],
          [],
          nil,
          above_allow("*.anthropic.com", ["/v1/*"]),
          [@runtime_host]
        )

      assert %Entry{in_force: true, overridden_by: nil} =
               Enum.find(effective.entries, &(&1.host == @host))

      assert effective.paths[@host] == ["/*"]
    end

    test "a level above that allows only its list does not strike the runtime's host" do
      above = %{above_allow("docs.example.com", nil) | own_allows: false}

      {:ok, effective} = Resolution.resolve("enforce", [], [], nil, above, [@runtime_host])

      assert effective.allow_first == [@host]

      assert %Entry{in_force: true, reason: nil} =
               Enum.find(effective.entries, &(&1.host == @host))
    end

    test "a deny of the level above loses to the runtime's host" do
      above = %Apiary.Policy.Above{
        name: "Northwind",
        rules: [%Rule{kind: "host", action: "deny", host: @host}],
        floor: false
      }

      {:ok, effective} = Resolution.resolve("enforce", [], [], nil, above, [@runtime_host])

      assert effective.allow_first == [@host]
      assert effective.deny == []
    end
  end

  describe "a rule saved before the host became a runtime's" do
    test "a deny: a render does not fail, the document allows the host and has no deny", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      rule = saved_rule!(scope, %{action: "deny", host: @host})

      assert {:ok, _versions} = Policy.rerender(scope.workspace.id)

      egress = egress(scope, nil)
      assert egress["allow_first"] == [@host]
      refute Map.has_key?(egress, "deny")

      # The pages read the rules without the runtime's host, as for an integration's host:
      # the rule stays listed, and it can be removed.
      assert Enum.any?(Policy.effective(scope, nil).entries, &(&1.host == @host))
      assert {:ok, _removed} = Policy.remove_rule(scope, rule)
    end

    test "a held allow: a render does not fail, and the host stays on every path", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      rule = saved_rule!(scope, %{action: "allow", host: @host, paths: ["/v1/*"]})

      assert {:ok, _versions} = Policy.rerender(scope.workspace.id)

      egress = egress(scope, nil)
      assert egress["allow"] == [@host, "docs.example.com"]
      assert egress["allow_first"] == [@host]
      refute Map.has_key?(egress, "paths")

      # The pages read the rules without the runtime's host: the rule stays listed with
      # its paths, and it can be removed or opened.
      effective = Policy.effective(scope, nil)
      assert %Entry{paths: ["/v1/*"]} = Enum.find(effective.entries, &(&1.host == @host))

      # A save that would leave the paths is refused; opening the host is not.
      assert {:error, %Error{reason: :runtime_host, field: :paths}} =
               Policy.allow(scope, nil, %{host: @host})

      assert {:error, %Error{reason: :runtime_host, field: :paths}} =
               Policy.allow_path(scope, nil, @host, "/v2/messages")

      assert {:ok, %Rule{paths: nil}} = Policy.allow(scope, nil, %{host: @host, paths: nil})
      assert Repo.reload!(rule).paths == nil
      refute Map.has_key?(egress(scope, nil), "paths")
    end

    test "a held allow: the export has no paths for the host, as the document has none", %{
      scope: scope
    } do
      saved_rule!(scope, %{action: "allow", host: @host, paths: ["/v1/*"]})

      assert {:ok, %{forager_file: forager_file, policy_file: nil}} = Policy.export(scope, nil)
      assert forager_file =~ ~s(- "#{@host}")

      # The paths of another host stay: under enforce the gateway denies a path outside
      # them.
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example.com", paths: ["/acme/*"]})
      assert {:ok, %{policy_file: policy_file}} = Policy.export(scope, nil)

      assert policy_file =~ """
               paths:
                 "git.example.com":
                   - "/acme/*"
             """

      refute policy_file =~ "/v1/*"
    end

    test "a deny: the export does not deny the host, as the document does not", %{
      scope: scope
    } do
      saved_rule!(scope, %{action: "deny", host: @host})
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "tracker.example.com"})

      assert egress(scope, nil)["deny"] == ["tracker.example.com"]

      # A deny of another host stays.
      assert {:ok, %{forager_file: forager_file}} = Policy.export(scope, nil)

      assert forager_file == """
             # ~/.config/qory/forager.yaml
             gateway:
               egress:
                 mode: observe
                 allow:
                   - "api.anthropic.com"
                 deny:
                   - "tracker.example.com"
             """
    end
  end

  describe "the export" do
    test "allows the runtime's host in both texts, sorted in with the other names", %{
      scope: scope
    } do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "*.example.com"})
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example.com", paths: ["/acme/*"]})
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "aaa.example.org"})

      assert {:ok, %{forager_file: forager_file, policy_file: policy_file}} =
               Policy.export(scope, nil)

      allow = """
        allow:
          - "aaa.example.org"
          - "api.anthropic.com"
          - "git.example.com"
          - "*.example.com"
      """

      assert forager_file =~ String.replace(allow, ~r/^/m, "  ")
      assert policy_file =~ allow
    end

    test "lists the runtime's host once when a rule allows it", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: @host})

      assert {:ok, %{forager_file: forager_file}} = Policy.export(scope, nil)

      assert forager_file =~ """
                 allow:
                   - "api.anthropic.com"
             """

      assert length(String.split(forager_file, @host)) == 2
    end

    test "keeps a *. deny that covers the runtime's host, which still denies the host", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})

      assert {:ok, %{forager_file: forager_file}} = Policy.export(scope, nil)

      # The gateway decides deny before allow: a run from the file does not reach the host.
      assert forager_file == """
             # ~/.config/qory/forager.yaml
             gateway:
               egress:
                 mode: observe
                 allow:
                   - "api.anthropic.com"
                 deny:
                   - "*.anthropic.com"
             """
    end

    test "leaves out a *. deny that a target's allow outranks, which the document keeps", %{
      scope: scope
    } do
      target = target!(scope, "acme/site")
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})
      {:ok, _rule} = Policy.allow(scope, target, %{host: @host})

      assert {:ok, %{forager_file: forager_file}} = Policy.export(scope, target)
      assert forager_file =~ ~s(- "#{@host}")
      refute forager_file =~ "*.anthropic.com"

      served = egress(scope, target)
      assert "*.anthropic.com" in served["deny"]
      assert served["allow_first"] == [@host]
    end
  end

  describe "an existing version" do
    test "gains the host at the next boot: one version, one change by no person", %{
      scope: scope
    } do
      stub!([runtime("claude", [])])
      target = target!(scope, "acme/site")
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      {:ok, _rule} = Policy.allow(scope, target, %{host: "shop.example.com"})

      refute Map.has_key?(egress(scope, nil), "allow_first")
      baseline = versions(scope, nil)
      kept = versions(scope, target)
      changes = Policy.list_changes(scope, nil).total

      stub!([runtime("claude", [@host])])

      refute Map.has_key?(egress(scope, nil), "allow_first")

      totals = Apiary.Release.FirstVersions.run()

      assert egress(scope, nil)["allow_first"] == [@host]
      assert egress(scope, target)["allow_first"] == [@host]
      assert versions(scope, nil) == baseline + 1
      assert versions(scope, target) == kept + 1
      assert %{rerendered: %{versions: 2}} = totals

      %{items: [%Change{} = change | _], total: total} = Policy.list_changes(scope, nil)

      assert total == changes + 1
      assert change.action == "rerendered"
      assert change.changed_by_id == nil
      assert change.before == change.after

      assert %{rerendered: %{versions: 0}} = Apiary.Release.FirstVersions.run()
    end

    test "of a workspace that has no version is not given one by the render", %{scope: scope} do
      no_policy_version!(scope.workspace)
      assert Policy.rerender(scope.workspace.id) == {:ok, 0}
      refute Policy.managed?(scope)
    end
  end

  describe "the runtimes that apply" do
    test "a runtime with no hosts adds nothing: the document's bytes and the list", %{
      scope: scope
    } do
      stub!([runtime("claude", [])])

      assert Policy.default_document(scope.workspace.id) ==
               {:ok,
                ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})}

      assert RequiredHosts.runtimes().rows == []
      refute :runtimes in Enum.map(RequiredHosts.of(scope.workspace).groups, & &1.key)
      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: @host})
    end

    test "a *. entry is not rendered, not listed, and refuses no rule", %{scope: scope} do
      stub!([runtime("claude", ["*.anthropic.com"])])

      assert Runtimes.egress_hosts() == []

      assert Policy.default_document(scope.workspace.id) ==
               {:ok,
                ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[]}}})}

      assert RequiredHosts.runtimes().rows == []
      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})
    end

    test "a runtime no run can use does not widen a document", %{scope: scope} do
      stub!([
        runtime("claude", [@host]),
        runtime("other", ["api.other.example"], model_keys: [])
      ])

      assert Runtimes.dispatched() |> Enum.map(& &1.name) == ["claude"]

      assert Policy.default_document(scope.workspace.id) ==
               {:ok,
                ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":[],"allow_first":["api.anthropic.com"]}}})}

      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.other.example"})
    end

    test "a runtime a model choice can name applies, as a run's document has no runtime", %{
      scope: _scope
    } do
      keys = [
        %{"format" => "anthropic-messages", "auth" => %{"type" => "bearer"}, "variable" => "KEY"}
      ]

      stub!([runtime("claude", []), runtime("other", ["api.other.example"], model_keys: keys)])

      assert Runtimes.egress_hosts() == [
               %{host: "api.other.example", runtime: %{name: "other", title: "Other"}}
             ]
    end
  end

  describe "the 64 entries of egress.allow_first" do
    defp hosts(count), do: for(n <- 1..count, do: "host#{n}.example.com")

    defp integration_with(scope, hosts) do
      release =
        ready_release!(
          scope,
          tracker_description(%{
            "name" => "acme-tracker",
            "egress_hosts" => hosts,
            "roles" => %{"credential" => %{"argument" => "[A-Z]+", "hosts" => ["example.net"]}}
          }),
          "codeberg.org/acme/acme-tracker"
        )

      Connections.create_integration(scope, release.id, %{})
    end

    @tag needs: :secrets
    test "63 integration hosts and the runtime's fit", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      assert {:ok, _connection} = integration_with(scope, hosts(63))

      assert length(egress(scope, nil)["allow_first"]) == 64
    end

    @tag needs: :secrets
    test "64 integration hosts and the runtime's are refused as the write that renders them", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      log =
        capture_log(fn ->
          assert {:error, %Error{reason: :invalid_document}} =
                   integration_with(scope, hosts(64))
        end)

      assert log =~ "the runtimes require 65 hosts"
      assert Connections.egress_hosts(scope.workspace) == []
      refute length(egress(scope, nil)["allow_first"]) > 64
    end

    test "a host an integration also lists counts once", %{scope: scope} do
      integrations =
        for host <- [@host | hosts(63)] do
          %{host: host, connection: %{id: Ecto.UUID.generate(), public_id: "c", name: "c"}}
        end

      {:ok, effective} =
        Resolution.resolve(
          "observe",
          [],
          [],
          nil,
          nil,
          integrations ++ [%{host: @host, runtime: @runtime}]
        )

      assert length(effective.allow_first) == 64
    end
  end
end
