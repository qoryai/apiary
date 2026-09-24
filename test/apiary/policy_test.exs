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

  defp current!(scope, holder) do
    {:ok, configuration} = Policy.current_configuration(scope, holder)
    configuration
  end

  defp policy(%RunConfiguration{document: document}),
    do: Jason.decode!(document)["security_policy"]

  describe "the mode" do
    test "is observe until it is set; nothing is rendered until the first change, which is version 1",
         %{scope: scope} do
      assert Policy.get_mode(scope) == "observe"

      # A read of a hive nobody has changed renders and stores nothing.
      assert {:error, %Error{reason: :unmanaged}} = Policy.current_configuration(scope, nil)

      assert {:error, %Error{reason: :unmanaged}} =
               Policy.current_configuration(scope, repository_fixture(scope))

      assert %{in_force: nil, drift: false} = Policy.digests(scope, run_fixture(scope))

      assert {:error, %Error{reason: :not_found}} =
               Policy.configuration_for_digest(scope, nil, "sha256=" <> String.duplicate("0", 64))

      assert Repo.aggregate(RunConfiguration, :count) == 0
      refute Policy.managed?(scope)

      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      assert Policy.get_mode(scope) == "enforce"
      assert %{version: 1, policy_change_id: change_id} = first = current!(scope, nil)
      assert is_binary(change_id)
      assert policy(first)["egress"]["mode"] == "enforce"
      assert first.changed_by_id == scope.user.id

      assert {:error, %Error{reason: :invalid, field: :mode}} = Policy.set_mode(scope, "log")
      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      assert %{total: 1} = Policy.list_changes(scope, nil)
    end
  end

  describe "a repository's mode" do
    setup %{scope: scope} do
      %{repository: repository_fixture(scope), other: repository_fixture(scope, "acme/docs")}
    end

    test "follows the hive until it sets its own, and goes back by :inherit", ctx do
      %{scope: scope, repository: repository} = ctx

      assert Policy.get_mode(scope, nil) == "observe"
      assert Policy.get_mode(scope, :hive) == "observe"
      assert Policy.get_mode(scope, repository) == %{mode: "observe", own: nil, hive: "observe"}
      assert %{mode: "observe", mode_source: :hive} = Policy.effective(scope, repository)

      assert {:ok, %{mode: "enforce", own: "enforce", hive: "observe"}} =
               Policy.set_mode(scope, repository, "enforce")

      assert Policy.get_mode(scope, repository) == %{
               mode: "enforce",
               own: "enforce",
               hive: "observe"
             }

      assert Policy.get_mode(scope) == "observe"
      assert %{mode: "enforce", mode_source: :repository} = Policy.effective(scope, repository)
      assert %{mode: "observe", mode_source: :hive} = Policy.effective(scope, nil)
      assert %{mode: "observe", mode_source: :hive} = Policy.effective(scope, ctx.other)

      # A repository with only a mode of its own has a configuration of its own.
      own = current!(scope, repository)
      assert own.repository_id == repository.id
      assert policy(own)["egress"]["mode"] == "enforce"
      assert policy(current!(scope, nil))["egress"]["mode"] == "observe"
      assert current!(scope, ctx.other).repository_id == nil

      assert {:ok, %{mode: "observe", own: nil}} = Policy.set_mode(scope, repository, "inherit")
      assert %{version: 2} = own = current!(scope, repository)
      assert policy(own)["egress"]["mode"] == "observe"

      assert {:ok, %{own: "observe"}} = Policy.set_mode(scope, repository, "observe")
      # The same bytes: a change, and no new version.
      assert %{version: 2} = current!(scope, repository)
      assert {:ok, %{own: nil}} = Policy.set_mode(scope, repository, :inherit)

      assert [
               %{repository: %{path: "acme/docs"}, own_mode: nil, mode: "observe"},
               %{repository: %{path: "acme/site"}, own_mode: nil, mode: "observe"}
             ] = Policy.list_repositories(scope)
    end

    test "a hive's change moves the repositories that follow it and leaves the others", ctx do
      %{scope: scope, repository: repository, other: other} = ctx
      {:ok, _} = Policy.set_mode(scope, repository, "observe")
      {:ok, _} = Policy.allow(scope, other, %{host: "mcp.example"})
      kept = current!(scope, repository)
      followed = current!(scope, other)

      assert {:ok, "enforce"} = Policy.set_mode(scope, nil, "enforce")

      assert current!(scope, repository).id == kept.id
      assert %{mode: "observe", mode_source: :repository} = Policy.effective(scope, repository)

      moved = current!(scope, other)
      assert moved.version == followed.version + 1
      assert policy(moved)["egress"]["mode"] == "enforce"
      assert policy(current!(scope, nil))["egress"]["mode"] == "enforce"

      # Inherit follows a later change of the hive, too.
      {:ok, _} = Policy.set_mode(scope, repository, :inherit)
      assert policy(current!(scope, repository))["egress"]["mode"] == "enforce"
      {:ok, _} = Policy.set_mode(scope, "observe")
      assert policy(current!(scope, repository))["egress"]["mode"] == "observe"

      assert [%{own_mode: nil, mode: "observe"}, %{own_mode: nil, mode: "observe"}] =
               Policy.list_repositories(scope)
    end

    test "is a change in the repository's history, and its diff says from what to what", ctx do
      %{scope: scope, repository: repository} = ctx
      Policy.subscribe(scope)
      {:ok, _} = Policy.set_mode(scope, repository, "enforce")

      repository_id = repository.id
      assert_receive {:policy_changed, %{repository_id: ^repository_id, action: "mode_changed"}}

      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _} = Policy.set_mode(scope, repository, :inherit)
      # Setting what is set already is no change.
      {:ok, _} = Policy.set_mode(scope, repository, :inherit)

      assert %{items: [back, first], total: 2} = Policy.list_changes(scope, repository)
      assert first.action == "mode_changed" and first.version_after == 1

      assert %{mode: {"inherit", "enforce"}, added: [], removed: [], changed: []} =
               Policy.diff(first)

      assert %{mode: {"enforce", "inherit"}} = Policy.diff(back)
      # The repository's bytes did not change when it went back to a hive that enforces.
      assert back.version_after == 1

      # The hive's change is the hive's, not the repository's.
      assert %{items: [%{action: "mode_changed"} = hive], total: 1} =
               Policy.list_changes(scope, nil)

      assert %{mode: {"observe", "enforce"}} = Policy.diff(hive)

      # A rule's change in the repository does not read as a change of mode.
      {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.example"})
      %{items: [rule | _]} = Policy.list_changes(scope, repository)
      assert %{mode: nil, added: [%{"host" => "mcp.example"}]} = Policy.diff(rule)
    end

    test "is an owner's to set; what is no mode is refused; it makes the hive managed", ctx do
      %{scope: scope, repository: repository} = ctx
      %{scope: member} = member_fixture(scope)

      assert {:error, %Error{reason: :unauthorized}} =
               Policy.set_mode(member, repository, "enforce")

      assert {:error, %Error{reason: :unauthorized}} =
               Policy.set_mode(member, repository, :inherit)

      assert {:error, %Error{reason: :invalid, field: :mode}} =
               Policy.set_mode(scope, repository, "log")

      assert {:error, %Error{reason: :invalid, field: :mode}} =
               Policy.set_mode(scope, nil, :inherit)

      refute Policy.managed?(scope)

      assert {:ok, _} = Policy.set_mode(scope, repository, "enforce")
      assert Policy.managed?(scope)
    end

    test "a locked rule of the hive holds under the repository's own mode", ctx do
      %{scope: scope, repository: repository} = ctx
      {:ok, _} = Policy.deny(scope, nil, %{host: "mcp.example", locked: true})
      {:ok, _} = Policy.allow(scope, repository, %{host: "mcp.example"})
      {:ok, _} = Policy.allow(scope, repository, %{host: "api.example"})

      for mode <- ["observe", "enforce"] do
        {:ok, _} = Policy.set_mode(scope, repository, mode)

        # The locked deny is in the document's deny list under either mode: the runner
        # decides it first, so the repository is denied mcp.example while it observes too.
        assert policy(current!(scope, repository))["egress"] == %{
                 "mode" => mode,
                 "allow" => ["api.example"],
                 "deny" => ["mcp.example"]
               }
      end
    end

    test "another hive's repository is not found, and an unknown one follows the hive", ctx do
      %{scope: other} = sign_up_fixture()

      assert {:error, %Error{reason: :not_found}} =
               Policy.set_mode(other, ctx.repository, "enforce")

      assert Policy.get_mode(other, ctx.repository) == %{
               mode: "observe",
               own: nil,
               hive: "observe"
             }

      assert Repo.get!(Repository, ctx.repository.id).egress_mode == nil
    end

    test "the database takes observe, enforce or null and nothing else", ctx do
      assert_raise Postgrex.Error, ~r/repositories_egress_mode_check/, fn ->
        Repo.query!("UPDATE repositories SET egress_mode = 'log' WHERE id = $1", [
          Ecto.UUID.dump!(ctx.repository.id)
        ])
      end
    end

    test "the export says the mode in force for the repository", ctx do
      {:ok, _} = Policy.set_mode(ctx.scope, ctx.repository, "enforce")
      assert {:ok, %{runner_file: runner_file}} = Policy.export(ctx.scope, ctx.repository)
      assert runner_file =~ "mode: enforce"
      assert {:ok, %{runner_file: hive_file}} = Policy.export(ctx.scope, nil)
      assert hive_file =~ "mode: observe"
    end
  end

  describe "mode_summary/1" do
    test "is managed, the hive's mode and the repositories' own modes, in one query", %{
      scope: scope
    } do
      assert Policy.mode_summary(scope) == %{managed?: false, mode: "observe", own_modes: []}

      site = repository_fixture(scope)
      docs = repository_fixture(scope, "acme/docs")
      _plain = repository_fixture(scope, "acme/plain")
      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, _} = Policy.set_mode(scope, site, "observe")
      {:ok, _} = Policy.set_mode(scope, docs, "enforce")

      handler = "mode-summary-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == parent, do: send(parent, :query)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      summary = Policy.mode_summary(scope)
      assert_received :query
      refute_received :query

      assert %{managed?: true, mode: "enforce", own_modes: own} = summary
      assert Enum.sort(own) == ["enforce", "observe"]

      %{scope: other} = sign_up_fixture()
      assert Policy.mode_summary(other) == %{managed?: false, mode: "observe", own_modes: []}
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
      {:ok, _rule} = Policy.deny(scope, nil, %{kind: "credential", name: "model"})

      # The first change renders version 1 whatever it changed in the bytes.
      assert %{total: 1, items: [%Change{version_after: 1}]} = Policy.list_changes(scope, nil)
      assert %{version: 1, changed_by_id: changed_by} = current!(scope, nil)
      assert changed_by == scope.user.id
      # A credential deny is not in the document: the same bytes, no version.
      {:ok, _rule} = Policy.deny(scope, nil, %{kind: "credential", name: "product"})
      assert %{version: 1} = current!(scope, nil)

      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
      assert %{version: 2} = current!(scope, nil)
      {:ok, _rule} = Policy.lock(scope, rule)

      assert %{total: 4, items: [%Change{action: "rule_locked", version_after: 2} | _]} =
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

    test "an exact deny under an allowed suffix is accepted and written to deny", %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "*.s.example"})
      before = current!(scope, nil)

      assert {:ok, %Rule{action: "deny", host: "a.s.example"}} =
               Policy.deny(scope, nil, %{host: "a.s.example"})

      assert current!(scope, nil).version == before.version + 1

      assert policy(current!(scope, nil))["egress"] == %{
               "mode" => "observe",
               "allow" => ["*.s.example"],
               "deny" => ["a.s.example"]
             }

      assert %{total: 2} = Policy.list_changes(scope, nil)
    end

    test "a deny of a host nothing allows renders a version: it holds under observe", %{
      scope: scope
    } do
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "ads.example"})

      assert %{version: 1} = current!(scope, nil)

      assert policy(current!(scope, nil))["egress"] == %{
               "mode" => "observe",
               "allow" => [],
               "deny" => ["ads.example"]
             }
    end

    test "a hive change a repository's rules cannot take is refused and names it", %{scope: scope} do
      repository = repository_fixture(scope)
      {:ok, _rule} = Policy.allow(scope, repository, %{host: "git.example", paths: ["/a"]})

      assert {:error, %Error{reason: :conflict, message: message}} =
               Policy.allow(scope, nil, %{host: "*.example", paths: ["/b"]})

      assert message =~ "In the repository github.example/acme/site"
      assert [] = Policy.list_rules(scope, nil)
    end
  end

  describe "what is not named stays" do
    test "allowing a host held to paths again does not open it; every path is said", %{
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/a"]})

      assert {:ok, %Rule{paths: ["/a"]}} = Policy.allow(scope, nil, %{host: "git.example"})

      assert {:ok, %Rule{paths: ["/a"]}} =
               Policy.allow(scope, nil, %{host: "git.example", paths: " \n "})

      assert {:ok, %Rule{paths: ["/a"]}} =
               Policy.allow(scope, nil, %{host: "git.example", paths: ""})

      assert %{total: 1} = Policy.list_changes(scope, nil)

      assert {:ok, %Rule{paths: nil}} =
               Policy.allow(scope, nil, %{host: "git.example", paths: nil})

      assert {:ok, %Rule{paths: []}} = Policy.allow(scope, nil, %{host: "git.example", paths: []})

      # A deny takes the host whole, and an allow after it starts from every path.
      assert {:ok, %Rule{action: "deny", paths: nil}} =
               Policy.deny(scope, nil, %{host: "git.example"})

      assert {:ok, %Rule{action: "allow", paths: nil}} =
               Policy.allow(scope, nil, %{host: "git.example"})

      # A new rule with an empty paths field is on every path.
      assert {:ok, %Rule{paths: nil}} =
               Policy.allow(scope, nil, %{host: "new.example", paths: ""})
    end

    test "a credential's argument stays when it is not named", %{scope: scope} do
      {:ok, _} =
        Policy.allow(scope, nil, %{kind: "credential", name: "product", argument: "acme/site"})

      assert {:ok, %Rule{argument: "acme/site"}} =
               Policy.allow(scope, nil, %{kind: "credential", name: "product"})
    end
  end

  describe "bounds" do
    test "a list holds at most 500 rules", %{scope: scope} do
      now = DateTime.utc_now()

      rows =
        for n <- 1..500 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: scope.organisation.id,
            hive_id: scope.hive.id,
            kind: "host",
            action: "allow",
            host: "h#{n}.example",
            locked: false,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Rule, rows)

      assert {:error, %Error{reason: :invalid, message: message}} =
               Policy.allow(scope, nil, %{host: "one-more.example"})

      assert message =~ "500 rules"
      # A rule that is there is still changed, and a repository has a list of its own.
      assert {:ok, %Rule{}} = Policy.deny(scope, nil, %{host: "h1.example"})

      assert {:ok, %Rule{}} =
               Policy.allow(scope, repository_fixture(scope), %{host: "one-more.example"})
    end

    test "a rule holds at most 100 paths", %{scope: scope} do
      assert {:error, %Error{field: :paths, message: message}} =
               Policy.allow(scope, nil, %{
                 host: "git.example",
                 paths: for(n <- 1..101, do: "/p/#{n}")
               })

      assert message =~ "at most 100"
    end

    test "a document over 1 MiB, more than a runner reads, is a refused change", %{scope: scope} do
      paths = fn n -> for m <- 1..100, do: "/" <> String.duplicate("a", 1000) <> "/#{n}/#{m}" end

      for n <- 1..10,
          do: {:ok, _} = Policy.allow(scope, nil, %{host: "h#{n}.example", paths: paths.(n)})

      {:ok, before} = Policy.current_configuration(scope, nil)
      assert byte_size(before.document) < 1_048_576

      assert {:error, %Error{reason: :invalid_document, message: message}} =
               Policy.allow(scope, nil, %{host: "h11.example", paths: paths.(11)})

      assert message =~ "over 1 MiB"
      assert length(Policy.list_rules(scope, nil)) == 10
      assert {:ok, %{id: id}} = Policy.current_configuration(scope, nil)
      assert id == before.id
    end
  end

  describe "under the hive's lock" do
    test "a rule removed in the meantime is not found, by remove, lock and unlock", %{
      scope: scope
    } do
      {:ok, rule} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.remove_rule(scope, rule)

      # The caller still holds the struct it read before.
      assert {:error, %Error{reason: :not_found}} = Policy.remove_rule(scope, rule)
      assert {:error, %Error{reason: :not_found}} = Policy.lock(scope, rule)
      assert {:error, %Error{reason: :not_found}} = Policy.unlock(scope, rule)
    end

    test "a member holding a rule from before it was locked cannot remove it", %{scope: scope} do
      %{scope: member} = member_fixture(scope)
      {:ok, stale} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _locked} = Policy.lock(scope, stale)

      assert {:error, %Error{reason: :unauthorized}} = Policy.remove_rule(member, stale)
      assert [%Rule{locked: true}] = Policy.list_rules(scope, nil)
    end

    test "the hive's row is locked without blocking the receiver's inserts", %{scope: scope} do
      # FOR NO KEY UPDATE does not conflict with the FOR KEY SHARE a foreign key takes;
      # FOR UPDATE would. Said by the query, since two transactions do not meet in a sandbox.
      handler = "policy-lock-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler,
        [:apiary, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent and query =~ "FOR ", do: send(parent, {:lock, query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.current_configuration(scope, nil)

      assert_received {:lock, query}
      assert query =~ "FOR NO KEY UPDATE"
      refute_received {:lock, "FOR UPDATE" <> _}
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

  describe "bulk reads" do
    setup %{scope: scope} do
      site = repository_fixture(scope)
      docs = repository_fixture(scope, "acme/docs")
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      {:ok, _} = Policy.allow(scope, site, %{host: "mcp.example"})
      {:ok, _} = Policy.allow(scope, nil, %{host: "cdn.example"})
      %{site: site, docs: docs}
    end

    test "newest_versions/2: one per holder with a configuration of its own, no documents", ctx do
      versions =
        Policy.newest_versions(ctx.scope, [
          nil,
          ctx.site,
          ctx.docs.id,
          "not-an-id",
          Ecto.UUID.generate()
        ])

      assert Map.keys(versions) |> Enum.sort() == Enum.sort([nil, ctx.site.id])
      assert %RunConfiguration{version: 2, document: nil, digest: "sha256=" <> _} = versions[nil]
      assert %RunConfiguration{version: 2, document: nil} = versions[ctx.site.id]
      assert versions[nil].digest == current!(ctx.scope, nil).digest

      assert Map.keys(Policy.newest_versions(ctx.scope, [:hive])) == [nil]
      assert Policy.newest_versions(ctx.scope, [ctx.site]) |> Map.keys() == [ctx.site.id]
      assert Policy.newest_versions(ctx.scope, []) == %{}
    end

    test "configurations_for_changes/2: what each change rendered, the baseline's first", ctx do
      %{items: [cdn, mcp, api]} = Policy.list_changes(ctx.scope, :all)
      by_change = Policy.configurations_for_changes(ctx.scope, [cdn.id, mcp.id, api.id, "x"])

      assert [%{repository_id: nil, version: 1, document: nil}] = by_change[api.id]
      assert [%{repository_id: site_id, version: 1}] = by_change[mcp.id]
      assert site_id == ctx.site.id
      # The hive's second rule rendered the baseline and the repository that has rules.
      assert [%{repository_id: nil, version: 2}, %{repository_id: ^site_id, version: 2}] =
               by_change[cdn.id]

      # A change that rendered the same bytes has no key.
      {:ok, _} = Policy.deny(ctx.scope, nil, %{kind: "credential", name: "model"})
      %{items: [same | _]} = Policy.list_changes(ctx.scope, nil)
      assert Policy.configurations_for_changes(ctx.scope, [same.id]) == %{}
    end

    test "last_changes/2: the newest change of each holder, who made it, no rule sets", ctx do
      changes = Policy.last_changes(ctx.scope, [nil, ctx.site, ctx.docs])

      assert Map.keys(changes) |> Enum.sort() == Enum.sort([nil, ctx.site.id])

      assert %Change{subject: "cdn.example", before: nil, after: nil, version_after: 2} =
               changes[nil]

      assert changes[nil].changed_by.id == ctx.scope.user.id
      assert %Change{subject: "mcp.example"} = changes[ctx.site.id]
    end

    test "another hive reads none of it", ctx do
      %{scope: other} = sign_up_fixture()
      %{items: changes} = Policy.list_changes(ctx.scope, :all)

      assert Policy.newest_versions(other, [nil, ctx.site]) == %{}
      assert Policy.last_changes(other, [nil, ctx.site.id]) == %{}
      assert Policy.configurations_for_changes(other, Enum.map(changes, & &1.id)) == %{}
    end
  end

  describe "who may" do
    test "a member edits; only an owner locks, unlocks, changes or removes a locked rule", %{
      scope: scope
    } do
      %{scope: member} = member_fixture(scope)

      assert {:ok, rule} = Policy.allow(member, nil, %{host: "api.example"})

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

    test "the mode is an owner's to change, in both directions", %{scope: scope} do
      %{scope: member} = member_fixture(scope)

      assert {:error, %Error{reason: :unauthorized, message: message}} =
               Policy.set_mode(member, "enforce")

      assert message =~ "Only an owner changes the mode"
      assert Policy.get_mode(scope) == "observe"

      assert {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      assert {:error, %Error{reason: :unauthorized}} = Policy.set_mode(member, "observe")
      assert Policy.get_mode(scope) == "enforce"
    end

    test "a lock is said as true or false: nothing a cast would read as true gets past", %{
      scope: scope
    } do
      %{scope: member} = member_fixture(scope)
      repository = repository_fixture(scope)

      for locked <- ["1", 1, "true", true, "t", "yes"] do
        assert {:error, %Error{reason: reason}} =
                 Policy.allow(member, nil, %{"host" => "api.example", "locked" => locked})

        assert reason in [:unauthorized, :invalid], inspect(locked)

        # On a repository it is a refusal with a sentence, never the database's constraint.
        for who <- [member, scope] do
          assert {:error, %Error{reason: :invalid}} =
                   Policy.allow(who, repository, %{host: "api.example", locked: locked})
        end
      end

      assert [] = Policy.list_rules(scope, nil)
      assert [] = Policy.list_rules(scope, repository)

      # An owner locks with true or "true"; "1" is refused for an owner too.
      assert {:error, %Error{reason: :invalid}} =
               Policy.allow(scope, nil, %{host: "a.example", locked: "1"})

      assert {:ok, %Rule{locked: true}} =
               Policy.allow(scope, nil, %{host: "a.example", locked: "true"})

      assert {:ok, %Rule{locked: false}} =
               Policy.allow(member, repository, %{host: "b.example", locked: "false"})

      # And a member cannot unlock by any spelling.
      for locked <- [false, "false", "0", 0] do
        assert {:error, %Error{}} =
                 Policy.allow(member, nil, %{host: "a.example", locked: locked})
      end

      assert [%Rule{locked: true}] = Policy.list_rules(scope, nil)
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

    test "the digests of another hive's run are a refusal, not a raise", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      run = run_fixture(other)

      assert {:error, %Error{reason: :not_found}} = Policy.digests(scope, run)
      assert %{drift: false} = Policy.digests(other, run)
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

    test "allowing a connection that names no path, on a host held to paths, is refused", ctx do
      {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "new.example", paths: ["/v1/*"]})

      for level <- [:repository, :hive] do
        assert {:error, %Error{reason: :invalid, field: :paths, message: message}} =
                 Policy.rule_from_connection(ctx.scope, ctx.new, :allow, level)

        assert message =~ "names no path"
      end

      assert [%Rule{paths: ["/v1/*"]}] = Policy.list_rules(ctx.scope, nil)
      assert [] = Policy.list_rules(ctx.scope, ctx.repository)

      # Denying the host whole is still one click.
      assert {:ok, %Rule{action: "deny"}} =
               Policy.rule_from_connection(ctx.scope, ctx.new, :deny, :repository)
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

      # Shown against the record and against the rules.
      started_run(scope, shop(),
        egress: [
          %{"host" => "registry.example", "decision" => "denied"},
          %{"host" => "registry.example", "decision" => "denied"},
          %{"host" => "api.example", "decision" => "allowed"}
        ]
      )

      assert [%{host: "registry.example", allowed: 0, denied: 2}] =
               Policy.suggestions(scope, repository)

      future = DateTime.add(DateTime.utc_now(), 60, :second)
      assert [%{allowed: 0, denied: 0}] = Policy.suggestions(scope, repository, future)

      hive_rule = Enum.find(Policy.list_rules(scope, nil), &(&1.host == "api.example"))

      assert %{
               suggested: [%{host: "registry.example", denied: 2}],
               covered: [
                 %{host: "api.example", by: "api.example", source: :hive, rule_id: rule_id},
                 %{host: "docs.s.example", by: "*.s.example", source: :repository}
               ]
             } = Policy.declared_hosts(scope, repository)

      assert rule_id == hive_rule.id

      %{scope: other} = sign_up_fixture()
      assert %{suggested: [], covered: []} = Policy.declared_hosts(other, repository)

      # A host somebody denied is not suggested; one allowed is covered.
      {:ok, _} = Policy.deny(scope, nil, %{host: "registry.example"})
      assert [] = Policy.suggestions(scope, repository)
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

    test "a deny is in the egress section and in the policy file, and observe's note says so",
         %{scope: scope} do
      {:ok, _} = Policy.allow(scope, nil, %{host: "*.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "tracker.example"})
      {:ok, _} = Policy.deny(scope, nil, %{host: "*.ads.example"})

      assert {:ok, %{runner_file: runner_file, policy_file: nil, notes: [note]}} =
               Policy.export(scope, nil)

      assert runner_file == """
             # ~/.config/qory/runner.yaml
             egress:
               mode: observe
               allow:
                 - "*.example"
               deny:
                 - "tracker.example"
                 - "*.ads.example"
             """

      assert note =~ "only a host in deny is denied"

      {:ok, _} = Policy.allow(scope, nil, %{host: "git.example", paths: ["/a/*"]})
      assert {:ok, %{policy_file: policy_file}} = Policy.export(scope, nil)

      assert policy_file =~ """
             egress:
               mode: observe
               allow:
                 - "git.example"
                 - "*.example"
               deny:
                 - "tracker.example"
                 - "*.ads.example"
               paths:
             """
    end

    test "what YAML reads as a line break is refused in a rule, and escaped should it be there",
         %{scope: scope} do
      assert {:error, %Error{field: :paths}} =
               Policy.allow(scope, nil, %{host: "git.example", paths: ["/a\u2028b"]})

      assert {:error, %Error{field: :argument}} =
               Policy.allow(scope, nil, %{
                 kind: "credential",
                 name: "product",
                 argument: "x\u2028y: z"
               })

      # The export does not lean on that: a scalar is one line whatever it holds.
      effective = %Apiary.Policy.Effective{
        mode: "enforce",
        allow: ["git.example"],
        paths: %{"git.example" => ["/a\u2028b", "/c\u2029d", "/e\u0085f", "/ü/🐝"]},
        credentials: [%{name: "product", argument: "x\u2028y: z"}]
      }

      %{policy_file: policy_file} = Apiary.Policy.Export.text(effective)

      refute policy_file =~ ~r/[\x{85}\x{2028}\x{2029}]/u
      assert policy_file =~ ~S("/a\u2028b")
      assert policy_file =~ ~S("/c\u2029d")
      assert policy_file =~ ~S("/e\u0085f")
      assert policy_file =~ ~S(argument: "x\u2028y: z")
      # Nothing else is escaped: an astral character stays itself.
      assert policy_file =~ ~s("/ü/🐝")
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
