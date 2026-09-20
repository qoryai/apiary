defmodule Apiary.PolicyTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Change, Error, Rule, RunConfiguration, Schema}
  alias Apiary.Runs.{Connection, Repository}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp repository_fixture(scope, path \\ "acme/site") do
    Repo.insert!(%Repository{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      forge: "github.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp current!(scope, target) do
    {:ok, configuration} = Policy.current_configuration(scope, target)
    configuration
  end

  defp policy(%RunConfiguration{document: document}),
    do: Jason.decode!(document)["security_policy"]

  describe "the mode" do
    test "is observe until it is set, and a change renders a new baseline", %{scope: scope} do
      assert Policy.get_mode(scope) == "observe"
      assert %{version: 1} = first = current!(scope, nil)
      assert policy(first) == %{"version" => 1, "egress" => %{"mode" => "observe", "allow" => []}}

      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      assert Policy.get_mode(scope) == "enforce"
      assert %{version: 2} = second = current!(scope, nil)
      assert policy(second)["egress"]["mode"] == "enforce"
      assert second.digest != first.digest
      assert second.changed_by_id == scope.user.id

      assert {:error, %Error{reason: :invalid, field: :mode}} = Policy.set_mode(scope, "log")
      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      assert %{total: 1} = Policy.list_changes(scope, nil)
    end
  end

  describe "rules" do
    test "a rule is added, changed and removed, each a change and a version", %{scope: scope} do
      Policy.subscribe(scope)

      assert {:ok, %Rule{host: "api.example", action: "allow", paths: nil}} =
               Policy.allow(scope, nil, %{"host" => " API.example "})

      hive_id = scope.hive.id

      assert_receive {:policy_changed,
                      %{hive_id: ^hive_id, repository_id: nil, action: "rule_added"}}

      assert {:ok, %Rule{paths: ["/a", "/b/*"]} = rule} =
               Policy.allow(scope, :hive, %{host: "api.example", paths: "/a\n/b/*\n"})

      assert [%Rule{host: "api.example"}] = Policy.list_rules(scope, nil)

      assert policy(current!(scope, nil))["egress"] == %{
               "mode" => "observe",
               "allow" => ["api.example"],
               "paths" => %{"api.example" => ["/a", "/b/*"]}
             }

      assert {:ok, %Rule{}} = Policy.remove_rule(scope, rule.id)
      assert [] = Policy.list_rules(scope, nil)

      assert %{items: [removed, changed, added], total: 3} = Policy.list_changes(scope, nil)

      assert [added.action, changed.action, removed.action] ==
               ~w(rule_added rule_changed rule_removed)

      assert Enum.all?([added, changed, removed], &(&1.subject == "api.example"))
      assert Enum.all?([added, changed, removed], &(&1.changed_by.id == scope.user.id))
      assert [added.version_after, changed.version_after, removed.version_after] == [1, 2, 3]

      assert %{added: [%{"host" => "api.example"}], removed: [], changed: [], mode: nil} =
               Policy.diff(added)

      assert %{changed: [{%{"paths" => nil}, %{"paths" => ["/a", "/b/*"]}}]} =
               Policy.diff(changed)

      assert %{removed: [%{"host" => "api.example"}]} = Policy.diff(removed)
    end

    test "the same rule again changes nothing and records nothing", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})

      assert %{total: 1} = Policy.list_changes(scope, nil)
      assert %{version: 1} = current!(scope, nil)
    end

    test "a change that renders the same bytes writes a change and no version", %{scope: scope} do
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "ads.example"})

      # The first baseline is version 1; the deny of a host nothing allows renders the same.
      assert %{total: 1, items: [%Change{version_after: 1}]} = Policy.list_changes(scope, nil)
      assert %{version: 1, changed_by_id: changed_by} = current!(scope, nil)
      assert changed_by == scope.user.id

      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
      assert %{version: 2} = current!(scope, nil)
      {:ok, _rule} = Policy.lock(scope, rule)

      assert %{total: 3, items: [%Change{action: "rule_locked", version_after: 2} | _]} =
               Policy.list_changes(scope, nil)

      assert %{version: 2} = current!(scope, nil)
      assert %{total: 2} = Policy.list_configurations(scope, nil)
    end

    test "what is not in the contract's grammar is refused with a sentence", %{scope: scope} do
      for host <- [
            "https://api.example",
            "api.example:443",
            "api.example/path",
            "*.*.example",
            ""
          ] do
        assert {:error, %Error{reason: :invalid, field: :host, message: message}} =
                 Policy.allow(scope, nil, %{host: host})

        assert message =~ "host"
      end

      assert {:error, %Error{field: :paths}} =
               Policy.allow(scope, nil, %{host: "api.example", paths: ["no-slash"]})

      assert {:error, %Error{field: :paths}} =
               Policy.allow(scope, nil, %{host: "api.example", paths: ["/a/*/b"]})

      assert {:error, %Error{field: :name}} =
               Policy.allow(scope, nil, %{kind: "credential", name: "Not A Name"})

      assert {:error, %Error{field: :argument}} =
               Policy.allow(scope, nil, %{
                 kind: "credential",
                 name: "product",
                 argument: String.duplicate("a", 257)
               })

      assert [] = Policy.list_rules(scope, nil)
      assert %{total: 0} = Policy.list_changes(scope, nil)
    end

    test "credentials are named, never held", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{kind: "credential", name: "model"})

      {:ok, _rule} =
        Policy.allow(scope, nil, %{kind: :credential, name: "product", argument: "acme/shop"})

      assert policy(current!(scope, nil))["credentials"] == [
               %{"name" => "model"},
               %{"name" => "product", "argument" => "acme/shop"}
             ]
    end

    test "an exact deny under an allowed suffix is refused and nothing is kept", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "*.s.example"})
      before = current!(scope, nil)

      assert {:error, %Error{reason: :conflict, message: message}} =
               Policy.deny(scope, nil, %{host: "a.s.example"})

      assert message =~ "can only allow"
      assert [%Rule{host: "*.s.example"}] = Policy.list_rules(scope, nil)
      assert current!(scope, nil).id == before.id
      assert %{total: 1} = Policy.list_changes(scope, nil)
    end

    test "a hive change a repository's rules cannot take is refused and names it", %{scope: scope} do
      repository = repository_fixture(scope)
      {:ok, _rule} = Policy.deny(scope, repository, %{host: "a.s.example"})

      assert {:error, %Error{reason: :conflict, message: message}} =
               Policy.allow(scope, nil, %{host: "*.s.example"})

      assert message =~ "In the repository github.example/acme/site"
      assert [] = Policy.list_rules(scope, nil)
    end
  end

  describe "repositories" do
    test "a repository without rules is served the baseline's; with rules, its own", %{
      scope: scope
    } do
      repository = repository_fixture(scope)
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})

      baseline = current!(scope, nil)
      assert current!(scope, repository).id == baseline.id

      {:ok, _rule} = Policy.allow(scope, repository, %{host: "mcp.example"})
      own = current!(scope, repository)
      assert own.repository_id == repository.id
      assert own.version == 1
      assert policy(own)["egress"]["allow"] == ["api.example", "mcp.example"]
      assert current!(scope, nil).id == baseline.id

      # A change of the hive renders the repository again.
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "cdn.example"})
      assert %{version: 2} = own = current!(scope, repository)
      assert policy(own)["egress"]["allow"] == ["api.example", "cdn.example", "mcp.example"]

      # The repository's last rule goes: its next version says what the baseline says.
      [rule] = Policy.list_rules(scope, repository)
      {:ok, _rule} = Policy.remove_rule(scope, rule)
      assert %{version: 3, repository_id: repository_id} = own = current!(scope, repository)
      assert repository_id == repository.id
      assert own.digest == current!(scope, nil).digest

      assert %{total: 2} = Policy.list_changes(scope, repository)
      assert %{total: 2} = Policy.list_changes(scope, nil)
      assert %{total: 4} = Policy.list_changes(scope, :all)

      assert [%{repository: %Repository{}, rule_count: 0}] = Policy.list_repositories(scope)
    end

    test "the effective policy says where each entry came from", %{scope: scope} do
      repository = repository_fixture(scope)
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "mcp.example", locked: true})
      {:ok, _rule} = Policy.deny(scope, repository, %{host: "api.example"})
      {:ok, _rule} = Policy.allow(scope, repository, %{host: "mcp.example"})

      effective = Policy.effective(scope, repository)
      assert effective.allow == []

      assert [
               %{host: "api.example", source: :hive, in_force: false},
               %{host: "api.example", source: :repository, in_force: true},
               %{host: "mcp.example", source: :hive, locked: true, in_force: true},
               %{
                 host: "mcp.example",
                 source: :repository,
                 in_force: false,
                 overridden_by: %{locked: true}
               }
             ] = effective.entries

      assert Policy.effective(scope, nil).allow == ["api.example"]
    end

    test "versions are read by number and by digest", %{scope: scope} do
      repository = repository_fixture(scope)
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
      baseline = current!(scope, nil)

      assert {:ok, %{id: id}} = Policy.get_configuration(scope, nil, "1")
      assert id == baseline.id
      assert {:error, %Error{reason: :not_found}} = Policy.get_configuration(scope, nil, 2)
      assert {:error, %Error{reason: :not_found}} = Policy.get_configuration(scope, nil, "x")

      # A run of a repository without rules reported the baseline's digest.
      assert {:ok, %{id: ^id}} =
               Policy.configuration_for_digest(scope, repository, baseline.digest)

      assert {:ok, %{id: ^id}} = Policy.configuration_for_digest(scope, nil, baseline.digest)

      assert {:error, %Error{reason: :not_found}} =
               Policy.configuration_for_digest(scope, nil, "sha256=" <> String.duplicate("0", 64))

      assert {:error, %Error{reason: :not_found}} =
               Policy.configuration_for_digest(scope, nil, nil)
    end
  end

  describe "who may" do
    test "a member edits; only an owner locks, unlocks, changes or removes a locked rule", %{
      scope: scope
    } do
      %{scope: member} = member_fixture(scope)

      assert {:ok, rule} = Policy.allow(member, nil, %{host: "api.example"})
      assert {:ok, "enforce"} = Policy.set_mode(member, "enforce")

      assert {:error, %Error{reason: :unauthorized}} = Policy.lock(member, rule)

      assert {:error, %Error{reason: :unauthorized}} =
               Policy.allow(member, nil, %{host: "b.example", locked: true})

      assert {:ok, %Rule{locked: true} = rule} = Policy.lock(scope, rule)

      assert {:error, %Error{reason: :unauthorized, message: message}} =
               Policy.deny(member, nil, %{host: "api.example"})

      assert message =~ "locked"
      assert {:error, %Error{reason: :unauthorized}} = Policy.remove_rule(member, rule)
      assert {:error, %Error{reason: :unauthorized}} = Policy.unlock(member, rule)

      # An owner's change of a locked rule keeps the lock.
      assert {:ok, %Rule{locked: true, paths: ["/a"]}} =
               Policy.allow(scope, nil, %{host: "api.example", paths: ["/a"]})

      assert {:ok, %Rule{locked: false}} = Policy.unlock(scope, rule)
      assert {:ok, %Rule{}} = Policy.remove_rule(member, rule)
    end

    test "only a rule of the hive locks", %{scope: scope} do
      repository = repository_fixture(scope)

      assert {:error, %Error{reason: :invalid}} =
               Policy.allow(scope, repository, %{host: "api.example", locked: true})

      {:ok, rule} = Policy.allow(scope, repository, %{host: "api.example"})
      assert {:error, %Error{reason: :invalid}} = Policy.lock(scope, rule)
    end

    test "someone whose membership is gone changes nothing", %{scope: scope} do
      %{scope: member, membership: membership} = member_fixture(scope)
      {:ok, _} = Apiary.Organisations.remove_member(scope, membership.id)

      assert {:error, %Error{reason: :unauthorized}} =
               Policy.allow(member, nil, %{host: "api.example"})

      assert {:error, %Error{reason: :unauthorized}} = Policy.set_mode(member, "enforce")
    end
  end

  describe "tenancy" do
    test "another hive's repository, rule, configuration and change are not found", %{
      scope: scope
    } do
      %{scope: other} = sign_up_fixture()
      repository = repository_fixture(other)
      {:ok, rule} = Policy.allow(other, repository, %{host: "api.example"})
      {:ok, configuration} = Policy.current_configuration(other, repository)
      %{items: [change]} = Policy.list_changes(other, repository)

      assert {:error, %Error{reason: :not_found}} = Policy.get_repository(scope, repository.id)

      assert {:error, %Error{reason: :not_found}} =
               Policy.allow(scope, repository, %{host: "b.example"})

      assert {:error, %Error{reason: :not_found}} = Policy.get_rule(scope, rule.id)
      assert {:error, %Error{reason: :not_found}} = Policy.remove_rule(scope, rule)
      assert {:error, %Error{reason: :not_found}} = Policy.lock(scope, rule.id)

      assert {:error, %Error{reason: :not_found}} =
               Policy.current_configuration(scope, repository)

      assert {:error, %Error{reason: :not_found}} =
               Policy.configuration_for_digest(scope, nil, configuration.digest)

      assert {:error, %Error{reason: :not_found}} = Policy.get_change(scope, change.id)
      assert [] = Policy.list_rules(scope, repository)
      assert %{items: []} = Policy.list_changes(scope, repository)
      assert %{items: []} = Policy.list_changes(scope, :all)
      assert [] = Policy.list_repositories(scope)
      assert [] = Policy.suggestions(scope, repository)
      assert Policy.effective(scope, repository).allow == []

      # And the other hive's policy is untouched by this one's.
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "mine.example"})
      assert Policy.effective(other, repository).allow == ["api.example"]
    end

    test "the database refuses a rule that names another hive's repository", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      repository = repository_fixture(other)

      assert_raise Ecto.ConstraintError, ~r/policy_rules_repository_id_fkey/, fn ->
        Repo.insert!(%Rule{
          organisation_id: scope.organisation.id,
          hive_id: scope.hive.id,
          repository_id: repository.id,
          kind: "host",
          action: "allow",
          host: "api.example"
        })
      end
    end
  end

  describe "every stored document" do
    test "is valid under the contract's schema, and its digest is of its bytes", %{scope: scope} do
      repository = repository_fixture(scope)
      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.example", locked: true})
      {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/shop.git/*"]})

      {:ok, _} =
        Policy.allow(scope, nil, %{kind: "credential", name: "product", argument: "acme/shop"})

      {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.test"})
      {:ok, _} = Policy.deny(scope, repository, %{kind: "credential", name: "product"})

      configurations = Repo.all(RunConfiguration)
      assert length(configurations) >= 6

      for configuration <- configurations do
        assert :ok = Schema.validate(configuration.document)

        assert configuration.digest ==
                 "sha256=" <>
                   Base.encode16(:crypto.hash(:sha256, configuration.document), case: :lower)
      end
    end
  end

  describe "paths from a row" do
    setup %{scope: scope} do
      run =
        started_run(scope, shop(),
          egress: [
            %{"host" => "git.example", "path" => "/acme/shop.git/git-receive-pack"},
            %{"host" => "new.example"}
          ]
        )

      connections = Repo.all(from c in Connection, where: c.run_id == ^run.id)
      repository = Repo.get!(Repository, run.repository_id)

      %{
        repository: repository,
        git: Enum.find(connections, &(&1.host == "git.example")),
        new: Enum.find(connections, &(&1.host == "new.example"))
      }
    end

    test "a host is allowed or denied in the repository or in the hive", ctx do
      assert {:ok, %Rule{host: "new.example", action: "allow", repository_id: repository_id}} =
               Policy.rule_from_connection(ctx.scope, ctx.new, :allow, :repository)

      assert repository_id == ctx.repository.id

      assert {:ok, %Rule{host: "new.example", action: "deny", repository_id: nil}} =
               Policy.rule_from_connection(ctx.scope, ctx.new, :deny, :hive)
    end

    test "on a host held to paths the path is added or taken out", ctx do
      {:ok, _} =
        Policy.allow(ctx.scope, nil, %{host: "git.example", paths: ["/acme/shop.git/info/refs"]})

      assert {:ok, %Rule{repository_id: repository_id, paths: paths}} =
               Policy.rule_from_connection(ctx.scope, ctx.git, :allow, :repository)

      assert repository_id == ctx.repository.id
      assert paths == ["/acme/shop.git/info/refs", "/acme/shop.git/git-receive-pack"]

      assert {:ok, %Rule{paths: ["/acme/shop.git/info/refs"]}} =
               Policy.rule_from_connection(ctx.scope, ctx.git, :deny, :repository)

      assert {:error, %Error{message: message}} =
               Policy.rule_from_connection(ctx.scope, ctx.git, :deny, :repository)

      assert message =~ "denied already"
    end

    test "a path cannot be taken out of every path or out of a pattern; a locked rule holds",
         ctx do
      {:ok, rule} = Policy.allow(ctx.scope, nil, %{host: "git.example"})

      assert {:error, %Error{message: message}} =
               Policy.deny_path(ctx.scope, nil, "git.example", "/x")

      assert message =~ "every path but one"

      {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "git.example", paths: ["/acme/*"]})

      assert {:error, %Error{message: message}} =
               Policy.deny_path(ctx.scope, nil, "git.example", "/acme/shop")

      assert message =~ "pattern /acme/*"

      {:ok, _} = Policy.lock(ctx.scope, rule)

      assert {:error, %Error{reason: :locked}} =
               Policy.rule_from_connection(ctx.scope, ctx.git, :allow, :repository)
    end

    test "another hive's connection is not found; a run without a repository goes to the hive",
         ctx do
      %{scope: other} = sign_up_fixture()

      assert {:error, %Error{reason: :not_found}} =
               Policy.rule_from_connection(other, ctx.new, :allow, :hive)

      run = started_run(ctx.scope, %{}, egress: [%{"host" => "new.example"}])
      connection = Repo.one!(from c in Connection, where: c.run_id == ^run.id)

      assert {:error, %Error{reason: :not_found, message: message}} =
               Policy.rule_from_connection(ctx.scope, connection, :allow, :repository)

      assert message =~ "names no repository"
      assert {:ok, %Rule{}} = Policy.rule_from_connection(ctx.scope, connection, :allow, :hive)
    end
  end

  describe "suggestions" do
    test "the harness's hosts the policy does not cover, bounded and in the grammar", %{
      scope: scope
    } do
      run = started_run(scope, shop())
      repository = Repo.get!(Repository, run.repository_id)

      event_fixture(run, 10, "run.policy_applied", %{
        "mode" => "enforce",
        "harness_hosts" => [
          "api.example",
          "docs.s.example",
          "registry.example",
          "NOT A HOST",
          "https://x.example",
          7
        ]
      })

      other = started_run(scope, shop())
      event_fixture(other, 10, "run.policy_applied", %{"harness_hosts" => ["registry.example"]})

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, repository, %{host: "*.s.example"})

      assert [%{host: "registry.example", runs: 2, last_seen_at: %DateTime{}}] =
               Policy.suggestions(scope, repository)

      {:ok, _} = Policy.allow(scope, repository, %{host: "registry.example"})
      assert [] = Policy.suggestions(scope, repository)
    end
  end

  describe "export" do
    test "hosts alone are the runner file's egress section", %{scope: scope} do
      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

      assert {:ok, %{runner_file: runner_file, policy_file: nil, notes: []}} =
               Policy.export(scope, nil)

      assert runner_file == """
             # ~/.config/qory/runner.yaml
             egress:
               mode: enforce
               allow:
                 - "api.example"
                 - "*.example"
             """
    end

    test "paths and credentials go to a policy file the contract's schema accepts", %{
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/shop.git/*"]})

      {:ok, _} =
        Policy.allow(scope, nil, %{kind: "credential", name: "product", argument: "acme/shop"})

      assert {:ok, %{runner_file: runner_file, policy_file: policy_file, notes: [_ | _]}} =
               Policy.export(scope, nil)

      refute runner_file =~ "paths"

      assert policy_file == """
             # A file outside the checkout, given with: qory run --policy <file>
             version: 1
             egress:
               mode: observe
               allow:
                 - "git.example"
               paths:
                 "git.example":
                   - "/acme/shop.git/*"
             credentials:
               - name: "product"
                 argument: "acme/shop"
             """
    end
  end
end
