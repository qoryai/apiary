defmodule Apiary.Stacks.SourcesTest do
  # The harness sources Workspace settings › Workflow offers (`Apiary.Stacks.Sources`),
  # read through stub adapters (`Req.Test`): the linked repositories that have a stack,
  # the instance's assignments, a typed address and its refusals, the stacks and
  # workflows each has, and the save, whose document a run's walk then finds.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Harnesses.{Assignment, Walk}
  alias Apiary.Stacks
  alias Apiary.Stacks.{Sources, Stack}

  @moduletag needs: :factory
  @moduletag :capture_log

  @harness "https://code.example.com/acme/harness"
  @app "https://code.example.com/acme/app"
  @team "https://code.example.com/example-org/team-harness"

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

    %{scope: scope, adapter: adapter, covered: covered}
  end

  defp calls do
    receive do
      {:harness_call, path, call} -> [{path, call} | calls()]
    after
      0 -> []
    end
  end

  # The instance's adapter, its grant over `@team`, and the stub over both adapters.
  defp instance_grant(ctx) do
    instance = call_adapter_fixture()
    instance_scope = instance_admin_scope()
    {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
    live_grant_fixture(instance_scope.organisation.id, instance.adapter, connection, "G_i")

    covered = Map.put(ctx.covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})
    serve_calls([ctx.adapter, instance], covered: covered, files: @files)
    instance_scope
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

      assert {[source], 0} = Sources.linked(ctx.scope)
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

      assert {[%{label: "acme/app", stacks: [%{name: nil, file: "qory-stack.yaml"}]}], 0} =
               Sources.linked(ctx.scope)
    end

    test "a repository another organisation's grant covers is no source", ctx do
      covered = %{ctx.adapter.adapter.id => %{@harness => {"G_other", "R_harness"}}}
      serve_calls([ctx.adapter], covered: covered, files: @files)

      assert {[], 0} = Sources.linked(ctx.scope)
    end

    test "an adapter that reaches no one leaves its repositories out, counted", ctx do
      serve_calls([ctx.adapter], down: true)

      assert {[], 2} = Sources.linked(ctx.scope)
    end

    test "reading one gives its workflows and the base a document extends", ctx do
      serve_calls([ctx.adapter], covered: ctx.covered, files: @files)
      {[source], 0} = Sources.linked(ctx.scope)

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

      assert root.label == @team <> " @ v1"
      assert web.label == @team <> " @ v2 web"
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
      {[source], 0} = Sources.linked(ctx.scope)
      {:ok, [stack]} = Sources.read(ctx.scope, source)
      %{base: stack.base}
    end

    test "stores the workspace-level document with the workflow, which a run's walk then finds",
         ctx do
      assert {:ok, %Stack{} = stored} = Sources.save(ctx.scope, ctx.base, "triage")

      assert stored.workflow == "triage"
      assert stored.workspace_id == ctx.scope.workspace.id
      assert is_nil(stored.target_id)

      assert stored.harness ==
               "extends:\n  git: \"#{@harness}\"\n  ref: \"HEAD\"\n  stack: \"triage\"\n"

      assert Sources.current(ctx.scope.workspace) == %{workflow: "triage", base: ctx.base}
      assert Stacks.workflow_for(ctx.scope.workspace, nil) == "triage"

      input = %{
        organisation: ctx.scope.organisation,
        workspace: ctx.scope.workspace,
        target: nil,
        workflow: "triage"
      }

      assert {:ok, walked} = Walk.run(input)
      assert walked.origin == :setting
      assert walked.stack_id == stored.id
      assert walked.document == %{"extends" => ctx.base}
      assert walked.pins == [%{"git" => @harness, "ref" => "HEAD", "at" => "c-R_harness"}]
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
end
