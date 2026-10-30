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

  describe "connected repositories" do
    test "each address once, by name, with no call", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      harness_collection_fixture(ctx.connection, @harness, "acme/harness again")
      other = scope_fixture()
      {other_connection, _nonce} = connection_fixture(other, ctx.adapter.adapter, :listed)
      harness_collection_fixture(other_connection, @team, "example-org/team-harness")

      assert [
               %{kind: :linked, label: "acme/app", git: @app, ref: "HEAD", narrowing: %{}},
               %{kind: :linked, label: "acme/harness", git: @harness, location: nil}
             ] = Sources.repositories(ctx.scope)

      assert calls() == []
    end

    test "the stacks one exports, read at its ref; none is an answer", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      [app, harness] = Sources.repositories(ctx.scope)

      assert Sources.exports(ctx.scope, harness) == {:ok, ["triage"]}

      assert for({"read", call} <- calls(), do: {call["resource_ref"], call["path"], call["at"]}) ==
               [{"R_harness", "harness.yaml", "HEAD"}, {"R_harness", "qory.yaml", "c-R_harness"}]

      assert Sources.exports(ctx.scope, app) == {:ok, []}

      # A root qory-stack.yaml with no exports exports no stack.
      files = %{{"R_app", "qory-stack.yaml"} => @stack <> @workflows}
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      assert Sources.exports(ctx.scope, app) == {:ok, []}
    end

    test "both root harness files, or exports that do not read, are invalid, with the file and the walk's rule",
         ctx do
      files = %{
        {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage]\n",
        {"R_harness", "qory.yaml"} => "exports:\n  stacks: [triage]\n",
        {"R_app", "qory.yaml"} => "exports: [triage\n"
      }

      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      [app, harness] = Sources.repositories(ctx.scope)

      assert Sources.exports(ctx.scope, harness) ==
               {:error, {:invalid, "harness.yaml", %{"rule" => "both_files", "values" => %{}}}}

      assert Sources.exports(ctx.scope, app) ==
               {:error, {:invalid, "qory.yaml", Walk.yaml_rule("qory.yaml", :invalid_yaml)}}
    end

    test "exports that are not valid are an invalid section of the file", ctx do
      files = %{{"R_app", "qory.yaml"} => "exports: 7\n"}
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      [app, _harness] = Sources.repositories(ctx.scope)

      assert Sources.exports(ctx.scope, app) ==
               {:error, {:invalid_section, "qory.yaml", :exports}}
    end

    test "a failed call has the adapter's shown name and its cause, with no address", ctx do
      [_app, harness] = Sources.repositories(ctx.scope)
      title = Apiary.Adapters.title(ctx.adapter.adapter)

      serve_calls([ctx.adapter], covered: ctx.covered, files: @files, down: true)

      assert Sources.exports(ctx.scope, harness) ==
               {:error,
                {:call,
                 %{adapter: title, cause: :unreachable, code: nil, seconds: nil, refusal: nil}}}

      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        refuse_at: %{"HEAD" => "internal"}
      )

      refused =
        {:call, %{adapter: title, cause: :refused, code: "internal", seconds: nil, refusal: nil}}

      assert Sources.exports(ctx.scope, harness) == {:error, refused}
      assert Sources.read(ctx.scope, harness) == {:error, refused}
    end

    test "a refusal a run's walk takes as a version not found, a file that is not text or a source not covered is that",
         ctx do
      [_app, harness] = Sources.repositories(ctx.scope)

      # Version not found at HEAD: a repository with no commit.
      for {code, reason} <- [
            {"version_not_found", :no_commit},
            {"document_not_text", {:not_text, "harness.yaml"}},
            {"resource_not_covered", :not_covered},
            {"grant_unknown", :not_covered}
          ] do
        serve_calls([ctx.adapter],
          covered: ctx.covered,
          files: @files,
          refuse_at: %{"HEAD" => code}
        )

        assert Sources.exports(ctx.scope, harness) == {:error, reason}
      end
    end

    test "a read out of time has the read's seconds; a call with no answer has the call's" do
      adapter = %Node{kind: :adapter, name: "code-host", title: "Code host"}

      assert Sources.call(adapter, :late, 30) ==
               %{adapter: "Code host", cause: :late, code: nil, seconds: 30, refusal: nil}

      assert Sources.call(adapter, :timeout, 10) ==
               %{adapter: "Code host", cause: :timeout, code: nil, seconds: 10, refusal: nil}

      failure = %Apiary.Adapters.CallFailure{
        adapter_id: Ecto.UUID.generate(),
        adapter_public_id: "qn_1",
        adapter_name: "code-host",
        path: "read",
        cause: :refused,
        code: "unauthorized",
        status: 401
      }

      assert %{cause: :unauthorized, code: nil} = Sources.call(adapter, failure, 10)

      # A refused address keeps its kind, and no IP.
      for {refusal, kept} <- [
            {{:address, {169, 254, 169, 254}, :metadata}, {:address, :metadata}},
            {:form, :form},
            {:public_host, :public_host}
          ] do
        not_allowed = %{failure | cause: :not_allowed, code: nil, status: nil, refusal: refusal}

        assert Sources.call(adapter, not_allowed, 10) ==
                 %{
                   adapter: "Code host",
                   cause: :not_allowed,
                   code: nil,
                   seconds: nil,
                   refusal: kept
                 }
      end
    end

    test "an adapter whose call address Qory Apiary does not call lists no repository, and is unplaced",
         ctx do
      assert Sources.unplaced(ctx.scope) == []

      other = call_adapter_fixture()
      {connection, _nonce} = connection_fixture(ctx.scope, other.adapter, :listed)
      harness_collection_fixture(connection, @team, "example-org/team-harness")
      title = Apiary.Adapters.title(other.adapter)

      for {call_url, instance_id, cause} <- [
            {nil, nil, :no_address},
            {"https://code-host.example.org/calls/", "instance-1", :not_placed}
          ] do
        {1, _} =
          Repo.update_all(from(n in Node, where: n.id == ^other.adapter.id),
            set: [call_url: call_url, call_instance_id: instance_id]
          )

        assert Enum.map(Sources.repositories(ctx.scope), & &1.label) == [
                 "acme/app",
                 "acme/harness"
               ]

        assert Sources.unplaced(ctx.scope) == [
                 %{id: other.adapter.public_id, adapter: title, cause: cause}
               ]
      end

      # An instance whose public address has no host calls no adapter: each adapter with
      # a call address is unplaced for that.
      unplaced =
        Enum.sort_by(
          [
            %{
              id: ctx.adapter.adapter.public_id,
              adapter: Apiary.Adapters.title(ctx.adapter.adapter),
              cause: :no_instance_host
            },
            %{id: other.adapter.public_id, adapter: title, cause: :no_instance_host}
          ],
          &String.downcase(&1.adapter)
        )

      for host <- [nil, ""] do
        assert Sources.unplaced(ctx.scope, instance_host: host) == unplaced
      end
    end

    test "one another organisation's grant covers is not covered; reads count toward the limit",
         ctx do
      covered = %{ctx.adapter.adapter.id => %{@harness => {"G_other", "R_harness"}}}
      serve_calls([ctx.adapter], covered: covered, files: @files)
      [_app, harness] = Sources.repositories(ctx.scope)

      assert Sources.exports(ctx.scope, harness) == {:error, :not_covered}
      for _n <- 2..10, do: Sources.exports(ctx.scope, harness)
      assert {:error, {:limited, _seconds}} = Sources.exports(ctx.scope, harness)
    end

    test "reading one gives its workflows and the base a document extends", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      [_app, source] = Sources.repositories(ctx.scope)

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

      title = Apiary.Adapters.title(ctx.adapter.adapter)

      unreachable =
        {:call, %{adapter: title, cause: :unreachable, code: nil, seconds: nil, refusal: nil}}

      for _n <- 1..10, do: assert(Sources.read(ctx.scope, source) == {:error, unreachable})

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

      file = "stacks/triage/qory-stack.yaml"
      files = Map.put(@files, {"R_harness", file}, "modules: 7\n")
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      {:ok, harness} = Sources.address(@harness)
      assert Sources.read(ctx.scope, harness) == {:error, {:invalid_section, file, :stack}}

      files = Map.put(@files, {"R_harness", file}, "modules: [core\n")
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)

      assert Sources.read(ctx.scope, harness) ==
               {:error, {:invalid, file, Walk.yaml_rule(file, :invalid_yaml)}}
    end

    test "a listed stack and a folder with no stack file have that file missing; a stack name not exported is not exported",
         ctx do
      files = Map.delete(@files, {"R_harness", "stacks/triage/qory-stack.yaml"})
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      {:ok, harness} = Sources.address(@harness)

      assert Sources.read(ctx.scope, harness) ==
               {:error, {:no_stack_file, "stacks/triage/qory-stack.yaml"}}

      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      folder = %{harness | narrowing: %{"path" => "stacks/web"}}

      assert Sources.read(ctx.scope, folder) ==
               {:error, {:no_stack_file, "stacks/web/qory-stack.yaml"}}

      unexported = %{harness | narrowing: %{"stack" => "web"}}
      assert Sources.read(ctx.scope, unexported) == {:error, {:no_export, "web"}}
    end

    test "stacks listed at no path a read takes, a folder and a version a read does not take",
         ctx do
      files = %{{"R_harness", "harness.yaml"} => "exports:\n  dir: ../out\n  stacks: [triage]\n"}
      serve_calls([ctx.adapter], covered: ctx.covered, files: files)
      {:ok, harness} = Sources.address(@harness)

      assert Sources.read(ctx.scope, harness) ==
               {:error,
                {:stack_path, "harness.yaml", "triage", "../out/stacks/triage/qory-stack.yaml"}}

      folder = %{harness | narrowing: %{"path" => "../out"}}

      assert Sources.read(ctx.scope, folder) ==
               {:error, {:unreadable, :path, "../out/qory-stack.yaml"}}

      assert Sources.read(ctx.scope, %{harness | ref: "a b"}) ==
               {:error, {:unreadable, :version, "a b"}}
    end
  end

  describe "the save" do
    setup ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      [_app, source] = Sources.repositories(ctx.scope)
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

      qory_chosen = %{choice: :qory, git: git, stack: "core", version: :latest, pin: pin}

      assert Sources.chosen(ctx.scope.workspace) ==
               Map.merge(qory_chosen, %{saved: false, shared: false})

      assert {:ok, %Stack{workspace_id: nil, choice: :qory}} =
               Sources.choose(ctx.scope, :qory, shared: true)

      assert Sources.chosen(ctx.scope.workspace) ==
               Map.merge(qory_chosen, %{saved: true, shared: true})

      assert {:ok, %Stack{workspace_id: workspace_id}} = Sources.choose(ctx.scope, :qory)
      assert workspace_id == ctx.scope.workspace.id

      assert Sources.chosen(ctx.scope.workspace) ==
               Map.merge(qory_chosen, %{saved: true, shared: false})
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

    test "a stack of a connected repository is pinned at the commit of the ref given, creates the target's row, and the walk reads the target's file first",
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

      [_app, source] = Sources.repositories(ctx.scope)
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
                 stack: "triage",
                 version: nil,
                 pin: @pin
               }
             }

      # The target's file extends a stack, so it applies over the target's stack.
      calls()
      assert {:ok, %{origin: :file, stack_id: nil}} = Walk.run(walk_input(ctx))

      assert {"R_app", "harness.yaml", "HEAD"} in for(
               {"read", call} <- calls(),
               do: {call["resource_ref"], call["path"], call["at"]}
             )

      # With no file, the target's stack, with the target's version.
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      assert {:ok, walked} = Walk.run(walk_input(ctx))
      assert %{origin: :setting, target_version: "c-R_app"} = walked
      assert walked.stack_id == row.id
    end

    test "the Qory harness is saved with no read, at latest, and the walk reads the target's file first",
         ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      qory = ctx.scope.workspace |> Domain.for_workspace() |> Domain.definition()

      assert {:ok, %Stack{choice: :qory} = row} =
               Sources.choose_target(ctx.scope, @target, :qory)

      assert calls() == []

      assert %{choice: :qory, git: git, stack: "core", version: :latest, pin: pin} =
               Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]

      assert {git, pin} == {qory.harness["git"], qory.harness["ref"]}

      assert {:ok, %{stack_id: stack_id, target_version: "c-R_app"}} = Walk.run(walk_input(ctx))
      assert stack_id == row.id

      assert {"R_app", "harness.yaml", "HEAD"} in for(
               {"read", c} <- calls(),
               do: {c["resource_ref"], c["path"], c["at"]}
             )
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
      [_app, source] = Sources.repositories(ctx.scope)
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

    test "a stack of the workspace's harness follows its version; a change of repository keeps the version it followed",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      qory = Apiary.Lingo.Domain.Definition.qory_harness()
      [_app, harness] = Sources.repositories(ctx.scope)

      chosen = fn ->
        Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]
      end

      # Under the Qory harness: a stack the release lists, with no read.
      calls()
      assert Sources.choose_target(ctx.scope, @target, {:workspace, "nope"}) == {:error, :invalid}

      assert {:ok, %Stack{choice: :qory, version_kind: :workspace}} =
               Sources.choose_target(ctx.scope, @target, {:workspace, "core"})

      assert calls() == []
      assert %{stack: "core", version: :workspace, pin: pin} = chosen.()
      assert pin == qory.latest

      # The workspace takes a harness repository: the row keeps the Qory harness at latest.
      {:ok, _choice} =
        Sources.choose(ctx.scope, {:repository, harness, "triage", {:branch, "main"}})

      assert %{choice: :qory, stack: "core", version: :latest, pin: ^pin} = chosen.()

      # A stack of the harness repository follows its branch, then its tag.
      assert {:ok, %Stack{choice: :repository, version_kind: :workspace}} =
               Sources.choose_target(ctx.scope, @target, {:workspace, "triage"})

      assert %{git: @harness, stack: "triage", version: :workspace, pin: "main"} = chosen.()

      {:ok, _choice} = Sources.choose(ctx.scope, {:repository, harness, "triage", {:tag, "v1"}})
      assert %{version: :workspace, pin: "v1"} = chosen.()

      assert {:ok, walked} = Walk.run(walk_input(ctx))

      assert walked.document["extends"] == %{
               "git" => @harness,
               "ref" => "v1",
               "stack" => "triage"
             }

      # The workspace takes the Qory harness again: the row keeps the tag it followed.
      {:ok, _choice} = Sources.choose(ctx.scope, :qory)
      assert %{choice: :repository, stack: "triage", version: {:tag, "v1"}, pin: "v1"} = chosen.()

      row = Stacks.target_choice(ctx.scope.workspace, @target)

      assert row.harness ==
               "extends:\n  git: \"#{@harness}\"\n  ref: \"v1\"\n  stack: \"triage\"\n"
    end

    test "a share or a reuse of the shared harness keeps the version a row followed", ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)
      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))

      chosen = fn ->
        Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]
      end

      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "core"})

      # Another workspace shares a harness repository; this workspace has no choice, so
      # it takes the shared one, and the row keeps the Qory harness at latest.
      {:ok, _shared} =
        Sources.choose(other, {:repository, harness, "triage", {:branch, "main"}}, shared: true)

      assert %{choice: :qory, version: :latest} = chosen.()

      # Following the shared harness repository, then the workspace's Qory harness, then
      # the shared one again.
      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "triage"})
      assert %{version: :workspace, pin: "main"} = chosen.()
      {:ok, _choice} = Sources.choose(ctx.scope, :qory)
      assert %{choice: :repository, version: {:branch, "main"}} = chosen.()

      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "core"})
      {:ok, _shared} = Sources.reuse_shared(ctx.scope)
      assert %{choice: :qory, version: :latest} = chosen.()
    end

    test "a reuse of the shared harness while the workspace has no choice keeps a row following it",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)
      other = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))

      {:ok, _shared} =
        Sources.choose(other, {:repository, harness, "triage", {:branch, "main"}}, shared: true)

      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "triage"})

      # Two pages of the workspace reuse the shared harness, which it already takes.
      {:ok, _shared} = Sources.reuse_shared(ctx.scope)
      {:ok, _shared} = Sources.reuse_shared(ctx.scope)

      assert %{git: @harness, stack: "triage", version: :workspace, pin: "main"} =
               Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]

      assert {:ok, walked} = Walk.run(walk_input(ctx))
      assert walked.document["extends"]["git"] == @harness
    end

    test "a harness repository shared in place of the shared Qory harness: each workspace with no choice takes it, and its rows follow the three cases",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)
      organisation = ctx.scope.organisation
      sharing = workspace_scope(ctx.scope.user, workspace_fixture(organisation))
      saved = workspace_scope(ctx.scope.user, workspace_fixture(organisation))

      {:ok, qory} = Sources.choose(ctx.scope, :qory, shared: true)
      {:ok, choice} = Sources.choose(saved, :qory)

      # Main, the workspace of ctx.scope, takes the shared Qory harness. Three of its
      # targets follow its harness: one a stack of the Qory harness, one of acme/harness
      # and one of acme/other.
      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "core"})

      follow = fn path, choice, git ->
        workspace = ctx.scope.workspace
        target = %{system: @target.system, path: path}
        :ok = Target.insert_new(organisation.id, workspace.id, [target])
        row = Repo.get_by!(Target, workspace_id: workspace.id, path: path)
        document = "extends:\n  git: \"#{git}\"\n  ref: \"v1\"\n  stack: \"triage\"\n"

        {:ok, _row} =
          Stacks.put_stack(ctx.scope, {:target, row}, document,
            choice: choice,
            version: {:workspace, nil}
          )

        document
      end

      follow.("acme/one", :repository, @harness)
      other = follow.("acme/two", :repository, "https://code.example.com/acme/other")

      assert {:ok, %Stack{id: id, choice: :repository}} =
               Sources.choose(sharing, {:repository, harness, "triage", {:branch, "main"}},
                 shared: true
               )

      assert id == qory.id

      assert [%Stack{id: ^id}] =
               Repo.all(from s in Stack, where: is_nil(s.workspace_id) and not is_nil(s.choice))

      # Main and the workspace that shares take acme/harness; the workspace with a saved
      # choice keeps it.
      for scope <- [ctx.scope, sharing] do
        assert Stacks.choice(scope.workspace) == nil

        assert %{
                 choice: :repository,
                 git: @harness,
                 stack: "triage",
                 version: {:branch, "main"},
                 shared: true
               } = Sources.chosen(scope.workspace)
      end

      assert Stacks.choice(saved.workspace).id == choice.id
      assert %{choice: :qory, shared: false} = Sources.chosen(saved.workspace)

      chosen = Sources.targets_chosen(ctx.scope.workspace)

      # The stack of the Qory harness keeps the version it followed; the stack of
      # acme/harness follows the shared branch; the stack of acme/other keeps its
      # document, with no version.
      assert %{choice: :qory, stack: "core", version: :latest} =
               chosen[{@target.system, @target.path}]

      assert %{git: @harness, stack: "triage", version: :workspace, pin: "main"} =
               chosen[{@target.system, "acme/one"}]

      assert %{version: nil, pin: "v1"} = chosen[{@target.system, "acme/two"}]

      assert Stacks.target_choice(ctx.scope.workspace, %{@target | path: "acme/two"}).harness ==
               other

      # A share while the organisation shares a harness repository is refused.
      assert Sources.choose(saved, {:repository, harness, "triage", {:tag, "v1"}}, shared: true) ==
               {:error, :shared}

      assert Sources.choose(saved, :qory, shared: true) == {:error, :shared}
      assert Stacks.shared(organisation).id == id
      assert Stacks.choice(saved.workspace).id == choice.id
    end

    test "a row following a harness the workspace no longer takes reads its document's ref",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)

      {:ok, _choice} =
        Sources.choose(ctx.scope, {:repository, harness, "triage", {:tag, "v1"}})

      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "triage"})

      # The workspace's choice goes with no update of the row, as when a save of the
      # workspace's harness ends while the row's save reads: the workspace takes the Qory
      # harness, and the row still follows the harness repository.
      Repo.delete!(Stacks.choice(ctx.scope.workspace))
      row = Stacks.target_choice(ctx.scope.workspace, @target)
      assert row.version_kind == :workspace

      assert Stacks.version_ref(row, ctx.scope.workspace, ctx.scope.organisation) == "v1"

      assert %{git: @harness, version: :workspace, pin: "v1"} =
               Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]

      assert {:ok, walked} = Walk.run(walk_input(ctx))

      assert walked.document["extends"] == %{
               "git" => @harness,
               "ref" => "v1",
               "stack" => "triage"
             }
    end

    test "a change of the workspace's harness leaves a row of the new harness following it",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)

      {:ok, _choice} =
        Sources.choose(ctx.scope, {:repository, harness, "triage", {:tag, "v1"}})

      {:ok, _row} = Sources.choose_target(ctx.scope, @target, {:workspace, "triage"})

      # The workspace's choice goes with no update of the row, as a save of the row that
      # ends while the workspace changes harness leaves it; then the workspace takes the
      # same repository on a branch.
      Repo.delete!(Stacks.choice(ctx.scope.workspace))

      {:ok, _choice} =
        Sources.choose(ctx.scope, {:repository, harness, "triage", {:branch, "main"}})

      assert %{git: @harness, stack: "triage", version: :workspace, pin: "main"} =
               Sources.targets_chosen(ctx.scope.workspace)[{@target.system, @target.path}]

      # A row of another repository, neither the old harness nor the new one, keeps its
      # document as written, with no version.
      other =
        "extends:\n  git: \"https://code.example.com/acme/other\"\n" <>
          "  ref: \"v1\"\n  stack: \"triage\"\n"

      {1, _rows} =
        Repo.update_all(
          from(s in Stack, where: s.version_kind == :workspace),
          set: [harness: other]
        )

      {:ok, _choice} = Sources.choose(ctx.scope, :qory)

      row = Stacks.target_choice(ctx.scope.workspace, @target)
      assert {row.choice, row.version_kind, row.version_name} == {:repository, nil, nil}
      assert row.harness == other
    end

    test "a member chooses nothing", ctx do
      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.choose_target(member, @target, :qory) == {:error, :forbidden}
      refute Repo.exists?(Stack)
    end
  end

  describe "versions" do
    @pin String.duplicate("c3", 20)
    @later String.duplicate("d4", 20)

    defp no_target(ctx),
      do: %{
        organisation: ctx.scope.organisation,
        workspace: ctx.scope.workspace,
        target: nil,
        workflow: "triage"
      }

    test "the latest on a branch: stored by name, read when each run starts, and each run records the commit",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)

      assert {:ok, %Stack{version_kind: :branch, version_name: "main"} = row} =
               Sources.choose(ctx.scope, {:repository, harness, "triage", {:branch, " main "}})

      assert row.harness ==
               "extends:\n  git: \"#{@harness}\"\n  ref: \"main\"\n  stack: \"triage\"\n"

      assert %{git: @harness, stack: "triage", version: {:branch, "main"}, pin: "main"} =
               Sources.chosen(ctx.scope.workspace)

      assert {:ok, walked} = Walk.run(no_target(ctx))
      assert walked.document["extends"]["ref"] == "main"
      assert %{"git" => @harness, "ref" => "main", "at" => @pin} in walked.pins

      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @later}
      )

      assert {:ok, walked} = Walk.run(no_target(ctx))
      assert %{"git" => @harness, "ref" => "main", "at" => @later} in walked.pins
    end

    test "a fixed version: a tag by its name, a commit by its full id", ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin}
      )

      [_app, harness] = Sources.repositories(ctx.scope)

      assert {:ok, %Stack{version_kind: :tag, version_name: "v1"} = tag} =
               Sources.choose(ctx.scope, {:repository, harness, "triage", {:tag, "v1"}})

      assert tag.harness =~ ~s(ref: "v1")
      assert %{version: {:tag, "v1"}, pin: "v1"} = Sources.chosen(ctx.scope.workspace)

      reads = for {"read", call} <- calls(), do: {call["resource_ref"], call["path"], call["at"]}
      assert {"R_harness", "harness.yaml", "v1"} in reads

      assert {:ok, %Stack{version_kind: :commit, version_name: @pin} = commit} =
               Sources.choose(ctx.scope, {:repository, harness, "triage", {:commit, @pin}})

      assert commit.harness =~ ~s(ref: "#{@pin}")
      assert %{version: {:commit, @pin}, pin: @pin} = Sources.chosen(ctx.scope.workspace)

      reads = for {"read", call} <- calls(), do: {call["resource_ref"], call["path"], call["at"]}
      assert {"R_harness", "harness.yaml", @pin} in reads

      # A short id is no commit a fixed version takes.
      assert Sources.choose(ctx.scope, {:repository, harness, "triage", {:commit, "c3c3c3c"}}) ==
               {:error, :invalid}
    end

    test "the save checks the name with read: one it does not find is refused, and nothing is saved",
         ctx do
      serve_calls([ctx.adapter],
        covered: ctx.covered,
        files: @files,
        versions: %{"R_harness" => @pin},
        refuse_at: %{"no-such" => "version_not_found"}
      )

      [_app, harness] = Sources.repositories(ctx.scope)

      for version <- [{:branch, "no-such"}, {:tag, "no-such"}] do
        assert {:error, {:walk, %{failure: :invalid, rule: rule}}} =
                 Sources.choose(ctx.scope, {:repository, harness, "triage", version})

        assert rule == %{"rule" => "version", "values" => %{"ref" => "no-such"}}
      end

      # A stack the repository does not export, and no stack or no name.
      assert {:error, {:walk, %{failure: :invalid, rule: %{"rule" => "no_export"}}}} =
               Sources.choose(ctx.scope, {:repository, harness, "web", {:branch, "main"}})

      for choice <- [
            {:repository, harness, "", {:branch, "main"}},
            {:repository, harness, "triage", {:branch, " "}},
            {:repository, harness, "triage", {:pinned, "main"}}
          ] do
        assert Sources.choose(ctx.scope, choice) == {:error, :invalid}
      end

      assert Stacks.choice(ctx.scope.workspace) == nil
    end

    test "the Qory harness: latest with no version stored, and only a name the release ships",
         ctx do
      qory = Apiary.Lingo.Domain.Definition.qory_harness()
      assert qory.named == []

      assert {:ok, %Stack{version_kind: :latest, version_name: nil}} =
               Sources.choose(ctx.scope, {:qory, :latest})

      assert %{version: :latest, pin: pin, stack: "core"} = Sources.chosen(ctx.scope.workspace)
      assert pin == qory.latest
      assert Sources.choose(ctx.scope, {:qory, "v1"}) == {:error, :invalid}
    end

    test "a run at a named version the release no longer ships fails invalid", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      qory = ctx.scope.workspace |> Domain.for_workspace() |> Domain.definition()
      {:ok, _row} = Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "triage"}, nil)

      document =
        "extends:\n  git: \"#{qory.harness["git"]}\"\n  ref: \"#{qory.harness["ref"]}\"\n" <>
          "  stack: \"core\"\n"

      {:ok, _row} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document,
          choice: :qory,
          version: {:named, "v0.1"}
        )

      assert {:failed, %{failure: :invalid, rule: rule}} = Walk.run(no_target(ctx))
      assert rule == %{"rule" => "version", "values" => %{"ref" => "v0.1"}}
    end

    test "the row's check: each version under its choice, with its name", ctx do
      document = "extends: {git: \"#{@harness}\", ref: main}\n"

      for {choice, version} <- [
            {:repository, {:latest, nil}},
            {:qory, {:branch, "main"}},
            {:repository, {:branch, nil}},
            {:qory, {:latest, "main"}},
            {:repository, {:workspace, nil}},
            {nil, {:branch, "main"}}
          ] do
        assert {:error, %Ecto.Changeset{errors: errors}} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document,
                   choice: choice,
                   version: version
                 )

        assert {"is invalid", _} = errors[:version_kind]
      end
    end
  end
end
