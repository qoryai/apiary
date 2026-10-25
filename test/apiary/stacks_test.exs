defmodule Apiary.StacksTest do
  # The harness document at five levels: what each write stores, every refusal of a save,
  # the run's workflow read from the rows with a workflow, and what resolves for a run.
  # The resolution itself is `test/apiary/stacks/resolution_test.exs`.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Edition
  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias Apiary.Stacks.{Resolution, Stack}

  @stacks "https://code.example.com/team/stacks"

  # A document that extends the stack in the folder `path` of the stacks source at main.
  defp doc(path), do: "extends: {git: #{@stacks}, ref: main, path: #{path}}\n"

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

  # What resolves for an explore run at `target`, the context's target by default: the
  # document, the run's workflow and `harness_hidden`; nil for no workflow or no document.
  defp run_harness(ctx, target \\ :target) do
    target =
      case target do
        :target -> %{system: ctx.target.system, path: ctx.target.path}
        other -> other
      end

    with workflow when is_binary(workflow) <- Stacks.workflow_for(ctx.scope.workspace, target),
         {:ok, resolution} <-
           Stacks.resolve_for(ctx.scope.organisation, ctx.scope.workspace, target, workflow) do
      Map.take(resolution, [:harness, :workflow, :harness_hidden])
    else
      _none -> nil
    end
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

    test "records the person who saved it and the organisation that owns it", ctx do
      place = {:workspace, ctx.scope.workspace}
      first = put!(ctx, place, doc("core"))

      assert first.owner_organisation_id == ctx.scope.organisation.id
      assert first.created_by_id == ctx.scope.user.id
      assert first.updated_by_id == ctx.scope.user.id

      %{scope: other} = sign_up_fixture()
      {:ok, second} = Stacks.put_stack(other, place, doc("general"))

      assert second.id == first.id
      assert second.harness == doc("general")
      assert second.organisation_id == ctx.scope.organisation.id
      assert second.owner_organisation_id == other.organisation.id
      assert second.created_by_id == ctx.scope.user.id
      assert second.updated_by_id == other.user.id
    end

    test "a member's organisation owns what they save, and its runs are shown it", ctx do
      assert Stacks.saved_by(ctx.scope) == ctx.scope.organisation.id
      assert Edition.harness_owner(ctx.scope) == ctx.scope.organisation.id

      stack = workflow!(ctx, doc("core"))

      assert stack.owner_organisation_id == ctx.scope.organisation.id
      assert Resolution.owner(stack) == ctx.scope.organisation.id
      assert %{harness: harness, harness_hidden: false} = run_harness(ctx)
      assert harness == doc("core")
    end

    test "the instance's organisation owns what an instance admin saves there as no member",
         ctx do
      admin = instance_admin_scope()
      instance = Edition.instance_organisation_id()
      assert admin.organisation.id == instance
      refute instance == ctx.scope.organisation.id

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
        assert Edition.harness_owner(scope) == instance

        {:ok, stack} =
          Stacks.put_stack(scope, {:workspace, ctx.scope.workspace, "explore"}, doc("core"))

        assert stack.owner_organisation_id == instance
        assert Resolution.owner(stack) == instance
        assert %{harness: harness, harness_hidden: true} = run_harness(ctx)
        assert harness == doc("core")
      end
    end

    test "refuses the save of a member who reaches it another way", ctx do
      scope = %{ctx.scope | reach: {:operator, ctx.scope.organisation.id}}
      assert Stacks.saved_by(scope) == nil
      assert Edition.harness_owner(scope) == nil

      assert Stacks.put_stack(scope, {:workspace, ctx.scope.workspace}, doc("core")) ==
               {:error, :forbidden}

      refute Repo.exists?(Stack)
    end

    test "refuses the save of the instance acting by itself", ctx do
      scope = Apiary.Accounts.Scope.for_instance(ctx.scope.organisation, ctx.scope.workspace)
      assert Stacks.saved_by(scope) == nil
      assert Edition.harness_owner(scope) == nil

      assert Stacks.put_stack(scope, {:workspace, ctx.scope.workspace}, doc("core")) ==
               {:error, :forbidden}

      refute Repo.exists?(Stack)
    end

    test "refuses a save the edition gives no owner for, and keeps the row as it was", ctx do
      place = {:workspace, ctx.scope.workspace}
      before = put!(ctx, place, doc("core"))
      :ok = Edition.put_test_stub(Apiary.EditionStubs.NoHarnessOwner)

      assert Stacks.put_stack(ctx.scope, place, doc("other")) == {:error, :forbidden}
      assert Repo.all(Stack) == [before]
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

    test "take a document without extends that defines a stack, with its workflows", ctx do
      for document <- [
            "modules: [{source: {git: #{@stacks}, ref: v1}}]\n",
            "name: web\nmodules:\n  - source: {git: #{@stacks}, ref: v1, module: web}\n" <>
              "workflows:\n  explore: {access: write, time_limit: 45m}\n  review: {}\n"
          ] do
        assert {:ok, stack} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document)

        Repo.delete!(stack)
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
                   "extends, modules, bind, extensions and workflows"
               ],
               key
      end
    end

    test "refuse workflows with extends, and a document with neither extends nor modules",
         ctx do
      assert refused(ctx, "extends: {git: #{@stacks}, ref: v2}\nworkflows: {explore: {}}\n") ==
               [
                 "remove workflows or extends: " <>
                   "a harness document that extends a stack takes that stack's workflows"
               ]

      for document <- ["name: web\n", "bind: {agents/coder: x}\n"] do
        assert refused(ctx, document) == [
                 "add extends or at least one module: " <>
                   "a harness document extends a stack, or defines one with at least one module"
               ],
               document
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

      # The address is shown without what comes before its last `@`.
      expected = [
        "write code.example.com:team/stacks as an https address: " <>
          "Qory Apiary fetches harness sources over https only"
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

    test "never show a user name or password, whatever the address's shape", ctx do
      for address <- [
            "https://user:SECRET@host.example.com/r",
            " https://user:SECRET@host.example.com/r",
            "\thttps://user:SECRET@host.example.com/r",
            "https:/user:SECRET@host.example.com/r",
            "https:user:SECRET@host.example.com/r",
            "https:\\\\\\\\user:SECRET@host.example.com",
            "user:SECRET@host.example.com:org/r",
            "ssh://user:SECRET@host.example.com/r"
          ],
          document <- [
            "extends: {git: #{inspect(address)}, ref: v2}\n",
            "extends: {git: #{@stacks}, ref: v2}\nmodules:\n  - source: {git: #{inspect(address)}, ref: v1}\n"
          ] do
        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document)

        assert [{:harness, {message, values}}] = changeset.errors, document
        refute message =~ "SECRET"
        assert values[:source] =~ "host.example.com", document
        refute Enum.any?(values, fn {_key, value} -> inspect(value) =~ "SECRET" end), document
        refute Enum.any?(values, fn {_key, value} -> inspect(value) =~ "user" end), document
      end
    end

    test "show the address as \"the address\" when a ? or # comes before its last @", ctx do
      text =
        " with no query (?) and no fragment (#): a harness source address is " <>
          "https://, a host, an optional port and an optional path"

      for address <- [
            "https://user:SECRET#x@host.example.com/r",
            "https://user:SECRET?x@host.example.com/r",
            "https://h/r?x@SECRET",
            "https://host.example.com/r?u=me@example.com&token=SECRET"
          ],
          document <- [
            "extends: {git: '#{address}', ref: v2}\n",
            "extends: {git: #{@stacks}, ref: v2}\nmodules:\n  - source: {git: '#{address}', ref: v1}\n"
          ] do
        assert refused(ctx, document) == ["write the address" <> text], document

        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document)

        assert [{:harness, {_message, values}}] = changeset.errors, document
        refute Enum.any?(values, fn {_key, value} -> inspect(value) =~ "SECRET" end), document
      end
    end

    test "refuse an address that is not https, a host, a port and a path", ctx do
      text =
        " as https://, a host, an optional port and an optional path: " <>
          "Qory Apiary fetches harness sources over https only"

      for address <- [
            "https://",
            "https:///r",
            "https://:443/r",
            "https://code.example.com:99999/r",
            "https://code.example.com/team/%zz",
            "https://code.example.com/team/stacks\\x",
            "https://[::1/r",
            "https://code.example.com/" <> String.duplicate("a", 2_560)
          ] do
        assert refused(ctx, "extends: {git: '#{address}', ref: v2}\n") == [
                 "write " <> address <> text
               ],
               address
      end

      for address <- [
            "https://code.example.com",
            "https://code.example.com:8443/team/stacks.git",
            "https://[2001:db8::1]/team/stacks",
            "https://192.0.2.1/team/stacks"
          ] do
        assert {:ok, _stack} =
                 Stacks.put_stack(
                   ctx.scope,
                   {:workspace, ctx.scope.workspace},
                   "extends: {git: '#{address}', ref: v2}\n"
                 ),
               address
      end
    end

    test "refuse a query or a fragment, and never show the query", ctx do
      text =
        " with no query (?) and no fragment (#): a harness source address is " <>
          "https://, a host, an optional port and an optional path"

      for {address, shown} <- [
            {"https://code.example.com/team/stacks?private_token=SECRET",
             "https://code.example.com/team/stacks"},
            {"https://code.example.com/team/stacks#SECRET",
             "https://code.example.com/team/stacks"},
            {"https://code.example.com?SECRET", "https://code.example.com"},
            {"https://?SECRET", "https://"}
          ],
          document <- [
            "extends: {git: '#{address}', ref: v2}\n",
            "extends: {git: #{@stacks}, ref: v2}\nmodules:\n  - source: {git: '#{address}', ref: v1}\n"
          ] do
        assert refused(ctx, document) == ["write " <> shown <> text], document

        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document)

        assert [{:harness, {_message, values}}] = changeset.errors, document
        refute Enum.any?(values, fn {_key, value} -> inspect(value) =~ "SECRET" end), document
      end
    end

    test "refuse whitespace or a control character in an address", ctx do
      text =
        " as an https address with no space or control character: " <>
          "Qory Apiary fetches harness sources over https only"

      assert refused(ctx, ~s(extends: {git: "https://host.example.com r", ref: v2}\n)) ==
               ["write https://host.example.com r" <> text]

      assert refused(
               ctx,
               ~s(extends: {git: "https://host.example.com/r\\n--upload-pack=x", ref: v2}\n)
             ) == ["write https://host.example.com/r\uFFFD--upload-pack=x" <> text]

      assert refused(ctx, ~s(extends: {git: "https://host.example.com/r\\t", ref: v2}\n)) ==
               ["write https://host.example.com/r\uFFFD" <> text]

      assert refused(ctx, ~s(extends: {git: "https:// spaced host", ref: v2}\n)) ==
               ["write https:// spaced host" <> text]

      assert refused(ctx, ~s(extends: {git: "https://host.example.com/r\\n", ref: v2}\n)) ==
               ["write https://host.example.com/r\uFFFD" <> text]
    end

    test "refuse !!binary in any place, with no crash", ctx do
      for document <- [
            "extends: {git: #{@stacks}, ref: v2}\nbind: {agents/x: !!binary //79}\n",
            "extends: {git: #{@stacks}, ref: v2}\nname: !!binary //79\n",
            "extends: {git: #{@stacks}, ref: !!binary //79}\n",
            "extends: {git: #{@stacks}, ref: v2}\nextensions: {a: !!binary //79}\n"
          ] do
        assert refused(ctx, document) == [
                 "uses a YAML type a harness document does not take, such as !!binary: " <>
                   "write each value as text, a number, true, false or null"
               ],
               document
      end
    end

    test "refuse a control character, written or escaped, with no crash", ctx do
      expected = ["contains a control character, which a harness document may not"]

      for character <- [<<0>>, <<1>>, <<0x1B>>] do
        document = "extends: {git: #{@stacks}, ref: v2}\nname: a" <> character <> "b\n"
        assert refused(ctx, document) == expected
      end

      assert refused(ctx, "extends: {git: #{@stacks}, ref: v2}\nname: \"a\\0b\"\n") == expected
    end

    test "refuse what the YAML parser fails on, with no crash", ctx do
      for document <- [
            "extends: {git: #{@stacks}, ref: v2}\nname: !!bool maybe\n",
            "\t a: 1\n"
          ] do
        assert refused(ctx, document) == ["is not valid YAML"], document
      end
    end

    test "refuse a document that takes too long to read", ctx do
      expected = [
        "takes more work to read than a harness document may: " <>
          "write long lists as block lists, with one - item per line"
      ]

      # The read passes the reader's budget of 30 million reductions within 3 s on an
      # idle machine; the reader's backstop of 10 s bounds it on a busy one.
      slow = "modules:\n- [" <> String.duplicate("a,", 32_000) <> "a]\n"
      assert {time, ^expected} = :timer.tc(fn -> refused(ctx, slow) end)
      assert time < 12_000_000
    end

    test "refuse what the run contract's harness section refuses", ctx do
      base = "extends: {git: #{@stacks}, ref: v2}\n"

      for {document, place} <- [
            {"extends: {path: ./stacks/web}\n", "#/extends"},
            {"extends: {path: ., stack: web}\n", "#/extends"},
            {"extends: {git: #{@stacks}, ref: v2, path: s, stack: web}\n", "#/extends"},
            {"extends: {git: #{@stacks}}\n", "#/extends"},
            {"modules: []\n", "#/modules"},
            {"modules: [{source: {path: ./m}}]\n", "#/modules/0"},
            {"modules: [{source: {git: #{@stacks}, ref: v1}}]\nworkflows: {explore: {access: admin}}\n",
             "#/workflows/explore/access"},
            {"modules: [{source: {git: #{@stacks}, ref: v1}}]\nworkflows: {Explore: {}}\n",
             "#/workflows"},
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

  describe "the access level" do
    test "is nil by default", ctx do
      for {_level, place} <- places(ctx) do
        assert {:ok, %Stack{access: nil}} = Stacks.put_stack(ctx.scope, place, doc("one"))
      end
    end

    test "is recorded at a place with a workflow, and replaced by the next save", ctx do
      for place <- [{:workspace, ctx.scope.workspace, "explore"}, {:target, ctx.target, "x"}],
          level <- [:read, :write] do
        assert {:ok, %Stack{access: ^level}} =
                 Stacks.put_stack(ctx.scope, place, doc("one"), access: level)
      end

      place = {:workspace, ctx.scope.workspace, "explore"}
      assert {:ok, %Stack{access: nil}} = Stacks.put_stack(ctx.scope, place, doc("one"))
      assert Repo.get_by!(Stack, workflow: "explore").access == nil
    end

    test "a level at a place without a workflow is refused", ctx do
      for place <- [{:workspace, ctx.scope.workspace}, {:target, ctx.target}],
          level <- [:read, :write] do
        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, place, doc("one"), access: level)

        assert errors_on(changeset)[:access] == ["is recorded only at a place with a workflow"]
      end

      refute Repo.exists?(Stack)
    end

    test "a level other than read and write is refused", ctx do
      place = {:workspace, ctx.scope.workspace, "explore"}

      assert {:error, changeset} =
               Stacks.put_stack(ctx.scope, place, doc("one"), access: "admin")

      assert errors_on(changeset)[:access] == ["is invalid"]
    end

    test "the check takes null, or read or write on a row with a workflow", ctx do
      row = workflow!(ctx)
      plain = put!(ctx, {:workspace, ctx.scope.workspace}, doc("core"))

      for level <- [:read, :write, nil] do
        assert {1, _rows} =
                 Repo.update_all(from(s in Stack, where: s.id == ^row.id), set: [access: level])
      end

      for {id, level} <- [{plain.id, "write"}, {plain.id, "read"}, {row.id, "admin"}] do
        assert_raise Postgrex.Error, ~r/stacks_access_check/, fn ->
          Repo.transact(fn ->
            Repo.query!("UPDATE stacks SET access = $1 WHERE id = $2", [
              level,
              Ecto.UUID.dump!(id)
            ])

            {:ok, nil}
          end)
        end
      end
    end
  end

  describe "delete_stack/1" do
    test "removes the stack at a place, and the next level applies", ctx do
      workflow!(ctx)
      place = {:target, ctx.target}
      put!(ctx, place, doc("one"))
      assert run_harness(ctx).harness == doc("one")

      assert {:ok, %Stack{}} = Stacks.delete_stack(place)
      assert run_harness(ctx).harness == doc("standard")
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

  describe "workflow_for/2 and resolve_for/4" do
    test "one row with a workflow: the run has that workflow, its document and harness_hidden",
         ctx do
      workflow!(ctx)

      assert run_harness(ctx) == %{
               harness: doc("standard"),
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "a document resolves as saved, whatever its keys", ctx do
      for document <- [
            "extends: {git: #{@stacks}, ref: main, stack: web}\n",
            "extends: {git: #{@stacks}, ref: main}\nname: web\n",
            "extends: {git: #{@stacks}, ref: main}\nmodules: [{source: {git: #{@stacks}, ref: v1}}]\n"
          ] do
        workflow!(ctx, document)
        assert run_harness(ctx).harness == document
      end
    end

    test "a row with the workflow alone takes its document from another level", ctx do
      workflow!(ctx, nil)
      assert run_harness(ctx) == nil

      put!(ctx, {:organisation, ctx.scope.organisation}, doc("default"))

      assert run_harness(ctx) == %{
               harness: doc("default"),
               workflow: "explore",
               harness_hidden: false
             }
    end

    test "no row with a workflow: the run has no harness, whatever the levels have", ctx do
      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        put!(ctx, place, doc("core"))
      end

      assert run_harness(ctx) == nil
      assert run_harness(ctx, nil) == nil
    end

    test "two rows with a workflow: the run has no harness", ctx do
      workflow!(ctx)
      put!(ctx, {:target, ctx.target, "review"}, doc("x"))

      assert run_harness(ctx) == nil
      assert run_harness(ctx, nil).workflow == "explore"
    end

    test "a target row without a workflow wins over the workflow row at the workspace", ctx do
      workflow!(ctx, doc("at-workspace-workflow"))

      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        put!(ctx, place, doc("at-" <> String.replace("#{level}", "_", "-")))
      end

      assert run_harness(ctx).harness == doc("at-target")
      assert run_harness(ctx, nil).harness == doc("at-workspace-workflow")

      {:ok, _stack} = Stacks.delete_stack({:target, ctx.target})
      assert run_harness(ctx).harness == doc("at-workspace-workflow")
    end

    test "a workflow row at the target wins over every other level", ctx do
      for {level, place} <- places(ctx), level != :workspace_workflow do
        put!(ctx, place, doc("at-" <> String.replace("#{level}", "_", "-")))
      end

      assert run_harness(ctx) == %{
               harness: doc("at-target-workflow"),
               workflow: "explore",
               harness_hidden: false
             }

      assert run_harness(ctx, nil) == nil
    end

    test "a target no row of the workspace has counts as none", ctx do
      workflow!(ctx)
      put!(ctx, {:target, ctx.target}, doc("at-target"))

      assert run_harness(ctx, %{system: "system.example", path: "team/elsewhere"}).harness ==
               doc("standard")
    end
  end

  describe "harness_hidden" do
    test "is false for a document saved by the run's organisation", ctx do
      workflow!(ctx, doc("core"))
      assert %{harness_hidden: false} = run_harness(ctx)
    end

    test "is true for a document saved by another organisation", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace, "explore"}, doc("core"))

      assert %{harness_hidden: true} = run_harness(ctx)
    end

    test "is true when the run's organisation is operated", ctx do
      workflow!(ctx)
      :ok = Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert %{harness_hidden: true} = run_harness(ctx)
    end
  end
end
