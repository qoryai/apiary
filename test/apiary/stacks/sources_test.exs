defmodule Apiary.Stacks.SourcesTest do
  # The harness sources Workspace settings › Workflow offers (`Apiary.Stacks.Sources`),
  # read through stub adapters (`Req.Test`): the linked repositories that have a stack,
  # the instance's assignments, a typed address and its refusals, the stacks and
  # workflows each has, the save of the runs' workflow, the organisation's shared
  # harness, and the stack chosen for a target, which a run's walk then reads.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Harnesses.{Assignment, Walk}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias Apiary.Stacks.{Sources, Stack}

  @moduletag needs: :factory
  @moduletag :capture_log

  @harness "https://code.example.com/acme/harness"
  @app "https://code.example.com/acme/app"
  @team "https://code.example.com/example-org/team-harness"
  @public "https://code.example.com/example-org/public-harness"

  @stack "modules:\n  - name: core\n    source: {path: modules/core}\n"
  @workflows "workflows:\n  triage: {}\n  fix:\n    access: write\n"

  # acme/harness exports the stack `triage`; acme/app has no stack.
  @files %{
    {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage]\n",
    {"R_harness", "stacks/triage/qory-stack.yaml"} => @stack <> @workflows,
    {"R_team", "qory-stack.yaml"} => @stack <> "workflows:\n  review: {}\n"
  }

  setup do
    scope = scope_fixture()
    adapter = call_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
    live_grant_fixture(scope.organisation.id, adapter.adapter, connection, "G_acme")
    harness_collection_fixture(connection, @harness, "acme/harness")
    harness_collection_fixture(connection, @app, "acme/app")

    covered = %{
      adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}, @app => {"G_acme", "R_app"}}
    }

    %{scope: scope, adapter: adapter, connection: connection, covered: covered}
  end

  defp calls do
    receive do
      {:harness_call, path, call} -> [{path, call} | calls()]
    after
      0 -> []
    end
  end

  # The instance's adapter, its grant over `@team`, and the stub over both adapters, with
  # `opts` for the stub.
  defp instance_grant(ctx, opts \\ []) do
    instance = call_adapter_fixture()
    instance_scope = instance_admin_scope()
    {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
    live_grant_fixture(instance_scope.organisation.id, instance.adapter, connection, "G_i")

    covered = Map.put(ctx.covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})
    serve_calls([ctx.adapter, instance], [covered: covered, files: @files] ++ opts)
    instance_scope
  end

  # The public reads among `calls`, in order: `{resource_ref, path, at}`.
  defp public_reads(calls) do
    for {"read-public", call} <- calls,
        do: {call["resource_ref"], call["path"], call["at"]}
  end

  defp assignment(organisation_id, source, by) do
    Repo.insert!(%Assignment{
      organisation_id: organisation_id,
      every_organisation: is_nil(organisation_id),
      source: source,
      created_by_id: by.user.id
    })
  end

  describe "linked repositories" do
    test "only those with a stack, read at HEAD, with their stacks", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)

      assert {:ok, %{sources: [source], unread: 0, left_out: 0}} = Sources.linked(ctx.scope)
      assert %{kind: :linked, label: "acme/harness", git: @harness, ref: "HEAD"} = source
      assert source.version == "c-R_harness"
      assert source.stacks == [%{name: "triage", file: "stacks/triage/qory-stack.yaml"}]

      reads = for {"read", call} <- calls(), do: {call["resource_ref"], call["path"], call["at"]}
      assert {"R_harness", "harness.yaml", "HEAD"} in reads
      assert {"R_app", "qory-stack.yaml", "c-R_app"} in reads
    end

    test "a root qory-stack.yaml with no exports is the stack", ctx do
      files = %{{"R_app", "qory-stack.yaml"} => @stack <> @workflows}
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)

      assert {:ok,
              %{sources: [%{label: "acme/app", stacks: [%{name: nil, file: "qory-stack.yaml"}]}]}} =
               Sources.linked(ctx.scope)
    end

    test "a repository another organisation's grant covers is no source", ctx do
      covered = %{ctx.adapter.adapter.id => %{@harness => {"G_other", "R_harness"}}}
      serve_calls([ctx.adapter], covered: covered, files: @files)

      assert {:ok, %{sources: [], unread: 0}} = Sources.linked(ctx.scope)
    end

    test "an adapter that reaches no one leaves its repositories out, counted", ctx do
      serve_calls([ctx.adapter], down: true)

      assert {:ok, %{sources: [], unread: 2}} = Sources.linked(ctx.scope)
    end

    test "at most 100 are read, the first by title, and the rest counted", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)

      for n <- 1..99 do
        harness_collection_fixture(
          ctx.connection,
          "https://code.example.com/zz/r#{n}",
          "zz/r#{n}"
        )
      end

      assert {:ok, %{sources: [%{label: "acme/harness"}], unread: 0, left_out: 1}} =
               Sources.linked(ctx.scope)

      resolved = for {"resolve", call} <- calls(), address <- call["addresses"], do: address
      assert length(resolved) == 100
      refute "https://code.example.com/zz/r99" in resolved
    end

    test "a person lists them at most twice a minute", ctx do
      serve_calls([ctx.adapter], down: true)

      assert {:ok, _listing} = Sources.linked(ctx.scope)
      assert {:ok, _listing} = Sources.linked(ctx.scope)
      assert {:error, {:limited, seconds}} = Sources.linked(ctx.scope)
      assert seconds in 1..60
      assert {:ok, _listing} = Sources.linked(scope_fixture())
    end

    test "reading one gives its workflows and the base a document extends", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      {:ok, %{sources: [source]}} = Sources.linked(ctx.scope)

      assert {:ok, [stack]} = Sources.read(ctx.scope, source)

      assert stack == %{
               name: "triage",
               base: %{"git" => @harness, "ref" => "HEAD", "stack" => "triage"},
               workflows: ["fix", "triage"]
             }
    end
  end

  describe "assigned sources" do
    test "the organisation's and every organisation's, not a module's nor another organisation's",
         ctx do
      admin = instance_admin_scope()
      other = scope_fixture()
      assignment(ctx.scope.organisation.id, %{"git" => @team, "ref" => "v1"}, admin)
      assignment(nil, %{"git" => @team, "ref" => "v2", "stack" => "web"}, admin)

      assignment(
        ctx.scope.organisation.id,
        %{"git" => @team, "ref" => "v1", "module" => "m"},
        admin
      )

      assignment(other.organisation.id, %{"git" => @team, "ref" => "v3"}, admin)

      assert [
               %{kind: :assigned, ref: "v1", narrowing: %{}} = root,
               %{kind: :assigned, ref: "v2", narrowing: %{"stack" => "web"}} = web
             ] = Sources.assigned(ctx.scope)

      assert root.label == "example-org/team-harness · v1"
      assert web.label == "example-org/team-harness · v2 · web"
    end

    test "one is shown by its repository path, with its ref only where that tells two apart",
         ctx do
      admin = instance_admin_scope()
      assignment(ctx.scope.organisation.id, %{"git" => @team, "ref" => "v1"}, admin)
      assignment(ctx.scope.organisation.id, %{"git" => @harness <> ".git", "ref" => "v1"}, admin)

      assignment(
        ctx.scope.organisation.id,
        %{"git" => "https://other.example.org/acme/harness", "ref" => "v1"},
        admin
      )

      assert [
               "example-org/team-harness",
               "https://code.example.com/acme/harness.git",
               "https://other.example.org/acme/harness"
             ] =
               Enum.map(Sources.assigned(ctx.scope), & &1.label)
    end

    test "one is read through the instance's grant the assignment covers", ctx do
      admin = instance_grant(ctx)
      assignment(ctx.scope.organisation.id, %{"git" => @team, "ref" => "v1"}, admin)
      [source] = Sources.assigned(ctx.scope)

      assert {:ok, [stack]} = Sources.read(ctx.scope, source)

      assert stack == %{
               name: nil,
               base: %{"git" => @team, "ref" => "v1"},
               workflows: ["review"]
             }
    end

    test "a public one is read at its ref as public, with no grant", ctx do
      covered = Map.put(ctx.covered, ctx.adapter.adapter.id, %{@public => {:public, "P_pub"}})
      files = %{{"P_pub", "qory-stack.yaml"} => @stack <> @workflows}
      serve_calls([ctx.adapter], covered: covered, files: files)
      assignment(ctx.scope.organisation.id, %{"git" => @public, "ref" => "v1"}, ctx.scope)
      [source] = Sources.assigned(ctx.scope)

      assert {:ok, [%{base: %{"git" => @public, "ref" => "v1"}, workflows: ["fix", "triage"]}]} =
               Sources.read(ctx.scope, source)

      calls = calls()
      assert [] = for({"read", _call} <- calls, do: :read)
      assert [_ | _] = public = for({"read-public", call} <- calls, do: call)
      assert Enum.all?(public, &(&1["resource_ref"] == "P_pub" and &1["at"] in ["v1", "c-P_pub"]))
      refute Enum.any?(public, &Map.has_key?(&1, "grant_ref"))
    end

    test "one is found past an adapter whose calls fail", ctx do
      admin = instance_grant(ctx, down: [ctx.adapter.adapter.id])
      assignment(ctx.scope.organisation.id, %{"git" => @team, "ref" => "v1"}, admin)
      [source] = Sources.assigned(ctx.scope)

      assert {:ok, [%{workflows: ["review"]}]} = Sources.read(ctx.scope, source)
    end
  end

  describe "an address" do
    test "with a user name or password is refused, and shows neither", _ctx do
      assert {:error, {message, source: shown}} =
               Sources.address("https://deploy:s3cret@code.example.com/acme/harness")

      assert message =~ "remove the user name and password"
      assert shown == "https://code.example.com/acme/harness"
    end

    test "that is not https is refused", _ctx do
      assert {:error, {message, _values}} = Sources.address("http://code.example.com/acme/x")
      assert message =~ "https"
      assert {:error, _blank} = Sources.address("  ")
    end

    test "a linked one is read at HEAD through the organisation's grant", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)

      assert {:ok, %{kind: :address, ref: "HEAD"} = source} = Sources.address(" #{@harness} ")

      assert {:ok, [%{name: "triage", workflows: ["fix", "triage"]}]} =
               Sources.read(ctx.scope, source)
    end

    test "the instance's grant with no assignment, or no grant, is not covered", ctx do
      instance_grant(ctx)

      for git <- [@team, "https://public.example.org/qory/stack"] do
        {:ok, source} = Sources.address(git)
        assert Sources.read(ctx.scope, source) == {:error, :not_covered}
      end
    end

    test "a public one is read at HEAD as public, and a run's walk reads a choice that extends it",
         ctx do
      covered = %{ctx.adapter.adapter.id => %{@public => {:public, "P_pub"}}}
      files = %{{"P_pub", "qory-stack.yaml"} => @stack <> @workflows}
      serve_calls([ctx.adapter], covered: covered, files: files)
      {:ok, source} = Sources.address(@public)

      assert {:ok, [%{name: nil, base: base, workflows: ["fix", "triage"]}]} =
               Sources.read(ctx.scope, source)

      assert base == %{"git" => @public, "ref" => "HEAD"}
      assert [{"P_pub", "harness.yaml", "HEAD"} | _] = public_reads(calls())

      assert {:ok, stored} = Sources.save(ctx.scope, base, "triage")

      {:ok, _choice} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, stored.harness,
          choice: :repository
        )

      input = %{
        organisation: ctx.scope.organisation,
        workspace: ctx.scope.workspace,
        target: nil,
        workflow: "triage"
      }

      assert {:ok, walked} = Walk.run(input)
      assert walked.harness_links == []
      assert walked.pins == [%{"git" => @public, "ref" => "HEAD", "at" => "c-P_pub"}]
    end

    test "a source a grant covers that the rule does not allow is read as public, at its public_ref",
         ctx do
      instance = call_adapter_fixture()
      instance_scope = instance_admin_scope()
      {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
      live_grant_fixture(instance_scope.organisation.id, instance.adapter, connection, "G_i")

      covered = %{instance.adapter.id => %{@team => {"G_i", "R_team", {:public, "P_team"}}}}
      files = %{{"P_team", "qory-stack.yaml"} => @stack <> "workflows:\n  review: {}\n"}
      serve_calls([ctx.adapter, instance], covered: covered, files: files)
      {:ok, source} = Sources.address(@team)

      assert {:ok, [%{workflows: ["review"]}]} = Sources.read(ctx.scope, source)

      calls = calls()
      assert [] = for({"read", _call} <- calls, do: :read)
      assert [_ | _] = reads = public_reads(calls)
      assert Enum.all?(reads, fn {resource_ref, _path, _at} -> resource_ref == "P_team" end)
    end

    test "a link at a later adapter comes before a public result at an earlier one", ctx do
      first = call_adapter_fixture(%{name: "a-public-#{System.unique_integer([:positive])}"})
      assert first.adapter.name < ctx.adapter.adapter.name

      covered =
        Map.put(ctx.covered, first.adapter.id, %{@harness => {:public, "P_harness"}})

      serve_calls([ctx.adapter, first], covered: covered, files: @files)
      {:ok, source} = Sources.address(@harness)

      assert {:ok, [%{name: "triage"}]} = Sources.read(ctx.scope, source)

      calls = calls()
      assert public_reads(calls) == []
      assert [_ | _] = for({"read", %{"grant_ref" => "G_acme"}} <- calls, do: :read)
    end

    test "a person reads sources at most 10 times a minute", ctx do
      serve_calls([ctx.adapter], down: true)
      {:ok, source} = Sources.address(@harness)

      for _n <- 1..10, do: assert(Sources.read(ctx.scope, source) == {:error, :unreadable})
      assert calls() != []

      assert {:error, {:limited, seconds}} = Sources.read(ctx.scope, source)
      assert seconds in 1..60
      assert calls() == []
    end

    test "reads the first 20 stacks its harness file exports", ctx do
      names = for n <- 1..25, do: "s#{n}"

      files =
        Map.new(names, &{{"R_harness", "stacks/#{&1}/qory-stack.yaml"}, @stack <> @workflows})
        |> Map.put(
          {"R_harness", "harness.yaml"},
          "exports:\n  stacks: [#{Enum.join(names, ", ")}]\n"
        )

      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      {:ok, source} = Sources.address(@harness)

      assert {:ok, stacks} = Sources.read(ctx.scope, source)
      assert Enum.sort(Enum.map(stacks, & &1.name)) == Enum.sort(Enum.take(names, 20))
    end

    test "with no stack, and with stacks that cannot be read", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      {:ok, app} = Sources.address(@app)
      assert Sources.read(ctx.scope, app) == {:error, :no_stack}

      files = Map.put(@files, {"R_harness", "stacks/triage/qory-stack.yaml"}, "modules: 7\n")
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      {:ok, harness} = Sources.address(@harness)
      assert Sources.read(ctx.scope, harness) == {:error, :unreadable}
    end
  end

  describe "the save" do
    setup ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      {:ok, %{sources: [source]}} = Sources.linked(ctx.scope)
      {:ok, [stack]} = Sources.read(ctx.scope, source)
      %{base: stack.base}
    end

    test "stores the workspace-level document with the workflow, which sets the runs' workflow and no harness",
         ctx do
      assert {:ok, %Stack{} = stored} = Sources.save(ctx.scope, ctx.base, "triage")

      assert stored.workflow == "triage"
      assert stored.workspace_id == ctx.scope.workspace.id
      assert is_nil(stored.target_id)

      assert stored.harness ==
               "extends:\n  git: \"#{@harness}\"\n  ref: \"HEAD\"\n  stack: \"triage\"\n"

      assert Sources.current(ctx.scope.workspace) == %{workflow: "triage", base: ctx.base}
      assert Stacks.workflow_for(ctx.scope.workspace, nil) == "triage"

      # With no choice, the walk takes the Qory harness, not the row's document.
      input = %{
        organisation: ctx.scope.organisation,
        workspace: ctx.scope.workspace,
        target: nil,
        workflow: "triage"
      }

      qory = ctx.scope.workspace |> Domain.for_workspace() |> Domain.definition()
      assert {:ok, walked} = Walk.run(input)
      assert walked.origin == :setting
      assert walked.stack_id == nil
      assert walked.document == %{"extends" => qory.harness}
    end

    test "another workflow replaces the one before, so the runs have one", ctx do
      {:ok, _first} = Sources.save(ctx.scope, ctx.base, "triage")
      {:ok, _second} = Sources.save(ctx.scope, ctx.base, "fix")

      assert [%Stack{workflow: "fix"}] =
               Repo.all(from s in Stack, where: s.workspace_id == ^ctx.scope.workspace.id)

      assert Stacks.workflow_for(ctx.scope.workspace, nil) == "fix"
    end

    test "a member may not save, and nothing is stored", ctx do
      %{scope: member} = member_fixture(ctx.scope)

      assert Sources.save(member, ctx.base, "triage") == {:error, :forbidden}
      assert Sources.current(ctx.scope.workspace) == nil
    end

    test "no base or no workflow is refused, after the access check", ctx do
      assert Sources.save(ctx.scope, nil, "triage") == {:error, :invalid}
      assert Sources.save(ctx.scope, ctx.base, nil) == {:error, :invalid}
      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.save(member, nil, nil) == {:error, :forbidden}
    end

    test "the save rules refuse a base whose address has a credential", ctx do
      base = %{ctx.base | "git" => "https://deploy:s3cret@code.example.com/acme/harness"}

      assert {:error, %Ecto.Changeset{errors: [harness: {message, _values}]}} =
               Sources.save(ctx.scope, base, "triage")

      assert message =~ "remove the user name and password"
    end
  end

  describe "the shared harness" do
    test "a workspace shows its choice, else the organisation's shared one, else the Qory harness",
         ctx do
      qory = ctx.scope.workspace |> Domain.for_workspace() |> Domain.definition()
      git = qory.harness["git"]
      pin = qory.harness["ref"]

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :qory, git: git, pin: pin, saved: false, shared: false}

      assert {:ok, %Stack{workspace_id: nil, choice: :qory}} =
               Sources.choose(ctx.scope, :qory, shared: true)

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :qory, git: git, pin: pin, saved: true, shared: true}

      assert {:ok, %Stack{workspace_id: workspace_id}} = Sources.choose(ctx.scope, :qory)
      assert workspace_id == ctx.scope.workspace.id

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :qory, git: git, pin: pin, saved: true, shared: false}
    end

    test "a share removes the workspace's choice, so the workspace takes the shared one",
         ctx do
      {:ok, _choice} = Sources.choose(ctx.scope, :qory)
      assert {:ok, shared} = Sources.choose(ctx.scope, :qory, shared: true)

      assert Stacks.choice(ctx.scope.workspace) == nil
      assert Stacks.shared(ctx.scope.organisation).id == shared.id
    end

    test "a second share is refused while the organisation shares one, from any workspace",
         ctx do
      {:ok, shared} = Sources.choose(ctx.scope, :qory, shared: true)
      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      {:ok, _choice} = Sources.choose(other, :qory)

      assert Sources.choose(ctx.scope, :qory, shared: true) == {:error, :shared}
      assert Sources.choose(other, :qory, shared: true) == {:error, :shared}

      assert [%Stack{id: id}] =
               Repo.all(from s in Stack, where: is_nil(s.workspace_id) and not is_nil(s.choice))

      assert id == shared.id
      assert %Stack{} = Stacks.choice(other.workspace)
    end

    test "a member shares nothing", ctx do
      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.choose(member, :qory, shared: true) == {:error, :forbidden}
      assert Stacks.shared(ctx.scope.organisation) == nil
    end

    test "shared/1 is the organisation's shared harness, as a reusing workspace shows it; nil for none",
         ctx do
      assert Sources.shared(ctx.scope.organisation) == nil
      {:ok, _shared} = Sources.choose(ctx.scope, :qory, shared: true)
      {:ok, _choice} = Sources.choose(ctx.scope, :qory)

      assert %{choice: :qory, saved: true, shared: true} =
               Sources.shared(ctx.scope.organisation)
    end

    test "reuse_shared/1 removes the workspace's choice, so the workspace takes the shared one",
         ctx do
      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      {:ok, shared} = Sources.choose(ctx.scope, :qory, shared: true)
      {:ok, _choice} = Sources.choose(other, :qory)

      assert {:ok, %Stack{id: id}} = Sources.reuse_shared(other)
      assert id == shared.id
      assert Stacks.choice(other.workspace) == nil
      assert %{shared: true} = Sources.chosen(other.workspace)

      # A workspace with no choice reuses the shared one already.
      assert {:ok, %Stack{id: ^id}} = Sources.reuse_shared(other)
    end

    test "reuse_shared/1 removes nothing while the organisation shares none, or for a member",
         ctx do
      {:ok, choice} = Sources.choose(ctx.scope, :qory)
      assert Sources.reuse_shared(ctx.scope) == {:error, :not_shared}
      assert Stacks.choice(ctx.scope.workspace).id == choice.id

      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))
      {:ok, _shared} = Sources.choose(other, :qory, shared: true)

      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.reuse_shared(member) == {:error, :forbidden}
      assert Stacks.choice(ctx.scope.workspace).id == choice.id
    end
  end

  describe "a target's stack" do
    @pin String.duplicate("c3", 20)
    @target %{system: "code.example.com", path: "acme/app"}

    # acme/app as a destination of the workspace, at `@target`.
    setup ctx do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^ctx.adapter.adapter.id),
          set: [targets: true]
        )

      {1, _} =
        Repo.update_all(from(c in Apiary.Adapters.Collection, where: c.url == @app),
          set: [
            workspace_id: ctx.scope.workspace.id,
            target_system: @target.system,
            target_path: @target.path
          ]
        )

      :ok
    end

    defp walk_input(ctx) do
      %{
        organisation: ctx.scope.organisation,
        workspace: ctx.scope.workspace,
        target: @target,
        workflow: "triage"
      }
    end

    test "a stack of a linked source is pinned at the commit of the ref given, creates the target's row, and the walk reads it, not the target's file",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files:
          Map.put(
            @files,
            {"R_app", "harness.yaml"},
            "harness:\n  extends: {git: \"#{@harness}\", ref: v1, stack: triage}\n"
          ),
        versions: %{"R_harness" => @pin}
      )

      {:ok, %{sources: [source]}} = Sources.linked(ctx.scope)
      {:ok, [stack]} = Sources.read(ctx.scope, source)
      refute Repo.exists?(Target)
      calls()

      assert {:ok, %Stack{choice: :repository} = row} =
               Sources.choose_target(ctx.scope, @target, {:stack, source, stack, " main "})

      assert row.harness ==
               "extends:\n  git: \"#{@harness}\"\n  ref: \"#{@pin}\"\n  stack: \"triage\"\n"

      assert {"R_harness", "harness.yaml", "main"} in for(
               {"read", call} <- calls(),
               do: {call["resource_ref"], call["path"], call["at"]}
             )

      assert %Target{id: target_id} = Repo.get_by!(Target, path: @target.path)
      assert row.target_id == target_id

      assert Sources.targets_chosen(ctx.scope.workspace) == %{
               {@target.system, @target.path} => %{
                 choice: :repository,
                 git: @harness,
                 narrowing: %{"stack" => "triage"},
                 pin: @pin
               }
             }

      calls()
      assert {:ok, walked} = Walk.run(walk_input(ctx))
      assert %{origin: :setting, target_version: nil} = walked
      assert walked.stack_id == row.id

      refute Enum.any?(calls(), fn {path, call} ->
               path == "read" and call["resource_ref"] == "R_app"
             end)
    end

    test "the Qory harness is saved with no read, and the walk reads no target's file", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      qory = ctx.scope.workspace |> Domain.for_workspace() |> Domain.definition()

      assert {:ok, %Stack{choice: :qory} = row} =
               Sources.choose_target(ctx.scope, @target, :qory)

      assert calls() == []

      assert %{choice: :qory, git: git, narrowing: %{"stack" => _}, pin: pin} =
               Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]

      assert {git, pin} == {qory.harness["git"], qory.harness["ref"]}

      assert {:ok, %{stack_id: stack_id, target_version: nil}} = Walk.run(walk_input(ctx))
      assert stack_id == row.id
    end

    test "a stack of an assigned source keeps the assignment's ref, and is still read",
         ctx do
      admin = instance_grant(ctx, versions: %{"R_team" => @pin})
      assignment(ctx.scope.organisation.id, %{"git" => @team, "ref" => "v1"}, admin)
      [source] = Sources.assigned(ctx.scope)
      {:ok, [stack]} = Sources.read(ctx.scope, source)
      calls()

      assert {:ok, row} =
               Sources.choose_target(ctx.scope, @target, {:stack, source, stack, "main"})

      assert row.harness == "extends:\n  git: \"#{@team}\"\n  ref: \"v1\"\n"

      assert [_ | _] =
               for({"read", %{"resource_ref" => "R_team", "at" => "v1"}} <- calls(), do: :read)

      assert {:ok, %{harness_links: [%{"grant_ref" => "G_i"}]}} = Walk.run(walk_input(ctx))
    end

    test "a stack that cannot be read is refused with the walk's reason, and nothing is saved",
         ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      {:ok, %{sources: [source]}} = Sources.linked(ctx.scope)
      {:ok, [stack]} = Sources.read(ctx.scope, source)

      # The version the read returned, c-R_harness, is no full commit id.
      assert {:error, {:walk, %{failure: :invalid}}} =
               Sources.choose_target(ctx.scope, @target, {:stack, source, stack, "main"})

      assert Sources.choose_target(ctx.scope, @target, {:stack, source, nil, "main"}) ==
               {:error, :invalid}

      assert Sources.targets_chosen(ctx.scope.workspace) == %{}
    end

    test "a target that is no destination of the workspace is refused", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))

      for {scope, target} <- [
            {ctx.scope, %{system: "code.example.com", path: "acme/harness"}},
            {ctx.scope, %{system: "elsewhere.example.com", path: "acme/app"}},
            {other, @target}
          ] do
        assert Sources.choose_target(scope, target, :qory) == {:error, :not_found}
      end

      assert Sources.choose_target(ctx.scope, nil, :qory) == {:error, :not_found}
      refute Repo.exists?(Stack)
      refute Repo.exists?(Target)
    end

    test ":default removes the target's stack, and takes no target with none", ctx do
      {:ok, _row} = Sources.choose_target(ctx.scope, @target, :qory)

      assert Sources.choose_target(ctx.scope, @target, :default) == {:ok, nil}
      assert Sources.targets_chosen(ctx.scope.workspace) == %{}
      assert Stacks.target_choice(ctx.scope.workspace, @target) == nil

      assert Sources.choose_target(ctx.scope, @target, :default) == {:ok, nil}
    end

    test "a member chooses nothing", ctx do
      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.choose_target(member, @target, :qory) == {:error, :forbidden}
      refute Repo.exists?(Stack)
    end
  end
end
