defmodule Apiary.StacksTest do
  # The harness document at five levels: what each write stores, every refusal of a save,
  # the run's workflow read from the rows with a workflow, and what resolves for a run.
  # The resolution itself is `test/apiary/stacks/resolution_test.exs`.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias Apiary.Stacks.{Resolution, Stack}

  @stacks "https://code.example.com/team/stacks"

  # A document that extends the stack in the folder `path` of the stacks source at
  # main, and the stack reference a run's documents carry for it.
  defp doc(path), do: "extends: {git: #{@stacks}, ref: main, path: #{path}}\n"
  defp ref(path), do: "#{@stacks}#main:#{path}"

  setup do
    %{scope: scope} = sign_up_fixture()

    %{scope: scope, target: target!(scope, "team/place")}
  end

  defp target!(scope, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: "system.example",
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  # The workspace's row for the workflow `explore`, with `harness`: the run's one row
  # with a workflow.
  defp workflow!(ctx, harness \\ doc("standard")) do
    {:ok, row} =
      Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "explore"}, harness)

    row
  end

  defp put!(ctx, place, harness) do
    {:ok, row} = Stacks.put_stack(ctx.scope, place, harness)
    row
  end

  defp run_stack(ctx, target \\ :target) do
    target =
      case target do
        :target -> %{system: ctx.target.system, path: ctx.target.path}
        other -> other
      end

    Stacks.for_run(ctx.scope.organisation, ctx.scope.workspace, target)
  end

  defp places(ctx) do
    [
      target_workflow: {:target, ctx.target, "explore"},
      target: {:target, ctx.target},
      workspace_workflow: {:workspace, ctx.scope.workspace, "explore"},
      workspace: {:workspace, ctx.scope.workspace},
      organisation: {:organisation, ctx.scope.organisation}
    ]
  end

  # The changeset errors on `harness` of saving `harness` at the workspace.
  defp refused(ctx, harness) do
    assert {:error, changeset} =
             Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, harness)

    refute Repo.exists?(Stack)
    errors_on(changeset)[:harness]
  end

  describe "put_stack/3" do
    test "stores a document at each of the five levels", ctx do
      for {level, place} <- places(ctx) do
        assert {:ok, %Stack{} = stack} = Stacks.put_stack(ctx.scope, place, doc("one"))
        assert Stack.level(stack) == level
        assert stack.organisation_id == ctx.scope.organisation.id
        assert stack.harness == doc("one")
      end

      assert Repo.aggregate(Stack, :count) == 5
    end

    test "records the person who saved it and that person's organisation", ctx do
      place = {:workspace, ctx.scope.workspace}
      first = put!(ctx, place, doc("core"))

      assert first.saved_by_organisation_id == ctx.scope.organisation.id
      assert first.created_by_id == ctx.scope.user.id
      assert first.updated_by_id == ctx.scope.user.id

      %{scope: other} = sign_up_fixture()
      {:ok, second} = Stacks.put_stack(other, place, doc("general"))

      assert second.id == first.id
      assert second.harness == doc("general")
      assert second.organisation_id == ctx.scope.organisation.id
      assert second.saved_by_organisation_id == other.organisation.id
      assert second.created_by_id == ctx.scope.user.id
      assert second.updated_by_id == other.user.id
    end

    test "records a member's organisation, whose document is shown to its runs", ctx do
      assert Stacks.saved_by(ctx.scope) == ctx.scope.organisation.id

      stack = workflow!(ctx, doc("core"))

      assert stack.saved_by_organisation_id == ctx.scope.organisation.id
      assert Resolution.owner(stack) == ctx.scope.organisation.id
      assert %{stack: reference, harness_hidden: false} = run_stack(ctx)
      assert reference == ref("core")
    end

    test "records no organisation for an instance admin who is not a member", ctx do
      admin = instance_admin_scope()
      refute admin.organisation.id == ctx.scope.organisation.id

      # The admin acting in the run's organisation by a reach an edition gives, with no
      # membership there; and with the admin's membership of the instance's organisation.
      without_membership = %{
        admin
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace,
          membership: nil,
          reach: :instance_admin
      }

      with_other_membership = %{
        admin
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      for scope <- [without_membership, with_other_membership] do
        assert Stacks.saved_by(scope) == nil

        {:ok, stack} =
          Stacks.put_stack(scope, {:workspace, ctx.scope.workspace, "explore"}, doc("core"))

        assert stack.saved_by_organisation_id == nil
        assert Resolution.owner(stack) == nil
        assert %{stack: reference, harness_hidden: true} = run_stack(ctx)
        assert reference == ref("core")
      end
    end

    test "records no organisation for a member who reaches it another way", ctx do
      scope = %{ctx.scope | reach: {:operator, ctx.scope.organisation.id}}
      assert Stacks.saved_by(scope) == nil
    end

    test "records no organisation for the instance acting by itself", ctx do
      scope = Apiary.Accounts.Scope.for_instance(ctx.scope.organisation, ctx.scope.workspace)
      assert Stacks.saved_by(scope) == nil
    end

    test "keeps one row per place", ctx do
      place = {:target, ctx.target, "explore"}
      put!(ctx, place, doc("first"))
      put!(ctx, place, doc("second"))

      assert [%Stack{harness: harness}] = Repo.all(Stack)
      assert harness == doc("second")
    end

    test "stores a row that sets only the workflow, at a place with a workflow", ctx do
      row = put!(ctx, {:workspace, ctx.scope.workspace, "explore"}, nil)
      assert {row.harness, row.workflow} == {nil, "explore"}
      assert Stacks.workflow(ctx.scope.workspace, nil) == "explore"
    end

    test "refuses no document at a place without a workflow", ctx do
      assert refused(ctx, nil) == ["can't be blank"]
      assert refused(ctx, "") == ["can't be blank"]

      assert {:error, changeset} =
               Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, nil)

      assert errors_on(changeset)[:harness] == ["can't be blank"]
    end

    test "refuses a workflow that is not a name", ctx do
      assert {:error, changeset} =
               Stacks.put_stack(
                 ctx.scope,
                 {:workspace, ctx.scope.workspace, "Explore"},
                 doc("core")
               )

      assert changeset.errors[:workflow]
    end
  end

  describe "the save rules" do
    test "take a base by export, by a folder, and at the root of a remote source", ctx do
      for base <- [
            "{git: #{@stacks}, ref: v2, stack: web}",
            "{git: #{@stacks}, ref: v2, path: stacks/web}",
            "{git: #{@stacks}, ref: v2}"
          ] do
        assert {:ok, _stack} =
                 Stacks.put_stack(
                   ctx.scope,
                   {:workspace, ctx.scope.workspace},
                   "extends: #{base}\n"
                 )
      end
    end

    test "take modules by git, by export and at the root, with the other keys", ctx do
      document = """
      name: web
      description: The web harness
      extends: {git: #{@stacks}, ref: v2, stack: web}
      modules:
        - source: {git: https://code.example.com/team/modules, ref: v1, path: modules/review}
          variant: claude
        - name: lint
          source: {git: https://code.example.com/team/modules, ref: v1, module: lint}
          only: {skills: [lint]}
        - source: {git: https://code.example.com/team/extra, ref: v1}
          exclude: {instructions: true}
      bind:
        agents/coder: web-coder
      extensions:
        required_check: Harness self-tests
      """

      assert {:ok, %Stack{harness: ^document}} =
               Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document)
    end

    test "refuse each key a harness document does not take", ctx do
      for key <-
            ~w(runtime model effort tiers force update home links launch) ++
              ~w(git env worktree exports target) do
        document = "extends: {git: #{@stacks}, ref: main}\n#{key}: x\n"

        assert refused(ctx, document) == [
                 "may not contain #{key}: a harness document takes name, description, " <>
                   "extends, modules, bind and extensions"
               ],
               key
      end
    end

    test "refuse a base given by name alone", ctx do
      expected = [
        "give the base web as a git source and an export: " <>
          "extends: {git: <https address>, ref: <ref>, stack: web}"
      ]

      assert refused(ctx, "extends: {stack: web}\n") == expected
      assert refused(ctx, "extends: {stack: web, ref: v2}\n") == expected
    end

    test "refuse a source in scp form, in the base and in a module", ctx do
      scp = "git@code.example.com:team/stacks"

      expected = [
        "write #{scp} as an https address: Qory Apiary fetches harness sources over https only"
      ]

      assert refused(ctx, "extends: {git: '#{scp}', ref: v2, stack: web}\n") == expected

      module = """
      extends: {git: #{@stacks}, ref: v2}
      modules:
        - source: {git: '#{scp}', ref: v1, module: lint}
      """

      assert refused(ctx, module) == expected
    end

    test "refuse an http address and any other address that is not https", ctx do
      for address <- ["http://code.example.com/team/stacks", "ssh://code.example.com/s", "s"] do
        assert refused(ctx, "extends: {git: '#{address}', ref: v2}\n") == [
                 "write #{address} as an https address: " <>
                   "Qory Apiary fetches harness sources over https only"
               ]
      end
    end

    test "refuse user information in an address, and show the address without it", ctx do
      for address <- [
            "https://someone:secret-value@code.example.com/team/stacks",
            "https://someone@code.example.com/team/stacks",
            "http://someone:secret-value@code.example.com/team/stacks"
          ] do
        assert [error] = refused(ctx, "extends: {git: '#{address}', ref: v2}\n")
        refute error =~ "secret-value"
        refute error =~ "someone"

        assert error =~
                 ~r{^remove the user name and password from https?://code\.example\.com/team/stacks: a harness source address may not contain a credential$}
      end

      module = """
      extends: {git: #{@stacks}, ref: v2}
      modules:
        - source: {git: 'https://someone:secret-value@code.example.com/m', ref: v1}
      """

      assert [error] = refused(ctx, module)
      refute error =~ "secret-value"
    end

    test "refuse what the run contract's harness section refuses", ctx do
      base = "extends: {git: #{@stacks}, ref: v2}\n"

      for {document, place} <- [
            {"extends: {path: ./stacks/web}\n", "#/extends"},
            {"extends: {path: ., stack: web}\n", "#/extends"},
            {"extends: {git: #{@stacks}, ref: v2, path: s, stack: web}\n", "#/extends"},
            {"extends: {git: #{@stacks}}\n", "#/extends"},
            {"modules: [{source: {git: #{@stacks}, ref: v1}}]\n", "#"},
            {base <> "modules: [{name: lint}]\n", "#/modules/0"},
            {base <> "modules: [{source: {path: ./m}}]\n", "#/modules/0"},
            {base <> "modules: [{source: {git: #{@stacks}, ref: v1}, link: m}]\n", "#/modules/0"},
            {base <> "modules: []\n", "#/modules"},
            {base <> "bind: {coder: x}\n", "#/bind"}
          ] do
        assert [error] = refused(ctx, document), document
        assert error =~ "does not follow the harness format at #{place}", document
        assert error =~ ~r/^does not follow the harness format at #[^:]*: .+/
      end
    end

    test "refuse a document the reader refuses", ctx do
      assert refused(ctx, "extends: &b {git: #{@stacks}, ref: v2}\n") == [
               "uses a YAML anchor or alias, which a harness document may not"
             ]

      assert refused(ctx, "extends: [a\n") == ["is not valid YAML"]
      assert [not_a_section] = refused(ctx, "- a\n")
      assert not_a_section =~ "is not a harness section"

      assert refused(ctx, "extends: {git: #{@stacks}, ref: a, ref: b}\n") ==
               ["repeats the key ref"]

      big = "extensions: {n: '#{String.duplicate("x", 65_536)}'}\n"
      assert refused(ctx, big) == ["is larger than 65536 bytes"]
    end

    test "refuse a value that is not text", ctx do
      assert refused(ctx, 7) == ["is invalid"]
    end
  end

  describe "delete_stack/1" do
    test "removes the stack at a place, and the next level applies", ctx do
      workflow!(ctx)
      place = {:target, ctx.target}
      put!(ctx, place, doc("one"))
      assert run_stack(ctx).stack == ref("one")

      assert {:ok, %Stack{}} = Stacks.delete_stack(place)
      assert run_stack(ctx).stack == ref("standard")
    end

    test "is not found for a place with none", ctx do
      assert Stacks.delete_stack({:organisation, ctx.scope.organisation}) ==
               {:error, :not_found}
    end
  end

  describe "workflow/2" do
    test "is the workflow of the one row with a workflow at the workspace", ctx do
      workflow!(ctx)
      put!(ctx, {:workspace, ctx.scope.workspace}, doc("core"))
      put!(ctx, {:organisation, ctx.scope.organisation}, doc("x"))

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "explore"
      assert Stacks.workflow(ctx.scope.workspace, nil) == "explore"
    end

    test "is the workflow of the one row with a workflow at the run's target", ctx do
      put!(ctx, {:target, ctx.target, "review"}, doc("core"))

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "review"
      assert Stacks.workflow(ctx.scope.workspace, nil) == nil
    end

    test "leaves out the rows with a workflow at another target", ctx do
      workflow!(ctx)
      other = target!(ctx.scope, "team/other")
      put!(ctx, {:target, other, "review"}, doc("core"))

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == "explore"
      assert Stacks.workflow(ctx.scope.workspace, other) == nil
    end

    test "leaves out the rows of another workspace", ctx do
      %{scope: other} = sign_up_fixture()
      {:ok, _stack} = Stacks.put_stack(other, {:workspace, other.workspace, "explore"}, doc("c"))

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
    end

    test "is nil for no row with a workflow", ctx do
      put!(ctx, {:target, ctx.target}, doc("core"))
      put!(ctx, {:workspace, ctx.scope.workspace}, doc("core"))

      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
    end

    test "is nil for two rows with a workflow, whatever their workflows", ctx do
      workflow!(ctx)
      put!(ctx, {:workspace, ctx.scope.workspace, "review"}, doc("x"))

      assert Stacks.workflow(ctx.scope.workspace, nil) == nil

      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace, "review"})
      put!(ctx, {:target, ctx.target, "explore"}, doc("x"))
      assert Stacks.workflow(ctx.scope.workspace, ctx.target) == nil
      assert Stacks.workflow(ctx.scope.workspace, nil) == "explore"
    end
  end

  describe "for_run/3" do
    test "one row with a workflow: the run has that workflow, its stack and harness_hidden",
         ctx do
      workflow!(ctx)

      assert run_stack(ctx) == %{
               stack: ref("standard"),
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "the stack of a base at the root of a remote source is that root", ctx do
      workflow!(ctx, "extends: {git: #{@stacks}, ref: main}\n")
      assert run_stack(ctx).stack == ref(".")
    end

    test "a document that is not a base alone gives the run no stack", ctx do
      for document <- [
            "extends: {git: #{@stacks}, ref: main, stack: web}\n",
            "extends: {git: #{@stacks}, ref: main}\nname: web\n",
            "extends: {git: #{@stacks}, ref: main}\nmodules: [{source: {git: #{@stacks}, ref: v1}}]\n"
          ] do
        workflow!(ctx, document)
        assert run_stack(ctx) == nil, document
      end
    end

    test "a row with the workflow alone takes its document from another level", ctx do
      workflow!(ctx, nil)
      assert run_stack(ctx) == nil

      put!(ctx, {:organisation, ctx.scope.organisation}, doc("default"))

      assert run_stack(ctx) == %{
               stack: ref("default"),
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "no row with a workflow: the run has no stack, whatever the levels have", ctx do
      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        put!(ctx, place, doc("core"))
      end

      assert run_stack(ctx) == nil
      assert run_stack(ctx, nil) == nil
    end

    test "two rows with a workflow: the run has no stack", ctx do
      workflow!(ctx)
      put!(ctx, {:target, ctx.target, "review"}, doc("x"))

      assert run_stack(ctx) == nil
      assert run_stack(ctx, nil).workflow == "explore"
    end

    test "a target row without a workflow wins over the workflow row at the workspace", ctx do
      workflow!(ctx, doc("at-workspace-workflow"))

      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        put!(ctx, place, doc("at-" <> String.replace("#{level}", "_", "-")))
      end

      assert run_stack(ctx).stack == ref("at-target")
      assert run_stack(ctx, nil).stack == ref("at-workspace-workflow")

      {:ok, _stack} = Stacks.delete_stack({:target, ctx.target})
      assert run_stack(ctx).stack == ref("at-workspace-workflow")
    end

    test "a workflow row at the target wins over every other level", ctx do
      for {level, place} <- places(ctx), level != :workspace_workflow do
        put!(ctx, place, doc("at-" <> String.replace("#{level}", "_", "-")))
      end

      assert run_stack(ctx) == %{
               stack: ref("at-target-workflow"),
               workflow: "explore",
               harness_hidden: false
             }

      assert run_stack(ctx, nil) == nil
    end

    test "a target no row of the workspace has counts as none", ctx do
      workflow!(ctx)
      put!(ctx, {:target, ctx.target}, doc("at-target"))

      assert run_stack(ctx, %{system: "system.example", path: "team/elsewhere"}).stack ==
               ref("standard")
    end
  end

  describe "harness_hidden" do
    test "is false for a document saved by the run's organisation", ctx do
      workflow!(ctx, doc("core"))
      assert %{harness_hidden: false} = run_stack(ctx)
    end

    test "is true for a document saved by another organisation", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "explore"}, doc("core"))

      assert %{harness_hidden: true} = run_stack(ctx)
    end

    test "is true when the run's organisation is operated", ctx do
      workflow!(ctx)
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert %{harness_hidden: true} = run_stack(ctx)
    end
  end
end
