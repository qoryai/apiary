defmodule Apiary.StacksTest do
  # The harness document at five levels: what each write stores, every refusal of a save,
  # the run's workflow read from the rows with a workflow, and the harness choice a run
  # takes. The resolution of a row is `test/apiary/stacks/resolution_test.exs`.
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

  # The harness choice an explore run at `target` takes, the context's target by default:
  # `{kind, %{harness, level, harness_hidden}}`, or `:none`.
  defp run_harness(ctx, target \\ :target) do
    target =
      case target do
        :target -> %{system: ctx.target.system, path: ctx.target.path}
        other -> other
      end

    case Stacks.chosen_for(ctx.scope.organisation, ctx.scope.workspace, target, "explore") do
      {kind, resolution} -> {kind, Map.take(resolution, [:harness, :level, :harness_hidden])}
      :none -> :none
    end
  end

  # A harness choice at `place`, a place with no workflow.
  defp choose!(ctx, place, harness, choice \\ :repository) do
    {:ok, row} = Stacks.put_stack(ctx.scope, place, harness, choice: choice)
    row
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

      stack = choose!(ctx, {:workspace, ctx.scope.workspace}, doc("core"))

      assert stack.owner_organisation_id == ctx.scope.organisation.id
      assert Resolution.owner(stack) == ctx.scope.organisation.id
      assert {:chosen, %{harness: harness, harness_hidden: false}} = run_harness(ctx)
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
          Stacks.put_stack(scope, {:workspace, ctx.scope.workspace}, doc("core"),
            choice: :repository
          )

        assert stack.owner_organisation_id == instance
        assert Resolution.owner(stack) == instance
        assert {:chosen, %{harness: harness, harness_hidden: true}} = run_harness(ctx)
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
    @allowed_refs [
      "HEAD",
      "main",
      "release/1.0",
      "v1.2.0",
      "refs/heads/main",
      "refs/tags/v1.2.0",
      String.duplicate("0a", 20),
      String.duplicate("b1", 32)
    ]
    @refused_refs [
      "refs/pull/1/head",
      "refs/merge-requests/1/head",
      "refs/remotes/x",
      "pull/1/head",
      "merge-requests/1/head",
      "remotes/x",
      "refs/heads/",
      "refs/notes/x",
      "pull-requests/1/from",
      "changes/01/1/1",
      "notes/x",
      "refs/tags/../pull/1/head",
      "./pull/1/head",
      "/x",
      "a//b"
    ]

    test "take a ref that is HEAD, a branch or tag name, refs/heads/*, refs/tags/* or a full commit id",
         ctx do
      for ref <- @allowed_refs,
          document <- [
            "extends: {git: #{@stacks}, ref: '#{ref}'}\n",
            "modules: [{source: {git: #{@stacks}, ref: '#{ref}'}}]\n"
          ] do
        assert {:ok, stack} =
                 Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, document),
               document

        Repo.delete!(stack)
      end
    end

    test "refuse any other ref under refs/, a short name in another namespace, and an empty or dot part, in the base and in a module",
         ctx do
      for ref <- @refused_refs,
          document <- [
            "extends: {git: #{@stacks}, ref: '#{ref}'}\n",
            "extends: {git: #{@stacks}, ref: v2}\nmodules:\n  - source: {git: #{@stacks}, ref: '#{ref}'}\n"
          ] do
        assert refused(ctx, document) == [
                 "write the ref #{ref} as HEAD, a branch or tag name, refs/heads/<name>, " <>
                   "refs/tags/<name> or a full commit id: people without write access can " <>
                   "change other refs, such as a pull request's"
               ],
               document
      end
    end

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
    test "removes the stack at a place, and the next choice applies", ctx do
      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("standard"))
      place = {:target, ctx.target}
      choose!(ctx, place, doc("one"))
      assert {:chosen, %{harness: harness}} = run_harness(ctx)
      assert harness == doc("one")

      assert {:ok, %Stack{}} = Stacks.delete_stack(place)
      assert {:chosen, %{harness: harness}} = run_harness(ctx)
      assert harness == doc("standard")
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

  describe "workflow_for/2" do
    test "is the workflow of the one row with a workflow at the run's places", ctx do
      put!(ctx, {:target, ctx.target, "review"}, doc("core"))
      target = %{system: ctx.target.system, path: ctx.target.path}

      assert Stacks.workflow_for(ctx.scope.workspace, target) == "review"
      assert Stacks.workflow_for(ctx.scope.workspace, nil) == nil
    end

    test "a target no row of the workspace has counts as none", ctx do
      workflow!(ctx)
      put!(ctx, {:target, ctx.target, "review"}, doc("core"))
      elsewhere = %{system: "system.example", path: "team/elsewhere"}

      assert Stacks.workflow_for(ctx.scope.workspace, elsewhere) == "explore"
    end
  end

  describe "a harness choice" do
    test "is stored with its document at each place with no workflow", ctx do
      for {level, place} <- places(ctx),
          level in [:target, :workspace, :organisation],
          choice <- [:qory, :repository] do
        assert {:ok, %Stack{choice: ^choice} = stack} =
                 Stacks.put_stack(ctx.scope, place, doc("one"), choice: choice)

        assert Stack.level(stack) == level
      end

      assert Stacks.choice(ctx.scope.workspace).choice == :repository
      assert Stacks.shared(ctx.scope.organisation).choice == :repository
      assert Stacks.target_choice(ctx.scope.workspace, ctx.target).choice == :repository

      assert Stacks.target_choice(ctx.scope.workspace, %{
               system: "system.example",
               path: "team/place"
             }).id ==
               Stacks.target_choice(ctx.scope.workspace, ctx.target).id
    end

    test "is refused at a place with a workflow, and without a document", ctx do
      for {level, place} <- places(ctx), level in [:target_workflow, :workspace_workflow] do
        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, place, doc("one"), choice: :qory)

        assert errors_on(changeset)[:choice] == ["is invalid"]
      end

      for {level, place} <- places(ctx), level in [:target, :workspace, :organisation] do
        assert {:error, changeset} =
                 Stacks.put_stack(ctx.scope, place, nil, choice: :repository)

        assert errors_on(changeset)[:harness] == ["can't be blank"]
      end

      refute Repo.exists?(Stack)
    end

    test "refuses any other value, target_file among them", ctx do
      assert {:error, changeset} =
               Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, nil,
                 choice: :target_file
               )

      assert errors_on(changeset)[:choice] == ["is invalid"]
    end

    test "a write at the place without a choice removes the choice", ctx do
      choose!(ctx, {:organisation, ctx.scope.organisation}, doc("one"))
      put!(ctx, {:organisation, ctx.scope.organisation}, doc("one"))
      assert Stacks.shared(ctx.scope.organisation) == nil
    end
  end

  describe "chosen_for/4" do
    test "a target's stack, then the workspace's choice, then the organisation's shared harness, then none",
         ctx do
      choose!(ctx, {:organisation, ctx.scope.organisation}, doc("shared"), :qory)
      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("workspace"))
      choose!(ctx, {:target, ctx.target}, doc("target"), :qory)

      assert run_harness(ctx) ==
               {:chosen, %{harness: doc("target"), level: :target, harness_hidden: false}}

      {:ok, _stack} = Stacks.delete_stack({:target, ctx.target})

      assert run_harness(ctx) ==
               {:chosen, %{harness: doc("workspace"), level: :workspace, harness_hidden: false}}

      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace})

      assert run_harness(ctx) ==
               {:chosen, %{harness: doc("shared"), level: :organisation, harness_hidden: false}}

      {:ok, _stack} = Stacks.delete_stack({:organisation, ctx.scope.organisation})
      assert run_harness(ctx) == :none
    end

    test "the Qory harness and a harness repository are both :chosen, the walk reads the target's file before either",
         ctx do
      choose!(ctx, {:organisation, ctx.scope.organisation}, doc("shared"), :repository)
      assert {:chosen, %{level: :organisation}} = run_harness(ctx)

      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("workspace"), :qory)
      assert {:chosen, %{level: :workspace}} = run_harness(ctx)
    end

    test "the resolution's ref is that of the row's version, nil for a row with none", ctx do
      target = %{system: ctx.target.system, path: ctx.target.path}

      chosen = fn ->
        Stacks.chosen_for(ctx.scope.organisation, ctx.scope.workspace, target, "explore")
      end

      latest = Apiary.Lingo.Domain.Definition.qory_commit(:latest)

      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("workspace"), :repository)
      assert {:chosen, %Resolution{ref: nil}} = chosen.()

      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, doc("workspace"),
          choice: :repository,
          version: {:tag, "v2"}
        )

      assert {:chosen, %Resolution{ref: "v2"}} = chosen.()

      # A target's stack that follows the workspace's version.
      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:target, ctx.target}, doc("target"),
          choice: :repository,
          version: {:workspace, nil}
        )

      assert {:chosen, %Resolution{level: :target, ref: "v2"}} = chosen.()

      # The workspace takes the Qory harness, and the row is of another repository: the
      # row's document's ref.
      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace})
      assert {:chosen, %Resolution{level: :target, ref: "main"}} = chosen.()

      # A row of the Qory harness that follows the workspace's: the newest version.
      qory =
        "extends:\n  git: \"https://github.com/qoryai/harness\"\n" <>
          "  ref: \"#{String.duplicate("0a", 20)}\"\n  stack: \"core\"\n"

      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:target, ctx.target}, qory,
          choice: :qory,
          version: {:workspace, nil}
        )

      assert {:chosen, %Resolution{level: :target, ref: ^latest}} = chosen.()

      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:target, ctx.target}, doc("target"),
          choice: :qory,
          version: {:named, "v0.1"}
        )

      assert {:chosen, %Resolution{ref: {:missing, "v0.1"}}} = chosen.()
    end

    test "the target's resolution has the target's row", ctx do
      stack = choose!(ctx, {:target, ctx.target}, doc("target"))
      target = %{system: ctx.target.system, path: ctx.target.path}

      assert {:chosen, %Resolution{stack_id: stack_id, workflow: "explore"}} =
               Stacks.chosen_for(ctx.scope.organisation, ctx.scope.workspace, target, "explore")

      assert stack_id == stack.id
    end

    test "rows with no choice are not read, the documents of rows with a workflow among them",
         ctx do
      for {_level, place} <- places(ctx), do: put!(ctx, place, doc("level"))

      assert run_harness(ctx) == :none
      assert run_harness(ctx, nil) == :none
    end

    test "a run with no target, or at a target no row of the workspace has, takes no target's stack",
         ctx do
      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("workspace"))
      choose!(ctx, {:target, ctx.target}, doc("target"))

      for target <- [nil, %{system: "system.example", path: "team/elsewhere"}] do
        assert {:chosen, %{level: :workspace}} = run_harness(ctx, target)
      end
    end

    test "another organisation's shared harness is not read", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:organisation, other.organisation}, doc("other"), choice: :qory)

      assert run_harness(ctx) == :none
    end
  end

  describe "harness_hidden" do
    test "is false for a document saved by the run's organisation", ctx do
      choose!(ctx, {:workspace, ctx.scope.workspace}, doc("core"))
      assert {:chosen, %{harness_hidden: false}} = run_harness(ctx)
    end

    test "is true for a document saved by another organisation", ctx do
      %{scope: other} = sign_up_fixture()

      {:ok, _stack} =
        Stacks.put_stack(other, {:workspace, ctx.scope.workspace}, doc("core"),
          choice: :repository
        )

      assert {:chosen, %{harness_hidden: true}} = run_harness(ctx)
    end

    test "is true when the run's organisation is operated", ctx do
      choose!(ctx, {:organisation, ctx.scope.organisation}, doc("core"), :qory)
      :ok = Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert {:chosen, %{harness_hidden: true}} = run_harness(ctx)
    end
  end
end
