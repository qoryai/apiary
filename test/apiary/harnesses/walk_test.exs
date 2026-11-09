defmodule Apiary.Harnesses.WalkTest do
  # The harness walk of an explore run (`Apiary.Harnesses.Walk`) against stub adapters
  # (`Req.Test`): the harness choices, the target's harness file and the Qory harness in
  # their order, two levels of sources, the rule, the pins and the links, each failure, and the job that queues and
  # writes it (`Apiary.Harnesses.WalkJob`). A test work item's run gets the built-in
  # harness unwalked (`Apiary.Harnesses.Builtin`); any other document with its source is
  # walked.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.DispatchedRunsFixtures

  alias Apiary.{Dispatches, Edition, Harnesses, Organisations, Stacks, WorkItems}
  alias Apiary.Adapters.{Calls, Collection, Grant}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{Assignment, Builtin, Reader, RunHarness, Walk, WalkJob, WorkflowGap}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Stacks.{Document, Sources}
  alias Apiary.PublicGitServer
  alias Apiary.QoryHarnessFixture

  @moduletag needs: :factory
  @moduletag :capture_log

  @target "https://code.example.com/acme/app"
  @harness "https://code.example.com/acme/harness"
  @tools "https://code.example.com/acme/tools"
  @lint "https://code.example.com/acme/lint"
  @public "https://public.example.org/qory/stack"
  @commit String.duplicate("0a", 20)
  @commit256 String.duplicate("b1", 32)

  # The base by export, its stack listing one module by git.
  @base_files %{
    {"R_harness", "harness.yaml"} => "exports:\n  stacks: [web]\n",
    {"R_harness", "stacks/web/qory-stack.yaml"} =>
      "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n"
  }

  @file_section "harness:\n  extends: {git: \"#{@harness}\", ref: v1, stack: web}\n"

  setup do
    scope = scope_fixture()
    run = adapter()
    {connection, _nonce} = connection_fixture(scope, run.adapter, :listed)
    grant = grant(scope.organisation.id, run.adapter, connection, "G_run")
    collection(scope, run.adapter, connection)

    input = %{
      organisation: scope.organisation,
      workspace: scope.workspace,
      target: %{system: "code.example.com", path: "acme/app"},
      workflow: "explore"
    }

    %{scope: scope, run: run, connection: connection, grant: grant, input: input}
  end

  ## Setting up

  # An adapter with a call address, persisted, as its start-up declares one, and its seed.
  defp adapter(attrs \\ %{}) do
    %{adapter: adapter, pair: pair} = connectable_adapter_fixture(attrs)
    host = adapter.name <> ".localhost"

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [call_url: "https://#{host}/calls/", call_instance_id: "instance-1"]
      )

    %{adapter: Repo.get!(Node, adapter.id), host: host, seed: pair.secret}
  end

  defp grant(organisation_id, adapter, connection, grant_ref) do
    Repo.insert!(%Grant{
      public_id: Apiary.PublicId.generate(Grant.prefix()),
      organisation_id: organisation_id,
      adapter_id: adapter.id,
      connection_id: connection.id,
      grant_ref: grant_ref,
      state: :live,
      pass_nonce: :crypto.strong_rand_bytes(16),
      granted_at: DateTime.utc_now()
    })
  end

  # The target's collection, at `@target`, of the scope's workspace.
  defp collection(scope, adapter, connection) do
    Repo.insert!(%Collection{
      public_id: Apiary.PublicId.generate(Collection.prefix()),
      organisation_id: scope.organisation.id,
      adapter_id: adapter.id,
      connection_id: connection.id,
      workspace_id: scope.workspace.id,
      external_ref: "R_app",
      url: @target,
      title: "acme/app",
      target_system: "code.example.com",
      target_path: "acme/app",
      environment_ref: "env-1",
      last_listed_at: DateTime.utc_now(:second)
    })
  end

  # The workspace's harness choice, a harness repository with `document`, saved by the
  # scope's person, which applies where the target's file does not; and, where the
  # workspace has no workflow, its row for `explore` with no document. The choice's row.
  defp setting(scope, document) do
    if Stacks.workflow_for(scope.workspace, nil) == nil,
      do: {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "explore"}, nil)

    {:ok, stack} =
      Stacks.put_stack(scope, {:workspace, scope.workspace}, document, choice: :repository)

    stack
  end

  @setting "extends: {git: \"#{@harness}\", ref: v1, stack: web}\n"

  # Sends `test` each call that the trace reports, until `{:done, test}`.
  defp forward(test) do
    receive do
      {:trace, _pid, :call, {Reader, :document, [text]}} ->
        send(test, {:forwarded, {:read, text}})
        forward(test)

      {:done, ^test} ->
        send(test, {:forwarded, :done})
    end
  end

  ## The stub adapters

  # Serves `adapters`' calls: `covered`, by adapter, maps an address to its grant and
  # resource, `{grant_ref, resource_ref}`; `files` maps a resource and a path to a
  # document. A resource's version is `c-<resource>`, whatever the version asked, or its
  # value in `versions`. `refuse` answers every read with a signed refusal, and
  # `refuse_at`, a map of a version a read asks for (`at`) to a code, each read at that
  # version, with a 404; `down` makes every call reach no one. A public repository is
  # served by its host (`public!/2`).
  defp serve(adapters, opts) do
    test = self()
    hosts = Map.new(adapters, &{&1.host, &1})
    covered = Keyword.get(opts, :covered, %{})
    files = Keyword.get(opts, :files, %{})

    Req.Test.stub(Calls, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [host] = Plug.Conn.get_req_header(conn, "host")
      call = Jason.decode!(body)
      path = conn.request_path |> String.split("/") |> List.last()
      send(test, {:walk_call, host, path, Map.drop(call, ["version", "time"])})
      adapter = Map.fetch!(hosts, host)

      cond do
        opts[:down] ->
          Req.Test.transport_error(conn, :econnrefused)

        path == "resolve" and is_nil(opts[:refuse_resolve]) ->
          by_address = Map.get(covered, adapter.adapter.id, %{})

          results =
            for address <- call["addresses"] do
              case by_address[address] do
                {grant_ref, resource_ref} ->
                  %{
                    "address" => address,
                    "grant_ref" => grant_ref,
                    "resource_ref" => resource_ref
                  }

                nil ->
                  %{"address" => address, "covered" => false}
              end
            end

          answer(conn, 200, %{"version" => 1, "revision" => 1, "results" => results}, adapter)

        path == "resolve" and opts[:refuse_resolve] ->
          {status, code} = opts[:refuse_resolve]
          answer(conn, status, %{"error" => code}, adapter)

        refusal = opts[:refuse] ->
          {status, code} = refusal
          answer(conn, status, %{"error" => code}, adapter)

        path == "read" and is_map_key(opts[:refuse_at] || %{}, call["at"]) ->
          answer(conn, 404, %{"error" => opts[:refuse_at][call["at"]]}, adapter)

        path == "read" ->
          version =
            Map.get(opts[:versions] || %{}, call["resource_ref"], "c-" <> call["resource_ref"])

          found =
            case files[{call["resource_ref"], call["path"]}] do
              nil -> %{"found" => false}
              content -> %{"content" => content}
            end

          body = Map.merge(%{"version" => 1, "revision" => 1, "resolved_at" => version}, found)
          answer(conn, 200, body, adapter)
      end
    end)
  end

  defp answer(conn, status, body, adapter) do
    body = Jason.encode!(body)
    [call_signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
    message = SignedMessage.call_answer(status, call_signature, body)
    signature = Ed25519.encode(:crypto.sign(:eddsa, :none, message, [adapter.seed, :ed25519]))

    conn
    |> Plug.Conn.put_resp_header("x-qory-signature-ed25519", signature)
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp calls do
    receive do
      {:walk_call, host, path, call} -> [{host, path, call} | calls()]
    after
      0 -> []
    end
  end

  defp reads(calls),
    do: for({_host, "read", call} <- calls, do: {call["resource_ref"], call["path"], call["at"]})

  # Public repositories, each served by its host (`Apiary.PublicGitServer`), by address:
  # `files`, a map of path to content, or `{files, opts}` with the repository's options.
  # Each repository has one more file whose name no other test's has, so no commit of
  # another test is in the cache. The commit of each, by address.
  defp public!(repositories, opts \\ []) do
    made =
      Map.new(repositories, fn {git, spec} ->
        {files, repository_opts} = if is_tuple(spec), do: spec, else: {spec, []}
        unique = %{".test-#{System.unique_integer([:positive])}" => ""}
        {git, PublicGitServer.repository!(Map.merge(files, unique), repository_opts)}
      end)

    PublicGitServer.serve(Map.new(made, fn {git, repo} -> {git, repo.dir} end), opts)
    Map.new(made, fn {git, repo} -> {git, repo.commit} end)
  end

  # The requests to public hosts so far, `{method, host, path}`.
  defp git_requests do
    receive do
      {:git_request, method, host, path, _headers} -> [{method, host, path} | git_requests()]
    after
      0 -> []
    end
  end

  defp resolves(calls), do: for({_host, "resolve", call} <- calls, do: call["addresses"])

  # The run's adapter covering the target and `more` addresses under `G_run`.
  defp covering(ctx, more \\ %{}) do
    %{
      ctx.run.adapter.id =>
        Map.merge(
          %{@target => {"G_run", "R_app"}, @harness => {"G_run", "R_harness"}},
          more
        )
    }
  end

  ## The target's file and the choice's document

  describe "the row of a workspace made from a template" do
    setup do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
      :ok
    end

    # The template of the stack `web` of `source`, read at `@commit`.
    defp from_template(ctx, source) do
      path = "../../fixtures/harness/v1/sources/factory/modules/support-desk/process.yaml"
      {:ok, read} = __DIR__ |> Path.join(path) |> File.read!() |> Reader.template()
      template = Map.merge(read, %{module: "support-desk", stack: "web"})

      {:ok, workspace} =
        Organisations.create_workspace_from_template(ctx.scope, %{
          source: source,
          commit: @commit,
          template: template
        })

      {:ok, _row} = Stacks.put_stack(ctx.scope, {:workspace, workspace, "explore"}, nil)
      workspace
    end

    # The organisation shares the harness at `ref`, a row the instance's organisation owns.
    defp shared!(ctx, version, ref) do
      document = ~s(extends:\n  git: "#{@harness}"\n  ref: "#{ref}"\n  stack: "web"\n)

      {:ok, _row} =
        Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, document,
          choice: :repository,
          version: version,
          owner: Edition.instance_organisation_id()
        )

      %{
        id: "shared",
        kind: :shared,
        label: "acme/harness",
        git: @harness,
        ref: ref,
        narrowing: %{},
        location: nil,
        version: nil,
        stacks: nil
      }
    end

    # The repository is reached only through the instance's grant, as `assigned` covers it.
    defp through_the_instance(ctx, assigned) do
      %{instance: instance} = instance(ctx, assigned)

      covered =
        ctx
        |> covering()
        |> Map.update!(ctx.run.adapter.id, &Map.delete(&1, @harness))
        |> Map.put(instance.adapter.id, %{
          @harness => {"G_i", "R_harness"},
          @tools => {"G_i", "R_tools"}
        })

      serve([ctx.run, instance], covered: covered, files: @base_files)
    end

    defp row_ref(workspace) do
      {:ok, %{"extends" => %{"ref" => ref}}} =
        Reader.document(Stacks.choice(workspace).harness)

      ref
    end

    test "an assigned source walks at the assignment's ref", ctx do
      through_the_instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])
      source = Enum.find(Sources.assigned(ctx.scope), &(&1.git == @harness))

      workspace = from_template(ctx, source)

      assert row_ref(workspace) == "v1"
      assert {:ok, _walked} = Walk.run(%{ctx.input | workspace: workspace})
    end

    test "a shared source through an assignment of a branch walks at that branch", ctx do
      through_the_instance(ctx, [{@harness, "main"}, {@tools, "v2"}])

      workspace = from_template(ctx, shared!(ctx, {:branch, "main"}, "main"))

      assert row_ref(workspace) == "main"
      assert {:ok, _walked} = Walk.run(%{ctx.input | workspace: workspace})
    end

    test "a shared source through an assignment of a tag walks at that tag", ctx do
      through_the_instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      workspace = from_template(ctx, shared!(ctx, {:tag, "v1"}, "v1"))

      assert row_ref(workspace) == "v1"
      assert {:ok, _walked} = Walk.run(%{ctx.input | workspace: workspace})
    end

    test "a shared source whose ref differs from the live row's keeps the live row's", ctx do
      through_the_instance(ctx, [{@harness, "main"}, {@tools, "v2"}])

      source = %{shared!(ctx, {:branch, "main"}, "main") | ref: "v1"}
      workspace = from_template(ctx, source)

      assert row_ref(workspace) == "main"
      assert {:ok, _walked} = Walk.run(%{ctx.input | workspace: workspace})
    end

    test "a shared source no assignment covers keeps the commit, and walks by the grant", ctx do
      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      workspace = from_template(ctx, shared!(ctx, {:branch, "main"}, "main"))

      assert row_ref(workspace) == @commit
      assert {:ok, _walked} = Walk.run(%{ctx.input | workspace: workspace})
    end

    test "the commit stays where an assignment covers another ref", ctx do
      through_the_instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      workspace = from_template(ctx, shared!(ctx, {:branch, "main"}, "main"))

      assert row_ref(workspace) == @commit

      assert {:failed, %{failure: :not_allowed}} = Walk.run(%{ctx.input | workspace: workspace})
    end
  end

  describe "which harness applies" do
    test "the target's file whose section has extends applies over the workspace's Qory harness choice, and the run gets no document",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@lint}\", ref: v9}\n")

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: Map.put(@base_files, {"R_app", "harness.yaml"}, @file_section)
      )

      assert {:ok, walked} = Walk.run(ctx.input)

      assert %{origin: :file, document: nil, stack_id: nil, harness_hidden: false} = walked
      assert walked.target_version == "c-R_app"
      assert walked.owner_organisation_id == ctx.scope.organisation.id

      assert walked.pins == [
               %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"},
               %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"}
             ]

      grant_id = ctx.grant.id
      adapter_id = ctx.run.adapter.id

      assert [
               %{
                 "grant_id" => ^grant_id,
                 "adapter_id" => ^adapter_id,
                 "grant_ref" => "G_run",
                 "resources" => ["R_harness", "R_tools"]
               }
             ] = walked.harness_links

      calls = calls()

      assert reads(calls) == [
               {"R_app", "harness.yaml", "HEAD"},
               {"R_app", "qory.yaml", "c-R_app"},
               {"R_harness", "harness.yaml", "v1"},
               {"R_harness", "qory.yaml", "c-R_harness"},
               {"R_harness", "stacks/web/qory-stack.yaml", "c-R_harness"},
               {"R_tools", "harness.yaml", "v2"}
             ]

      refute Enum.any?(resolves(calls), &(@lint in &1))
    end

    test "with no file, the choice's document applies, and the target's version is the read's",
         ctx do
      stack = setting(ctx.scope, @setting)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{origin: :setting, target_version: "c-R_app", harness_hidden: false} = walked
      assert walked.stack_id == stack.id

      assert walked.document == %{
               "extends" => %{"git" => @harness, "ref" => "v1", "stack" => "web"}
             }
    end

    test "the document is read once, so its check and its section come from one read", ctx do
      # A second read of a document near the reader's budget of reductions could refuse
      # what the first took. The calls to Reader.document/1 that this process makes are
      # traced to `forward`, which sends them on. The pattern is global, but only this
      # process is traced.
      setting(ctx.scope, @setting)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      test = self()
      forward = spawn_link(fn -> forward(test) end)
      traced = {Reader, :document, 1}
      Code.ensure_loaded!(Reader)
      assert :erlang.trace_pattern(traced, true, [:global]) > 0
      on_exit(fn -> :erlang.trace_pattern(traced, false, [:global]) end)
      :erlang.trace(self(), true, [:call, {:tracer, forward}])

      assert {:ok, %{origin: :setting}} = Walk.run(ctx.input)

      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^ref}
      send(forward, {:done, test})
      assert_receive {:forwarded, :done}

      reads =
        for {:forwarded, {:read, @setting}} <- Process.info(self(), :messages) |> elem(1),
            do: :read

      assert reads == [:read]
    end

    test "a file with machine keys alone, or whose section has neither extends nor modules, takes the document",
         ctx do
      setting(ctx.scope, @setting)

      for file <- [
            "harness:\n  runtime: claude\n",
            "harness:\n  name: app\n",
            "harness:\n  name: app\n  modules: []\n",
            "git:\n  user: someone\n"
          ] do
        serve([ctx.run],
          covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
          files: Map.put(@base_files, {"R_app", "qory.yaml"}, file)
        )

        assert {:ok, %{origin: :setting, target_version: "c-R_app"}} = Walk.run(ctx.input), file
      end
    end

    test "a file whose section lists modules without extends applies over the choice's document, with its modules' sources alone",
         ctx do
      setting(ctx.scope, @setting)

      section =
        "harness:\n  name: app\n  modules:\n" <>
          "    - source: {git: \"#{@tools}\", ref: v2}\n" <>
          "    - source: {path: harness/local}\n"

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: %{
          {"R_app", "harness.yaml"} => section,
          {"R_tools", "qory-stack.yaml"} => "modules:\n  - source: {git: \"#{@lint}\", ref: v3}\n"
        }
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{origin: :file, document: nil, stack_id: nil, target_version: "c-R_app"} = walked
      assert walked.pins == [%{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"}]
      assert [%{"grant_ref" => "G_run", "resources" => ["R_tools"]}] = walked.harness_links

      # The setting's base is never resolved, and the module's stack is not followed.
      calls = calls()
      assert resolves(calls) == [[@target], [@tools]]

      assert reads(calls) == [
               {"R_app", "harness.yaml", "HEAD"},
               {"R_app", "qory.yaml", "c-R_app"},
               {"R_tools", "harness.yaml", "v2"}
             ]
    end

    test "a file that lists modules without extends has its sources checked by the same rules",
         ctx do
      setting(ctx.scope, @setting)

      for {module, failure, source} <- [
            {"{git: \"#{@lint}\", ref: v3}", :not_covered, @lint},
            {"{git: \"git@code.example.com:acme/lint\", ref: v3}", :scp_form,
             "code.example.com:acme/lint"},
            {"{path: ../outside}", :invalid, @target}
          ] do
        serve([ctx.run],
          covered: covering(ctx),
          files: %{{"R_app", "harness.yaml"} => "harness:\n  modules:\n    - source: #{module}\n"}
        )

        assert {:failed, %{failure: ^failure, source: ^source}} = Walk.run(ctx.input), module
      end
    end

    test "a setting without extends is the run's document, with its modules' sources alone",
         ctx do
      document =
        "name: web\nmodules:\n  - source: {git: \"#{@harness}\", ref: v1, module: web}\n" <>
          "workflows:\n  explore: {access: write}\n"

      stack = setting(ctx.scope, document)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{origin: :setting, target_version: "c-R_app"} = walked
      assert walked.stack_id == stack.id

      assert walked.document == %{
               "name" => "web",
               "modules" => [
                 %{"source" => %{"git" => @harness, "ref" => "v1", "module" => "web"}}
               ],
               "workflows" => %{"explore" => %{"access" => "write"}}
             }

      # The module's source is pinned at its root's version; its export is not followed.
      assert walked.pins == [%{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"}]
      assert [%{"resources" => ["R_harness"]}] = walked.harness_links
      calls = calls()
      assert resolves(calls) == [[@target], [@harness]]
      refute Enum.any?(reads(calls), &match?({"R_harness", "stacks/web/qory-stack.yaml", _}, &1))
    end

    test "a target of a domain without harness files is never read, and the run has no target version",
         ctx do
      setting(ctx.scope, @setting)
      scope = with_domain(ctx.scope, "example")

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, %{origin: :setting, target_version: nil}} =
               Walk.run(%{ctx.input | workspace: scope.workspace})

      refute Enum.any?(reads(calls()), &match?({"R_app", _path, _at}, &1))
    end

    test "with neither a file nor a choice, the Qory harness applies, with the target's version",
         ctx do
      serve([ctx.run], covered: covering(ctx))
      qory = Map.put(Domain.definition(Domain.Software).harness, "stack", "software")

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{origin: :setting, target_version: "c-R_app", stack_id: nil} = walked
      assert walked.document == %{"extends" => qory}
    end

    test "both harness.yaml and qory.yaml in the target fail invalid, naming the target", ctx do
      setting(ctx.scope, @setting)

      serve([ctx.run],
        covered: covering(ctx),
        files: %{
          {"R_app", "harness.yaml"} => @file_section,
          {"R_app", "qory.yaml"} => @file_section
        }
      )

      assert {:failed, %{failure: :invalid, source: @target, rule: %{"rule" => "both_files"}}} =
               Walk.run(ctx.input)
    end

    test "both harness files in a remote base fail invalid, naming the base", ctx do
      setting(ctx.scope, @setting)

      serve([ctx.run],
        covered: covering(ctx),
        files: %{
          {"R_harness", "harness.yaml"} => "exports:\n  stacks: [web]\n",
          {"R_harness", "qory.yaml"} => "exports:\n  stacks: [web]\n"
        }
      )

      assert {:failed, %{failure: :invalid, source: @harness, rule: %{"rule" => "both_files"}}} =
               Walk.run(ctx.input)
    end

    test "a base's root file whose exports.modules is no list of text walks on to its stack",
         ctx do
      setting(ctx.scope, @setting)

      for modules <- ["[1]", "core"] do
        root = "exports:\n  stacks: [web]\n  modules: #{modules}\n"

        serve([ctx.run],
          covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
          files: Map.put(@base_files, {"R_harness", "harness.yaml"}, root)
        )

        assert {:ok, walked} = Walk.run(ctx.input), modules

        assert walked.pins == [
                 %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"},
                 %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"}
               ]
      end
    end

    test "a file whose base has a name alone fails invalid, and the rule names the base", ctx do
      serve([ctx.run],
        covered: covering(ctx),
        files: %{{"R_app", "harness.yaml"} => "harness:\n  extends: {stack: web}\n"}
      )

      assert {:failed, %{failure: :invalid, source: @target, rule: rule}} = Walk.run(ctx.input)

      assert %{"message" => "give the base %{name} as a git source" <> _, "values" => values} =
               rule

      assert values == %{"name" => "web"}
    end

    test "a target that no grant of the run's organisation covers fails not_covered", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], covered: %{})
      assert {:failed, %{failure: :not_covered, source: @target}} = Walk.run(ctx.input)
    end
  end

  ## The access level

  describe "the access level" do
    # The base's stack, declaring `workflows` as `declared` writes them, nil for none.
    defp declaring(declared) do
      stack =
        "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n" <>
          if(declared, do: "workflows:\n#{declared}", else: "")

      Map.put(@base_files, {"R_harness", "stacks/web/qory-stack.yaml"}, stack)
    end

    # The workspace's row for `workflow`, with `@setting`, recording `recorded`.
    defp recording(ctx, workflow, recorded) do
      {:ok, stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, workflow}, @setting,
          access: recorded
        )

      stack
    end

    # The level of a walk whose choice's document applies, with the workspace's row for
    # `explore` recording `recorded`, and the base's stack declaring `declared`.
    defp level(ctx, declared, recorded) do
      setting(ctx.scope, @setting)
      recording(ctx, "explore", recorded)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring(declared)
      )

      assert {:ok, %{origin: :setting, access_level: level}} = Walk.run(ctx.input)
      level
    end

    test "declared write, recorded null: write", ctx do
      assert level(ctx, "  explore: {access: write}\n", nil) == :write
    end

    test "declared read, recorded write: read", ctx do
      assert level(ctx, "  explore: {access: read}\n", :write) == :read
    end

    test "no declaration, recorded write: read", ctx do
      for declared <- [nil, "  explore: {time_limit: 45m}\n", "  review: {access: write}\n"] do
        assert level(ctx, declared, :write) == :read, inspect(declared)
      end
    end

    test "no declaration, recorded null: read", ctx do
      for declared <- [nil, "  explore: {time_limit: 45m}\n", "  review: {access: write}\n"] do
        assert level(ctx, declared, nil) == :read, inspect(declared)
      end
    end

    test "declared write, recorded write: write; a value other than write declares read",
         ctx do
      assert level(ctx, "  explore: {access: write}\n", :write) == :write
      assert level(ctx, "  explore: {access: admin}\n", nil) == :read
    end

    # The level of a walk whose target's file `section` applies, with the workspace's row
    # for `explore` recording `recorded`, and the base's stack declaring `declared`.
    defp file_level(ctx, section, declared, recorded) do
      recording(ctx, "explore", recorded)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declared |> declaring() |> Map.put({"R_app", "harness.yaml"}, section)
      )

      assert {:ok, %{origin: :file, access_level: level}} = Walk.run(ctx.input)
      level
    end

    test "a target's file with extends: the base's declared level, lowered by the recorded one",
         ctx do
      write = "  explore: {access: write}\n"

      assert file_level(ctx, @file_section, write, nil) == :write
      assert file_level(ctx, @file_section, write, :write) == :write
      assert file_level(ctx, @file_section, write, :read) == :read
      assert file_level(ctx, @file_section, nil, :write) == :read

      # The section's own workflows declare nothing where it has a base.
      section = @file_section <> "  workflows:\n    explore: {access: write}\n"
      assert file_level(ctx, section, nil, nil) == :read
    end

    test "a target's file that lists modules without extends: its own workflows, lowered by the recorded one",
         ctx do
      section = fn workflows ->
        "harness:\n  modules:\n    - source: {git: \"#{@tools}\", ref: v2}\n" <> workflows
      end

      write = section.("  workflows:\n    explore: {access: write}\n")

      assert file_level(ctx, write, nil, nil) == :write
      assert file_level(ctx, write, nil, :write) == :write
      assert file_level(ctx, write, nil, :read) == :read

      for workflows <- [
            "",
            "  workflows:\n    explore: {time_limit: 45m}\n",
            "  workflows:\n    review: {access: write}\n"
          ] do
        assert file_level(ctx, section.(workflows), nil, nil) == :read, workflows
      end
    end

    test "a setting without extends: its own workflows, lowered by the recorded one", ctx do
      document = fn workflows ->
        "modules:\n  - source: {git: \"#{@harness}\", ref: v1, module: web}\n" <> workflows
      end

      serve([ctx.run], covered: covering(ctx), files: @base_files)

      for {workflows, recorded, expected} <- [
            {"workflows:\n  explore: {access: write}\n", nil, :write},
            {"workflows:\n  explore: {access: write}\n", :write, :write},
            {"workflows:\n  explore: {access: write}\n", :read, :read},
            {"workflows:\n  explore: {access: read}\n", :write, :read},
            {"workflows:\n  review: {access: write}\n", nil, :read},
            {"", nil, :read}
          ] do
        setting(ctx.scope, document.(workflows))

        {:ok, _stack} =
          Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "explore"}, nil,
            access: recorded
          )

        assert {:ok, %{origin: :setting, access_level: ^expected}} = Walk.run(ctx.input),
               inspect({workflows, recorded})
      end
    end

    test "a run whose workflow no row has any longer gets read", ctx do
      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @setting,
          choice: :repository
        )

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring("  explore: {access: write}\n")
      )

      recording(ctx, "explore", nil)
      assert {:ok, %{access_level: :write}} = Walk.run(ctx.input)

      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace, "explore"})
      assert {:ok, %{access_level: :read}} = Walk.run(ctx.input)

      recording(ctx, "review", :write)
      assert {:ok, %{access_level: :read}} = Walk.run(ctx.input)
    end
  end

  ## The sources

  describe "the sources" do
    test "two levels and no third: the base's modules are pinned, never followed", ctx do
      setting(ctx.scope, "extends: {git: \"#{@harness}\", ref: v1}\n")

      files = %{
        {"R_harness", "qory-stack.yaml"} =>
          "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n",
        {"R_tools", "qory-stack.yaml"} => "modules:\n  - source: {git: \"#{@lint}\", ref: v3}\n"
      }

      serve([ctx.run], covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}), files: files)

      assert {:ok, walked} = Walk.run(ctx.input)
      assert Enum.map(walked.pins, & &1["git"]) == [@harness, @tools]

      calls = calls()
      refute Enum.any?(resolves(calls), &(@lint in &1))
      refute Enum.any?(reads(calls), &match?({"R_tools", "qory-stack.yaml", _at}, &1))
    end

    test "a bare root: its qory-stack.yaml, else invalid, as qory reads a base", ctx do
      setting(ctx.scope, "extends: {git: \"#{@harness}\", ref: v1}\n")
      tools = "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n"
      covered = covering(ctx, %{@tools => {"G_run", "R_tools"}})

      serve([ctx.run], covered: covered, files: %{{"R_harness", "qory-stack.yaml"} => tools})
      assert {:ok, %{pins: [_harness, %{"git" => @tools}]}} = Walk.run(ctx.input)
      calls()

      # A root harness section is no stack, whatever modules and workflows it lists.
      section =
        "harness:\n  modules:\n    - source: {git: \"#{@tools}\", ref: v2}\n" <>
          "  workflows:\n    explore: {access: write}\n"

      for files <- [%{{"R_harness", "harness.yaml"} => section}, %{}] do
        serve([ctx.run], covered: covered, files: files)

        assert {:failed,
                %{
                  failure: :invalid,
                  source: @harness,
                  rule: %{"rule" => "no_stack_file", "values" => %{"path" => "qory-stack.yaml"}}
                }} = Walk.run(ctx.input)

        refute Enum.any?(resolves(calls()), &(@tools in &1))
      end
    end

    test "a base that exports no such stack fails invalid", ctx do
      setting(ctx.scope, "extends: {git: \"#{@harness}\", ref: v1, stack: api}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed,
              %{
                failure: :invalid,
                source: @harness,
                rule: %{"rule" => "no_export", "values" => %{"name" => "api"}}
              }} = Walk.run(ctx.input)
    end

    test "a source no adapter covers fails not_covered", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert {:failed, %{failure: :not_covered, source: @tools}} = Walk.run(ctx.input)
    end

    test "another organisation's grant covers nothing for the run: not_covered, not not_allowed",
         ctx do
      setting(ctx.scope, @setting)
      other = scope_fixture()
      {connection, _nonce} = connection_fixture(other, ctx.run.adapter, :listed)
      grant(other.organisation.id, ctx.run.adapter, connection, "G_other")

      serve([ctx.run],
        covered: covering(ctx, %{@harness => {"G_other", "R_harness"}}),
        files: @base_files
      )

      assert {:failed, %{failure: :not_covered, source: @harness}} = Walk.run(ctx.input)
    end

    test "the instance's grant: not_allowed with no assignment; allowed by an assignment of the root",
         ctx do
      setting(ctx.scope, @setting)
      instance = adapter()
      instance_scope = instance_admin_scope()
      {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
      instance_grant = grant(instance_scope.organisation.id, instance.adapter, connection, "G_i")

      covered =
        Map.merge(covering(ctx), %{
          instance.adapter.id => %{@harness => {"G_i", "R_harness"}, @tools => {"G_i", "R_tools"}}
        })
        |> Map.update!(ctx.run.adapter.id, &Map.delete(&1, @harness))

      serve([ctx.run, instance], covered: covered, files: @base_files)

      assert {:failed, %{failure: :not_allowed, source: @harness}} = Walk.run(ctx.input)

      for git <- [@harness, @tools] do
        Repo.insert!(%Assignment{
          organisation_id: ctx.scope.organisation.id,
          every_organisation: false,
          source: %{"git" => git, "ref" => if(git == @harness, do: "v1", else: "v2")},
          created_by_id: instance_scope.user.id
        })
      end

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = instance_grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links
    end

    test "a source no grant covers, at a full commit id, has no link and is not read", ctx do
      setting(
        ctx.scope,
        "extends: {git: \"#{@public}\", ref: \"#{@commit}\", stack: web}\n" <>
          "modules:\n  - source: {git: \"#{@lint}\", ref: \"#{@commit256}\"}\n"
      )

      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.pins == [
               %{"git" => @lint, "ref" => @commit256, "at" => @commit256},
               %{"git" => @public, "ref" => @commit, "at" => @commit}
             ]

      assert walked.harness_links == []
      assert walked.access_level == :read

      assert ComposedConfiguration.stack_hosts(walked.pins) ==
               ["code.example.com", "public.example.org"]

      # Only the target's harness file is read; the base's stack is not followed.
      calls = calls()
      assert resolves(calls) == [[@target], [@public, @lint]]
      assert Enum.all?(reads(calls), &match?({"R_app", _path, _at}, &1))
    end

    test "a source no grant covers, at a branch, a tag or a short id, fails not_covered",
         ctx do
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      for ref <- [
            "main",
            "v1.2.0",
            String.slice(@commit, 0, 12),
            String.slice(@commit, 0, 39),
            @commit <> "0",
            String.upcase(@commit)
          ] do
        setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{ref}\", stack: web}\n")
        assert {:failed, %{failure: :not_covered, source: @public}} = Walk.run(ctx.input)
      end
    end

    test "at a full commit id, another organisation's grant changes nothing: same walk, no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{@commit}\", stack: web}\n")

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert {:ok, without} = Walk.run(ctx.input)

      other = scope_fixture()
      {connection, _nonce} = connection_fixture(other, ctx.run.adapter, :listed)
      grant(other.organisation.id, ctx.run.adapter, connection, "G_other")

      serve([ctx.run],
        covered: covering(ctx, %{@public => {"G_other", "R_public"}}),
        files: @base_files
      )

      calls()
      assert {:ok, with_grant} = Walk.run(ctx.input)

      assert with_grant == without
      assert with_grant.harness_links == []
      assert with_grant.pins == [%{"git" => @public, "ref" => @commit, "at" => @commit}]

      assert ComposedConfiguration.stack_hosts(with_grant.pins) ==
               ComposedConfiguration.stack_hosts(without.pins)

      assert ComposedConfiguration.stack_hosts(with_grant.pins) == ["public.example.org"]
      refute Enum.any?(reads(calls()), &match?({"R_public", _path, _at}, &1))

      # At a branch, both still fail the same way.
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      assert {:failed, %{failure: :not_covered, source: @public}} = Walk.run(ctx.input)
    end

    test "at a full commit id, the instance's grant with no assignment still fails not_allowed",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{@commit}\", stack: web}\n")

      instance = adapter()
      instance_scope = instance_admin_scope()
      {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
      grant(instance_scope.organisation.id, instance.adapter, connection, "G_i")

      serve([ctx.run, instance],
        covered: Map.put(covering(ctx), instance.adapter.id, %{@public => {"G_i", "R_public"}}),
        files: @base_files
      )

      assert {:failed, %{failure: :not_allowed, source: @public}} = Walk.run(ctx.input)
    end

    test "sources with no link on more than 32 hosts compose no run configuration", ctx do
      modules =
        Enum.map_join(
          1..32,
          "",
          &"  - source: {git: \"https://h#{&1}.example.org/public/m\", ref: \"#{@commit}\"}\n"
        )

      setting(
        ctx.scope,
        "extends: {git: \"#{@public}\", ref: \"#{@commit}\"}\nmodules:\n" <> modules
      )

      serve([ctx.run], covered: covering(ctx), files: %{})

      # The walk sends one request to each source's host, to learn whether the host
      # serves the source to anyone, and counts each one. Once no public request is left,
      # a source at a full commit id passes with no request: the walk passes within the
      # default 24 requests.
      assert {:ok, walked} = Walk.run(ctx.input)
      assert Walk.max_calls() == 24
      assert walked.harness_links == []
      hosts = ComposedConfiguration.stack_hosts(walked.pins)
      assert length(hosts) == 33

      members = %{variables: nil, credential: nil, stack_hosts: hosts}

      assert ComposedConfiguration.shape(nil, nil, false, false, members) ==
               {:error, {:stack_hosts_too_many, 33}}
    end

    test "more links than a run takes fail too_many", ctx do
      sources =
        for n <- 1..6, do: "https://code.example.com/acme/m#{n}"

      modules =
        Enum.map_join(sources, "", &"  - source: {git: \"#{&1}\", ref: v1}\n")

      setting(ctx.scope, @setting <> "modules:\n" <> modules)

      more =
        for {source, n} <- Enum.with_index(sources, 1), into: %{} do
          grant(ctx.scope.organisation.id, ctx.run.adapter, ctx.connection, "G_#{n}")
          {source, {"G_#{n}", "R_#{n}"}}
        end

      serve([ctx.run], covered: covering(ctx, more), files: @base_files)
      assert {:failed, %{failure: :too_many}} = Walk.run(ctx.input)
      assert Walk.max_links() == 5
    end

    test "a hidden harness shows no source in its failure", ctx do
      # Saved by an instance admin with no membership here: the instance's organisation
      # owns it, so a run of this organisation hides it.
      admin = %{
        instance_admin_scope()
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      setting(admin, @setting)

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert {:failed, %{failure: :not_covered, source: nil}} = Walk.run(ctx.input)
    end

    test "a hidden harness's save-check message has no name, key, place or schema rule",
         ctx do
      admin = %{
        instance_admin_scope()
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      base = "extends: {git: \"#{@harness}\", ref: v1}\n"
      schema = "modules:\n  - source: {git: \"#{@tools}\", ref: v2, bogus: x}\n"
      repeated = "modules: []\nmodules: []\n"

      walk = fn stack ->
        serve([ctx.run],
          covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
          files: %{{"R_harness", "qory-stack.yaml"} => stack}
        )

        assert {:failed, %{failure: :invalid, rule: rule}} = Walk.run(ctx.input)
        rule
      end

      # Shown: the place and the rule, and the repeated key.
      setting(ctx.scope, base)

      assert %{"message" => "does not follow the harness format at %{place}: %{rule}"} =
               walk.(schema)

      assert %{"message" => "repeats the key %{key}", "message_values" => %{"key" => "modules"}} =
               walk.(repeated)

      # Hidden: none of them.
      setting(admin, base)

      assert walk.(schema) == %{
               "message" => "has a value the harness format does not take",
               "values" => %{}
             }

      assert %{"message" => "repeats a key", "message_values" => %{}} = walk.(repeated)
    end

    test "a stored flat bind fails the walk in the save check's words, hidden or not", ctx do
      admin = %{
        instance_admin_scope()
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      base = "extends: {git: \"#{@harness}\", ref: v1}\n"
      flat = base <> "bind: {agents/developer: web-developer}\n"

      # A row saved before bind was nested: the save refuses a flat bind.
      walk = fn scope ->
        stack = setting(scope, base)
        Repo.update_all(from(s in Stacks.Stack, where: s.id == ^stack.id), set: [harness: flat])
        serve([ctx.run], covered: covering(ctx), files: @base_files)
        assert {:failed, %{failure: :invalid, rule: rule}} = Walk.run(ctx.input)
        rule
      end

      assert %{
               "message" =>
                 "Write bind by kind, then by role, such as " <>
                   "bind: {agents: {developer: web-developer}}: %{key} is a flat key.",
               "values" => %{"key" => "agents/developer"}
             } = walk.(ctx.scope)

      assert walk.(admin) == %{
               "message" => "has a value the harness format does not take",
               "values" => %{}
             }
    end

    test "a hidden harness's rule has no path, ref or stack name", ctx do
      admin = %{
        instance_admin_scope()
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      put = fn document -> setting(admin, document) end

      put.("extends: {git: \"#{@harness}\", ref: v1, stack: api}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed,
              %{failure: :invalid, source: nil, rule: %{"rule" => "no_export", "values" => %{}}}} =
               Walk.run(ctx.input)

      put.("extends: {git: \"#{@harness}\", ref: v1}\n")
      stack = "modules:\n  - source: {path: ../../x}\n"

      serve([ctx.run],
        covered: covering(ctx),
        files: %{{"R_harness", "qory-stack.yaml"} => stack}
      )

      assert {:failed,
              %{failure: :invalid, source: nil, rule: %{"rule" => "path", "values" => %{}}}} =
               Walk.run(ctx.input)

      put.("extends: {git: \"#{@harness}\", ref: v1, path: web}\n")
      serve([ctx.run], covered: covering(ctx), files: %{})

      assert {:failed,
              %{
                failure: :invalid,
                source: nil,
                rule: %{"rule" => "no_stack_file", "values" => %{}}
              }} =
               Walk.run(ctx.input)

      serve([ctx.run], covered: covering(ctx), refuse_at: %{"v1" => "version_not_found"})

      assert {:failed,
              %{failure: :invalid, source: nil, rule: %{"rule" => "version", "values" => %{}}}} =
               Walk.run(ctx.input)
    end
  end

  ## Refused before any call

  ## Public sources

  describe "public sources" do
    # The public base's files: an export whose stack lists `@tools` and declares write.
    @public_files %{
      "harness.yaml" => "exports:\n  stacks: [web]\n",
      "stacks/web/qory-stack.yaml" =>
        "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n" <>
          "workflows:\n  explore: {access: write}\n"
    }

    # An adapter of the instance's organisation, named first in the adapters' order, with
    # its grant `G_i`, and an assignment of `assigned` sources to the run's organisation.
    defp instance(ctx, assigned) do
      instance = adapter(%{name: "aaa-#{System.unique_integer([:positive])}"})
      instance_scope = instance_admin_scope()
      {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
      grant = grant(instance_scope.organisation.id, instance.adapter, connection, "G_i")

      for {git, ref} <- assigned do
        Repo.insert!(%Assignment{
          organisation_id: ctx.scope.organisation.id,
          every_organisation: false,
          source: %{"git" => git, "ref" => ref},
          created_by_id: instance_scope.user.id
        })
      end

      %{instance: instance, grant: grant}
    end

    # No call of any path sends `ref` as a resource.
    defp never_sent(calls, ref) do
      for {_host, path, call} <- calls do
        refute call["resource_ref"] == ref, path
        refute ref in Map.get(call, "resources", []), path
      end
    end

    # A walk whose base is the public source `git` at `main`, its host answering every
    # request with `status` and `body`.
    defp answered(ctx, git, status, body \\ "") do
      setting(ctx.scope, "extends: {git: \"#{git}\", ref: main, stack: web}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      PublicGitServer.serve(%{},
        answer: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(status, body)
        end
      )

      Walk.run(ctx.input)
    end

    test "1. a grant of the run's organisation comes before an assigned grant at an adapter earlier in order",
         ctx do
      setting(ctx.scope, @setting)
      %{instance: instance} = instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      serve([ctx.run, instance],
        covered:
          Map.put(covering(ctx, %{@tools => {"G_run", "R_tools"}}), instance.adapter.id, %{
            @harness => {"G_i", "R_harness"},
            @tools => {"G_i", "R_tools"}
          }),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert git_requests() == []
    end

    test "2. an assignment comes before a read from the host", ctx do
      setting(ctx.scope, @setting)

      %{instance: instance, grant: instance_grant} =
        instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      serve([ctx.run, instance],
        covered:
          Map.put(
            %{ctx.run.adapter.id => %{@target => {"G_run", "R_app"}}},
            instance.adapter.id,
            %{@harness => {"G_i", "R_harness"}, @tools => {"G_i", "R_tools"}}
          ),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = instance_grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert git_requests() == []
    end

    test "3. a source with no link that its host serves to anyone is read from the host: its commit pinned, its stack followed, its access read, no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      %{@public => commit} = public!(%{@public => @public_files})

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.pins == [
               %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"},
               %{"git" => @public, "ref" => "main", "at" => commit}
             ]

      # The base's stack declares write, and no row records a level.
      assert walked.access_level == :write

      # A link for the module alone: the public base is none.
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links

      assert ComposedConfiguration.stack_hosts(walked.pins) ==
               ["code.example.com", "public.example.org"]

      calls = calls()
      assert resolves(calls) == [[@target], [@public], [@tools]]
      assert Enum.all?(reads(calls), &match?({resource, _, _} when resource != "R_public", &1))

      refute Enum.any?(
               calls,
               &match?({_host, path, _call} when path != "resolve" and path != "read", &1)
             )

      requests = git_requests()

      assert Enum.all?(
               requests,
               &match?({_method, "public.example.org", "/qory/stack/" <> _}, &1)
             )

      assert [{"GET", _, "/qory/stack/info/refs"} | _] = requests
    end

    test "3. a public source at a full commit id is read from its host", ctx do
      %{@public => commit} = public!(%{@public => @public_files})
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{commit}\", stack: web}\n")

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{"git" => @public, "ref" => commit, "at" => commit} in walked.pins
      assert walked.access_level == :write
    end

    test "3. another organisation's grant for a public source: read from its host, with no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      other = scope_fixture()
      {connection, _nonce} = connection_fixture(other, ctx.run.adapter, :listed)
      grant(other.organisation.id, ctx.run.adapter, connection, "G_other")
      public!(%{@public => @public_files})

      serve([ctx.run],
        covered: covering(ctx, %{@public => {"G_other", "9001"}, @tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links
      assert walked.access_level == :write
      never_sent(calls(), "9001")
    end

    test "3. the instance's grant with no assignment, and a public source: read from its host, not not_allowed",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      %{instance: instance} = instance(ctx, [])
      public!(%{@public => @public_files})

      serve([ctx.run, instance],
        covered:
          Map.put(covering(ctx, %{@tools => {"G_run", "R_tools"}}), instance.adapter.id, %{
            @public => {"G_i", "9002"}
          }),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links
      never_sent(calls(), "9002")
    end

    test "4. the instance's grant with no assignment, for a source that is not public, fails not_allowed",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      %{instance: instance} = instance(ctx, [])

      serve([ctx.run, instance],
        covered: Map.put(covering(ctx), instance.adapter.id, %{@public => {"G_i", "9002"}}),
        files: @base_files
      )

      assert {:failed, %{failure: :not_allowed, source: @public}} = Walk.run(ctx.input)
    end

    test "5. a source at a branch that is neither linked nor public fails not_covered, after one request",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)
      PublicGitServer.serve(%{})
      assert {:failed, %{failure: :not_covered, source: @public}} = Walk.run(ctx.input)
      assert git_requests() == [{"GET", "public.example.org", "/qory/stack/info/refs"}]
    end

    test "probes of 30 unlinked modules at commits leave the calls of a linked base", ctx do
      modules =
        Enum.map_join(
          1..30,
          "",
          &"  - source: {git: \"https://h#{&1}.example.org/public/m\", ref: \"#{@commit}\"}\n"
        )

      setting(ctx.scope, @setting <> "modules:\n" <> modules)
      PublicGitServer.serve(%{})

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)

      assert %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"} in walked.pins
      assert %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"} in walked.pins
      assert length(walked.pins) == 32
      assert [%{"resources" => ["R_harness", "R_tools"]}] = walked.harness_links
      assert length(git_requests()) == Walk.max_calls()
    end

    test "10 public modules at commits are pinned with no failure, beside a linked, read base",
         ctx do
      gits = for n <- 1..10, do: "https://h#{n}.example.org/public/m"
      commits = public!(Map.new(gits, &{&1, %{"harness.yaml" => "name: m\n"}}))

      modules =
        Enum.map_join(gits, "", &"  - source: {git: \"#{&1}\", ref: \"#{commits[&1]}\"}\n")

      setting(ctx.scope, @setting <> "modules:\n" <> modules)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"} in walked.pins

      for git <- gits do
        assert %{"git" => git, "ref" => commits[git], "at" => commits[git]} in walked.pins
      end

      assert length(git_requests()) <= Walk.max_calls()
    end

    test "with no public request left, a public source at a commit is pinned at it unread, and one at a branch fails the calls rule",
         ctx do
      %{@public => commit} = public!(%{@public => @public_files})

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      # One request is the probe; the read that pins the module has none left.
      module = fn ref -> "modules:\n  - source: {git: \"#{@public}\", ref: #{ref}}\n" end

      setting(ctx.scope, @setting <> module.("\"#{commit}\""))

      assert {:ok, walked} = Walk.run(ctx.input, max_public_calls: 1)
      assert %{"git" => @public, "ref" => commit, "at" => commit} in walked.pins
      assert [%{"resources" => ["R_harness", "R_tools"]}] = walked.harness_links

      setting(ctx.scope, @setting <> module.("main"))

      assert {:failed, %{failure: :invalid, rule: %{"rule" => "calls", "values" => %{"n" => 24}}}} =
               Walk.run(ctx.input, max_public_calls: 1)

      assert {:failed, %{failure: :invalid, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_public_calls: 0)
    end

    test "the adapters' calls and the public requests count apart", ctx do
      setting(ctx.scope, @setting)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert {:ok, _walked} = Walk.run(ctx.input, max_public_calls: 0)

      assert {:failed, %{failure: :invalid, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_calls: 1)
    end

    test "a host that asks for a sign-in serves no public repository: not_covered", ctx do
      for status <- [401, 403] do
        assert {:failed, %{failure: :not_covered, source: @public, rule: nil}} =
                 answered(ctx, @public, status)
      end
    end

    test "a host that serves no git repository fails fetch_failed, with its host and port",
         ctx do
      assert {:failed, %{failure: :fetch_failed, source: @public, rule: rule}} =
               answered(ctx, @public, 200, "<html></html>")

      assert rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "public.example.org", "port" => 443}
             }
    end

    test "a host that answers 429 fails rate_limited at once, with its host and port", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      PublicGitServer.serve(%{},
        answer: fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.send_resp(429, "")
        end
      )

      # Retry-After is not read: the walk fails with no retry, after one request.
      assert {:failed, %{failure: :rate_limited, source: @public, rule: rule}} =
               Walk.run(ctx.input)

      assert rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "public.example.org", "port" => 443}
             }

      assert git_requests() == [{"GET", "public.example.org", "/qory/stack/info/refs"}]
    end

    test "a host on a private address fails host_not_allowed, and gets no request", ctx do
      git = "https://private.example.org:8443/qory/stack"

      assert {:failed, %{failure: :host_not_allowed, source: ^git, rule: rule}} =
               answered(ctx, git, 200)

      assert rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "private.example.org", "port" => 8443}
             }

      assert git_requests() == []
    end

    # A walk of `@public`, whose host redirects to `target`, and every other host answers
    # with `answer`.
    defp redirected(ctx, target, answer) do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      PublicGitServer.serve(%{},
        answer: fn conn ->
          if Plug.Conn.get_req_header(conn, "host") == ["public.example.org"] do
            location = target <> "/qory/stack/info/refs?service=git-upload-pack"

            conn
            |> Plug.Conn.put_resp_header("location", location)
            |> Plug.Conn.send_resp(302, "")
          else
            answer.(conn)
          end
        end
      )

      Walk.run(ctx.input)
    end

    test "a redirect to a host that answers 429 fails rate_limited with that host", ctx do
      assert {:failed, %{failure: :rate_limited, source: @public, rule: rule}} =
               redirected(
                 ctx,
                 "https://mirror.example.org:8443",
                 &Plug.Conn.send_resp(&1, 429, "")
               )

      assert rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "mirror.example.org", "port" => 8443}
             }
    end

    test "a redirect to a port outside 1..65,535 fails with the host that sent it, and the rule stores",
         ctx do
      for port <- ["65536", "0", String.duplicate("9", 131_000)] do
        assert {:failed, %{failure: :fetch_failed, source: @public, rule: rule}} =
                 redirected(
                   ctx,
                   "https://mirror.example.org:#{port}",
                   &Plug.Conn.send_resp(&1, 200, "")
                 )

        assert rule == %{
                 "rule" => "fetch",
                 "values" => %{"host" => "public.example.org", "port" => 443}
               }

        assert rule |> Jason.encode!() |> Jason.decode!() == rule
      end
    end

    test "a redirect to a private address fails host_not_allowed with that host", ctx do
      assert {:failed, %{failure: :host_not_allowed, source: @public, rule: rule}} =
               redirected(
                 ctx,
                 "https://private.example.org",
                 &Plug.Conn.send_resp(&1, 200, "")
               )

      assert rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "private.example.org", "port" => 443}
             }
    end

    test "a redirect to a host out of reach is source_unreachable with that host", ctx do
      assert {:retry, %{failure: :source_unreachable, rule: %{"values" => values}}} =
               redirected(
                 ctx,
                 "https://nowhere.example.org",
                 &Plug.Conn.send_resp(&1, 200, "")
               )

      assert values == %{"host" => "nowhere.example.org", "port" => 443, "seconds" => 10}
    end

    test "a redirect to a host that serves no git repository is fetch_failed with that host",
         ctx do
      assert {:failed, %{failure: :fetch_failed, rule: %{"values" => values}}} =
               redirected(
                 ctx,
                 "https://mirror.example.org",
                 &Plug.Conn.send_resp(&1, 200, "<html></html>")
               )

      assert values == %{"host" => "mirror.example.org", "port" => 443}
    end

    test "a host that is out of reach is a retry, source_unreachable, with the request's seconds",
         ctx do
      git = "https://nowhere.example.org/qory/stack"

      assert {:retry,
              %{
                failure: :source_unreachable,
                source: ^git,
                adapter: nil,
                call_cause: :unreachable,
                rule: %{"rule" => "fetch", "values" => values}
              }} = answered(ctx, git, 200)

      assert values == %{"host" => "nowhere.example.org", "port" => 443, "seconds" => 10}
    end

    test "a harness file over 256 KiB fails too_large", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      public!(%{
        @public => %{"harness.yaml" => "# " <> String.duplicate("a", 256 * 1024) <> "\n"}
      })

      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed, %{failure: :too_large, source: @public, rule: %{"rule" => "fetch"}}} =
               Walk.run(ctx.input)
    end

    test "a ref the host does not list, and a file that is not text, fail invalid", ctx do
      public!(%{@public => Map.put(@public_files, "qory.yaml", <<0, 1>>)})
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: nope, stack: web}\n")

      assert {:failed,
              %{failure: :invalid, source: @public, rule: %{"values" => %{"ref" => "nope"}}}} =
               Walk.run(ctx.input)

      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      assert {:failed, %{failure: :invalid, source: @public, rule: %{"rule" => "not_text"}}} =
               Walk.run(ctx.input)
    end

    test "each request to a public host counts as one of the walk's public requests", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      public!(%{@public => @public_files})

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      # The first walk fills the cache, so the next ones make the same requests.
      assert {:ok, _walked} = Walk.run(ctx.input)
      calls()
      git_requests()
      assert {:ok, _walked} = Walk.run(ctx.input)
      requests = length(git_requests())
      assert requests > 0

      assert {:failed, %{failure: :invalid, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_public_calls: requests - 1)

      assert {:ok, _walked} = Walk.run(ctx.input, max_public_calls: requests)
    end

    test "a private base whose stack lists a public module at a branch: the module is pinned at its commit, with no link",
         ctx do
      setting(ctx.scope, @setting)
      %{@public => commit} = public!(%{@public => %{"lint/harness.yaml" => "name: lint\n"}})

      files =
        Map.put(
          @base_files,
          {"R_harness", "stacks/web/qory-stack.yaml"},
          "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n" <>
            "  - source: {git: \"#{@public}\", ref: main, path: lint}\n"
        )

      serve([ctx.run], covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}), files: files)

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.pins == [
               %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"},
               %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"},
               %{"git" => @public, "ref" => "main", "at" => commit}
             ]

      grant_id = ctx.grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert ComposedConfiguration.stack_hosts(walked.pins) ==
               ["code.example.com", "public.example.org"]
    end

    test "a module source of a public base is checked as any other", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      public!(%{
        @public =>
          Map.put(
            @public_files,
            "stacks/web/qory-stack.yaml",
            "modules:\n  - source: {git: \"https://localhost/acme/tools\", ref: v2}\n"
          )
      })

      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed,
              %{
                failure: :invalid,
                source: "https://localhost/acme/tools",
                rule: %{"rule" => "host"}
              }} =
               Walk.run(ctx.input)
    end

    test "public sources count toward no link: five links and two public modules resolve",
         ctx do
      linked = for n <- 1..4, do: "https://code.example.com/acme/m#{n}"
      public = for n <- 1..2, do: "https://public.example.org/qory/p#{n}"

      modules =
        Enum.map_join(linked ++ public, "", &"  - source: {git: \"#{&1}\", ref: v1}\n")

      setting(ctx.scope, @setting <> "modules:\n" <> modules)
      public!(Map.new(public, &{&1, {%{"harness.yaml" => "name: m\n"}, branches: ["v1"]}}))

      more =
        for {source, n} <- Enum.with_index(linked, 1), into: %{} do
          grant(ctx.scope.organisation.id, ctx.run.adapter, ctx.connection, "G_#{n}")
          {source, {"G_#{n}", "R_#{n}"}}
        end
        |> Map.put(@tools, {"G_run", "R_tools"})

      serve([ctx.run], covered: covering(ctx, more), files: @base_files)
      assert {:ok, walked} = Walk.run(ctx.input)
      assert length(walked.harness_links) == Walk.max_links()

      paths = for {"GET", _host, path} <- git_requests(), uniq: true, do: path
      assert Enum.sort(paths) == ["/qory/p1/info/refs", "/qory/p2/info/refs"]
    end
  end

  describe "the ref of a source in the walk" do
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
      "pull-requests/1/from",
      "changes/01/1/1",
      "notes/x",
      "refs/tags/../pull/1/head",
      "./pull/1/head"
    ]
    # A base's stack whose one module is at a full commit id, so it is not read.
    @ref_stack "modules:\n  - source: {git: \"#{@lint}\", ref: \"#{@commit}\"}\n"

    # A walk of the target's file, which no save check reads, whose base is `git` at
    # `ref`: linked at `R_harness` for `@harness`, or public on its host for `@public`.
    defp walk_ref(ctx, git, ref) do
      serve([ctx.run],
        covered: covering(ctx),
        files: %{
          {"R_app", "harness.yaml"} => "harness:\n  extends: {git: \"#{git}\", ref: '#{ref}'}\n",
          {"R_harness", "qory-stack.yaml"} => @ref_stack
        }
      )

      Walk.run(ctx.input)
    end

    test "each allowed form is read, for a linked and a public source", ctx do
      for ref <- @allowed_refs do
        assert {:ok, walked} = walk_ref(ctx, @harness, ref), ref
        assert Enum.any?(walked.pins, &match?(%{"git" => @harness, "ref" => ^ref}, &1))
        assert {"R_harness", "qory-stack.yaml", ref} in reads(calls())
      end

      # A public repository has the branches and tags it lists, and its commits.
      %{@public => commit} =
        public!(%{
          @public =>
            {%{"qory-stack.yaml" => @ref_stack}, branches: ["release/1.0"], tags: ["v1.2.0"]}
        })

      refs = Enum.reject(@allowed_refs, &(String.length(&1) >= 40)) ++ [commit]

      for ref <- refs do
        assert {:ok, walked} = walk_ref(ctx, @public, ref), ref
        assert %{"git" => @public, "ref" => ref, "at" => commit} in walked.pins
        # The base's stack was read: its module is pinned.
        assert Enum.any?(walked.pins, &match?(%{"git" => @lint}, &1))
      end
    end

    test "another ref under refs/, a short name in another namespace, or a dot part fails invalid before a call, for a linked and a public source",
         ctx do
      for git <- [@harness, @public], ref <- @refused_refs do
        assert {:failed, %{failure: :invalid, source: ^git, rule: rule}} =
                 walk_ref(ctx, git, ref)

        assert rule == %{
                 "message" =>
                   "write the ref %{ref} as HEAD, a branch or tag name, refs/heads/<name>, " <>
                     "refs/tags/<name> or a full commit id: people without write access can " <>
                     "change other refs, such as a pull request's",
                 "values" => %{"ref" => ref}
               }

        assert resolves(calls()) == [[@target]]
        assert git_requests() == []
      end
    end

    test "a module of a public base's stack at another ref under refs/ fails invalid", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main}\n")

      public!(%{
        @public => %{
          "qory-stack.yaml" =>
            "modules:\n  - source: {git: \"#{@tools}\", ref: refs/pull/1/head}\n"
        }
      })

      serve([ctx.run], covered: covering(ctx))

      assert {:failed, %{failure: :invalid, source: @tools, rule: %{"values" => values}}} =
               Walk.run(ctx.input)

      assert values == %{"ref" => "refs/pull/1/head"}
    end

    test "a hidden harness's ref rule has no ref", ctx do
      admin = %{
        instance_admin_scope()
        | organisation: ctx.scope.organisation,
          workspace: ctx.scope.workspace
      }

      setting(admin, "extends: {git: \"#{@harness}\", ref: v1}\n")

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: %{
          {"R_harness", "qory-stack.yaml"} =>
            "modules:\n  - source: {git: \"#{@tools}\", ref: refs/pull/1/head}\n"
        }
      )

      assert {:failed, %{failure: :invalid, source: nil, rule: rule}} = Walk.run(ctx.input)

      assert rule == %{
               "message" =>
                 "write the ref as HEAD, a branch or tag name, refs/heads/<name>, " <>
                   "refs/tags/<name> or a full commit id: people without write access can " <>
                   "change other refs, such as a pull request's",
               "values" => %{}
             }
    end
  end

  describe "refused before any call to resolve a source" do
    setup ctx do
      serve([ctx.run], covered: covering(ctx), files: @base_files)
      :ok
    end

    defp file_with(git), do: "harness:\n  extends: {git: \"#{git}\", ref: v1}\n"

    defp walk_file(ctx, git) do
      serve([ctx.run],
        covered: covering(ctx),
        files: %{{"R_app", "harness.yaml"} => file_with(git)}
      )

      result = Walk.run(ctx.input)
      # The target's resolve is the only one.
      assert resolves(calls()) == [[@target]]
      result
    end

    test "an scp-form source fails scp_form, shown without its user", ctx do
      assert {:failed, %{failure: :scp_form, source: "code.example.com:acme/harness"}} =
               walk_file(ctx, "git@code.example.com:acme/harness")
    end

    test "a source with a user name and password fails credential_in_address, never shown",
         ctx do
      assert {:failed, %{failure: :credential_in_address, source: source} = failure} =
               walk_file(ctx, "https://reader:s3cr3t@code.example.com/acme/harness")

      assert source == "https://code.example.com/acme/harness"
      refute inspect(failure) =~ "s3cr3t"
    end

    test "an IP address or a local name as host fails invalid", ctx do
      for git <- [
            "https://[::1]/r",
            "https://127.0.0.1/r",
            "https://127.1/r",
            "https://0x7f.1/r",
            "https://localhost/r",
            "https://adapter.localhost/r",
            "https://localhost./r",
            "https://a.localhost./r",
            "https://localhost../r",
            "https://127.0.0.1./r"
          ] do
        assert {:failed, %{failure: :invalid, rule: %{"rule" => "host"}}} = walk_file(ctx, git),
               git
      end
    end

    test "a host with a percent-encoding fails invalid: decoded, it may be a local name",
         ctx do
      # A fullwidth "l" (U+FF4C) before "ocalhost", and fullwidth digits for 127.
      for git <- [
            "https://%EF%BD%8Cocalhost/r",
            "https://%EF%BC%91%EF%BC%92%EF%BC%97.0.0.1/r",
            "https://code%C3%A9.example.com/r"
          ] do
        assert {:failed, %{failure: :invalid, rule: %{"rule" => "host_encoded"}}} =
                 walk_file(ctx, git),
               git
      end
    end

    test "a path that leaves its source fails invalid", ctx do
      file = "harness:\n  extends: {git: \"#{@harness}\", ref: v1, path: ../x}\n"
      serve([ctx.run], covered: covering(ctx), files: %{{"R_app", "harness.yaml"} => file})

      assert {:failed,
              %{failure: :invalid, rule: %{"rule" => "path", "values" => %{"path" => "../x"}}}} =
               Walk.run(ctx.input)

      assert resolves(calls()) == [[@target]]

      file = "harness:\n  extends: {path: ../x}\n"
      serve([ctx.run], covered: covering(ctx), files: %{{"R_app", "harness.yaml"} => file})

      assert {:failed, %{failure: :invalid, source: @target, rule: %{"rule" => "path"}}} =
               Walk.run(ctx.input)
    end

    test "a path with a backslash or a percent sign fails invalid, which could spell ..",
         ctx do
      for path <- ["..\\..\\x", "%2e%2e/x", "%2E%2E%2Fx", "a\\b"] do
        calls()

        file =
          "harness:\n  extends: {git: \"#{@harness}\", ref: v1, path: '#{path}'}\n"

        serve([ctx.run], covered: covering(ctx), files: %{{"R_app", "harness.yaml"} => file})

        assert {:failed, %{failure: :invalid, rule: rule}} = Walk.run(ctx.input), path
        assert rule["rule"] == "path_form", path
        assert resolves(calls()) == [[@target]]

        file = "harness:\n  extends: {path: '#{path}'}\n"
        serve([ctx.run], covered: covering(ctx), files: %{{"R_app", "harness.yaml"} => file})

        assert {:failed, %{failure: :invalid, source: @target, rule: %{"rule" => "path_form"}}} =
                 Walk.run(ctx.input),
               path
      end
    end

    test "a local module of a level-2 base that leaves the base fails invalid", ctx do
      setting(ctx.scope, "extends: {git: \"#{@harness}\", ref: v1}\n")

      for {path, name} <- [{"../../x", "path"}, {"/etc", "path"}, {"%2e%2e/x", "path_form"}] do
        stack = "modules:\n  - source: {path: '#{path}'}\n"

        serve([ctx.run],
          covered: covering(ctx),
          files: %{{"R_harness", "qory-stack.yaml"} => stack}
        )

        assert {:failed,
                %{
                  failure: :invalid,
                  source: @harness,
                  rule: %{"rule" => ^name, "values" => %{"path" => ^path}}
                }} = Walk.run(ctx.input),
               path
      end

      stack = "modules:\n  - source: {path: lint}\n"

      serve([ctx.run],
        covered: covering(ctx),
        files: %{{"R_harness", "qory-stack.yaml"} => stack}
      )

      assert {:ok, _walked} = Walk.run(ctx.input)
    end

    test "a local module of a level-2 stack is read from the stack file's folder", ctx do
      setting(ctx.scope, "extends: {git: \"#{@harness}\", ref: v1, path: stacks/web}\n")

      for {path, result} <- [{"../../modules/lint", :ok}, {"../../../x", :leaves}] do
        stack = "modules:\n  - source: {path: '#{path}'}\n"

        serve([ctx.run],
          covered: covering(ctx),
          files: %{{"R_harness", "stacks/web/qory-stack.yaml"} => stack}
        )

        case result do
          :ok ->
            assert {:ok, _walked} = Walk.run(ctx.input), path

          :leaves ->
            assert {:failed,
                    %{
                      failure: :invalid,
                      source: @harness,
                      rule: %{"rule" => "path", "values" => %{"path" => ^path}}
                    }} = Walk.run(ctx.input),
                   path
        end
      end
    end
  end

  ## Calls and limits

  describe "calls" do
    test "a refused read fails final: version_not_found invalid, resource_not_covered not_covered",
         ctx do
      setting(ctx.scope, @setting)

      serve([ctx.run], covered: covering(ctx), refuse: {404, "version_not_found"})

      assert {:failed, %{failure: :invalid, source: @target, rule: rule}} = Walk.run(ctx.input)
      assert rule == %{"rule" => "version", "values" => %{"ref" => "HEAD"}}

      serve([ctx.run], covered: covering(ctx), refuse: {403, "resource_not_covered"})
      assert {:failed, %{failure: :not_covered, source: @target}} = Walk.run(ctx.input)
    end

    test "more calls than a walk takes fail invalid", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed, %{failure: :invalid, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_calls: 3)

      assert length(calls()) == 3
    end

    test "more calls than a walk takes, where the target's file applies, show the target",
         ctx do
      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: Map.put(@base_files, {"R_app", "harness.yaml"}, @file_section)
      )

      assert {:failed, %{failure: :invalid, source: @target, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_calls: 3)

      setting(ctx.scope, @setting)
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed, %{failure: :invalid, source: nil, rule: %{"rule" => "calls"}}} =
               Walk.run(ctx.input, max_calls: 4)
    end

    test "a source shown in a failure is cut at 512 code points, as the row counts them",
         ctx do
      # 300 graphemes of two code points each: "e" and a combining acute accent.
      url = "https://code.example.com/" <> String.duplicate("e\u0301", 300)
      Repo.update_all(Collection, set: [url: url])
      setting(ctx.scope, @setting)
      serve([ctx.run], covered: covering(ctx))

      assert {:failed, %{failure: :not_covered, source: source}} = Walk.run(ctx.input)
      assert source |> String.to_charlist() |> length() == 512
      assert String.starts_with?(url, source)
    end

    test "a document larger than a row stores as JSON fails invalid", ctx do
      # Two items of 20,000 backslashes each: about 40 KB of YAML, and 80 KB of JSON as
      # stored, which escapes each backslash as two. A block list of two long items
      # reads in about 3 ms; a flow list of 20,000 items read in about 60 ms locally
      # and hit the save check's former limit of 200 ms on CI.
      item = String.duplicate("\\", 20_000)
      setting(ctx.scope, @setting <> "extensions:\n  n:\n    - #{item}\n    - #{item}\n")
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:failed,
              %{failure: :invalid, source: nil, rule: %{"rule" => "size", "values" => values}}} =
               Walk.run(ctx.input)

      assert values == %{"n" => 65_536}
    end

    test "an adapter that answers no one is a retry, with its name and the call's cause", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], down: true)

      assert {:retry,
              %{
                failure: :adapter_unavailable,
                adapter: name,
                call_failure: nil,
                call_cause: :unreachable
              }} =
               Walk.run(ctx.input, call_opts: [attempt: 100, total: 500, retry_wait: {1, 2}])

      assert name == ctx.run.adapter.name
    end

    test "a walk out of time is a retry, its call's cause late", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert {:retry, %{failure: :adapter_unavailable, call_cause: :late}} =
               Walk.run(ctx.input, time_limit: 0)
    end
  end

  ## The job

  describe "the job" do
    defp queued(ctx) do
      work_item =
        work_item_fixture(ctx.scope, target_system: "code.example.com", target_path: "acme/app")

      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      run
    end

    defp job(run, attempt \\ 1) do
      perform_job(
        WalkJob,
        %{
          "organisation_id" => run.organisation_id,
          "workspace_id" => run.workspace_id,
          "dispatch_run_id" => run.id
        },
        attempt: attempt
      )
    end

    test "a run with a workflow is pending, with its job, which writes the walk", ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      assert %RunHarness{state: :pending, workflow: "explore-a-ticket"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id}, queue: :harness)

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, origin: :setting, attempts: 1} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.target_version == "c-R_app"
      assert row.access_level == :read
      assert length(row.pins) == 2

      grant_id = ctx.grant.id

      assert Harnesses.entries(run) == [
               %{
                 purpose: :harness,
                 link_id: grant_id,
                 resources: ["R_harness", "R_tools"],
                 access: :read
               }
             ]

      # Run again, it finds the row resolved and calls no adapter.
      calls()
      assert :ok = job(run)
      assert calls() == []
    end

    test "a base no grant covers, at a full commit id, resolves with its pin and no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{@commit}\", stack: web}\n")
      run = queued(ctx)
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, origin: :setting, harness_links: []} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.pins == [%{"git" => @public, "ref" => @commit, "at" => @commit}]
      assert Harnesses.entries(run) == []
    end

    test "a public base resolves with its pin, its host in stack_hosts, and no link or credential",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      run = queued(ctx)

      lint = "https://public.example.org/qory/lint"

      commits =
        public!(%{
          @public => %{
            "harness.yaml" => "exports:\n  stacks: [web]\n",
            "stacks/web/qory-stack.yaml" =>
              "modules:\n  - source: {git: \"#{lint}\", ref: main}\n"
          },
          lint => %{"harness.yaml" => "name: lint\n"}
        })

      serve([ctx.run], covered: covering(ctx))

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, harness_links: []} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.pins == [
               %{"git" => lint, "ref" => "main", "at" => commits[lint]},
               %{"git" => @public, "ref" => "main", "at" => commits[@public]}
             ]

      assert ComposedConfiguration.stack_hosts(row.pins) == ["public.example.org"]
      assert Harnesses.entries(run) == []
    end

    test "a public read that fails ends the run with its code, and the host and port", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      run = queued(ctx)
      serve([ctx.run], covered: covering(ctx))

      PublicGitServer.serve(%{},
        answer: fn conn -> Plug.Conn.send_resp(conn, 200, "<html></html>") end
      )

      assert :ok = job(run)

      assert %RunHarness{state: :failed, failure: "fetch_failed", failed_source: @public} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.failure_rule == %{
               "rule" => "fetch",
               "values" => %{"host" => "public.example.org", "port" => 443}
             }

      assert %DispatchRun{end_detail: "fetch_failed", adapter_failure: nil} =
               Repo.get!(DispatchRun, run.id)
    end

    test "a public host out of reach is tried again, then fails source_unreachable", ctx do
      git = "https://nowhere.example.org/qory/stack"
      setting(ctx.scope, "extends: {git: \"#{git}\", ref: main, stack: web}\n")
      run = queued(ctx)
      serve([ctx.run], covered: covering(ctx))

      assert {:error, :adapter_unavailable} = job(run, 1)
      assert :ok = job(run, 3)

      assert %RunHarness{state: :failed, failure: "source_unreachable", attempts: 3} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.failure_rule["values"] == %{
               "host" => "nowhere.example.org",
               "port" => 443,
               "seconds" => 10
             }

      assert row.failure_adapter == nil
    end

    test "the job writes the access level the walk resolved", ctx do
      setting(ctx.scope, @setting)
      recording(ctx, "explore-a-ticket", nil)
      run = queued(ctx)
      assert Repo.get_by!(RunHarness, dispatch_run_id: run.id).access_level == :read

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring("  explore-a-ticket: {access: write}\n")
      )

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, access_level: :write} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)
    end

    # The workspace's harness choice with `@setting`, with no row with a workflow, and its
    # base's stack declaring `declared`.
    defp declared!(ctx, declared) do
      {:ok, _stack} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @setting,
          choice: :repository
        )

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring(declared)
      )
    end

    # The workspace's process: one stage, with `entry` as its one entry.
    defp process!(ctx, entry) do
      stage = %{
        "id" => "st_r79kph11eg",
        "name" => "Build",
        "inputs" => [],
        "sequence" => [entry],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => [stage]}
      {:ok, _version} = Apiary.Processes.save(ctx.scope, ctx.scope.workspace, document)
    end

    # The access level `run`'s walk writes on its row.
    defp walked_level(run) do
      assert :ok = job(run)

      assert %RunHarness{state: :resolved, access_level: level} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      level
    end

    # The access level of the documents of the next run a machine claims.
    defp claimed_level(ctx), do: claimed_harness(ctx).access

    # The harness members of the documents of the next run a machine claims. The workspace's
    # collections lose their environments, so the claim takes that run and no prebuild.
    defp claimed_harness(ctx) do
      workspace_id = ctx.scope.workspace.id

      {_count, _rows} =
        Repo.update_all(from(c in Collection, where: c.workspace_id == ^workspace_id),
          set: [environment_ref: nil]
        )

      place = handover_place_fixture(ctx.scope)
      body = ~s({"version":1,"time":"2026-10-18T12:00:00Z"})

      {:ok, %{documents: documents}} = Dispatches.claim(place.key, Dispatches.now(), body)
      documents.harness
    end

    @tag needs: [:factory, :workflow_model]
    test "a stage workflow declared write stays write, with no row", ctx do
      declared!(ctx, "  build: {access: write}\n")
      process!(ctx, %{"workflow" => "build"})

      assert walked_level(queued(ctx)) == :write
      assert claimed_level(ctx) == :write
    end

    @tag needs: [:factory, :workflow_model]
    test "a row of another workflow lowers nothing on a stage's run", ctx do
      declared!(ctx, "  build: {access: write}\n")
      recording(ctx, "explore", :read)
      process!(ctx, %{"workflow" => "build"})

      assert walked_level(queued(ctx)) == :write
    end

    @tag needs: [:factory, :workflow_model]
    test "a row with a stage's workflow still lowers its run", ctx do
      declared!(ctx, "  build: {access: write}\n")
      recording(ctx, "build", :read)
      process!(ctx, %{"workflow" => "build"})

      assert walked_level(queued(ctx)) == :read
    end

    @tag needs: [:factory, :workflow_model]
    test "a stage workflow with no declaration stays read, with no row", ctx do
      declared!(ctx, "  review: {access: write}\n")
      process!(ctx, %{"workflow" => "build"})

      assert walked_level(queued(ctx)) == :read
    end

    @tag needs: [:factory, :workflow_model]
    test "a lowered stage entry gets read", ctx do
      declared!(ctx, "  build: {access: write}\n")
      process!(ctx, %{"workflow" => "build", "access" => "read"})

      assert walked_level(queued(ctx)) == :write
      assert claimed_level(ctx) == :read
    end

    @tag needs: [:factory, :workflow_model]
    test "a run moved off a lowered entry onto another workflow's gets read", ctx do
      declared!(ctx, "  build: {access: write}\n")
      process!(ctx, %{"workflow" => "build", "access" => "read"})
      run = queued(ctx)

      {:ok, version} = process!(ctx, %{"workflow" => "lint"})
      work_item = Repo.get!(Apiary.WorkItems.WorkItem, run.work_item_id)
      assert {:ok, _assigned} = Apiary.Processes.assign(ctx.scope, work_item, version)

      assert walked_level(run) == :write
      assert claimed_level(ctx) == :read
    end

    test "a changed or removed row on a run with no stage entry stays read", ctx do
      declared!(ctx, "  explore: {access: write}\n")
      recording(ctx, "explore", nil)
      assert {:ok, %{access_level: :write}} = Walk.run(ctx.input)

      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace, "explore"})
      assert {:ok, %{access_level: :read}} = Walk.run(ctx.input)

      recording(ctx, "review", :write)
      assert {:ok, %{access_level: :read}} = Walk.run(ctx.input)
    end

    test "an adapter that answers no one is tried again, then fails adapter_unavailable", ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)
      serve([ctx.run], down: true)

      assert {:error, :adapter_unavailable} = job(run, 1)

      assert %RunHarness{state: :pending, attempts: 1} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert WalkJob.backoff(%Oban.Job{attempt: 1}) == 10
      assert WalkJob.backoff(%Oban.Job{attempt: 2}) == 30

      assert :ok = job(run, 3)

      assert %RunHarness{state: :failed, failure: "adapter_unavailable", attempts: 3} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.failure_adapter == ctx.run.adapter.name
      assert row.failure_adapter_id == ctx.run.adapter.id
    end

    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, a failed walk escalates the run's stage run_stopped", ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert :ok = job(run)

      assert %Apiary.WorkItems.WorkItem{stage_state: :escalated} =
               Repo.get!(Apiary.WorkItems.WorkItem, run.work_item_id)

      assert %Apiary.Stages.Escalation{cause: :run_stopped, points: [point]} =
               Repo.get_by!(Apiary.Stages.Escalation, work_item_id: run.work_item_id)

      # What could not be read and why, then who fixes it and where.
      org = ctx.scope.organisation.name

      assert point == %{
               "text" =>
                 "The run stopped: #{@tools} is not public, or does not exist, and no connection of #{org} reaches it.",
               "action" => "run_again",
               "fix" =>
                 "Owners and admins of #{org} connect an integration that covers #{@tools} in Organisation settings › Integrations."
             }
    end

    # The stage runner cannot read the work item's questions: the run still ends, and the
    # stage sweep of the lost-run check moves the stage once they can be read.
    @tag needs: [:factory, :workflow_model]
    test "with the workflow model, a failed walk with unreadable questions still ends the run",
         ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)
      work_item = Repo.get!(Apiary.WorkItems.WorkItem, run.work_item_id)
      asked_run = Apiary.StagesFixtures.asked_before!(run)
      path = Apiary.StagesFixtures.unreadable_questions!(ctx.scope, work_item, asked_run)

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      {result, log} = ExUnit.CaptureLog.with_log(fn -> job(run) end)
      assert result == :ok

      assert log =~
               "stage end left for later, newest questions unreadable dispatch_run=#{run.id}"

      assert %DispatchRun{state: :ended, end_cause: :harness_unresolved} =
               Repo.get!(DispatchRun, run.id)

      assert %Apiary.WorkItems.WorkItem{stage_state: :running} =
               Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)

      File.rename!(path <> ".away", path)
      assert {[_], nil} = Apiary.Stages.sweep(Dispatches.now(), nil)

      # Open questions come before a run that stopped.
      assert %Apiary.WorkItems.WorkItem{stage_state: :waiting_answers} =
               Repo.get!(Apiary.WorkItems.WorkItem, work_item.id)
    end

    test "a refusal fails the walk on the first attempt and ends the run harness_unresolved",
         ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert :ok = job(run)

      assert %RunHarness{state: :failed, failure: "not_covered", failed_source: @tools} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert %DispatchRun{
               state: :ended,
               end_cause: :harness_unresolved,
               end_detail: "not_covered",
               result_outcome: :error,
               adapter_failure: nil
             } = Repo.get!(DispatchRun, run.id)

      # The run's record, written when it was queued, ended with it.
      assert %Apiary.Runs.Run{state: "failed", reason: "harness_unresolved"} =
               Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: run.id)
    end

    test "a call that fails otherwise ends the run adapter_failed, with the call it stopped at",
         ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      serve([ctx.run], refuse_resolve: {400, "invalid_request"})
      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = job(run) end)

      # One line in the instance's log, with the run and the failure.
      assert [line] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ "end_cause=harness_unresolved"))

      assert line =~ "failure=adapter_failed run_id=#{run.run_id}"

      assert %RunHarness{state: :failed, failure: "adapter_failed", failed_source: nil} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      adapter_id = ctx.run.adapter.id

      assert %DispatchRun{
               end_cause: :harness_unresolved,
               end_detail: "adapter_failed",
               adapter_failure_id: ^adapter_id,
               adapter_failure: :refused,
               adapter_failure_call: "resolve",
               adapter_failure_code: "invalid_request"
             } = Repo.get!(DispatchRun, run.id)
    end

    test "a claim takes no run whose walk is pending, and takes it once the walk resolved",
         ctx do
      %{key: key} = handover_place_fixture(ctx.scope)
      setting(ctx.scope, @setting)

      # A target no collection has, so no build holds the run: the walk reads no file.
      work_item = work_item_fixture(ctx.scope)
      {:ok, run} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      waiting = fn -> Repo.one(Dispatches.waiting_query(key)) end

      assert waiting.() == nil

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: @base_files
      )

      assert :ok = job(run)
      assert %DispatchRun{id: id} = waiting.()
      assert id == run.id
    end
  end

  ## A test work item's run

  describe "a test work item's run" do
    @builtin_git "https://github.com/qoryai/qory"
    @builtin_ref "main"
    @builtin "extends: {git: \"#{@builtin_git}\", ref: \"#{@builtin_ref}\", path: examples/hello}\n"

    defp test_run!(scope) do
      {:ok, work_item} = WorkItems.take_in_test(scope, "Hello! Where are you running?")
      [run] = Repo.all(from r in DispatchRun, where: r.work_item_id == ^work_item.id)
      run
    end

    # A grant of the instance's organisation covering the built-in source, served with the
    # run's adapter: a walk of that source calls both adapters, and with no assignment
    # fails `not_allowed`.
    defp covering_builtin!(ctx) do
      instance = adapter()
      instance_scope = instance_admin_scope()
      {connection, _nonce} = connection_fixture(instance_scope, instance.adapter, :listed)
      grant(instance_scope.organisation.id, instance.adapter, connection, "G_i")

      covered = Map.put(covering(ctx), instance.adapter.id, %{@builtin_git => {"G_i", "R_qory"}})
      serve([ctx.run, instance], covered: covered, files: @base_files)
    end

    test "is the hello example on main, a document the save rules take" do
      assert Builtin.workflow() == "hello"

      assert Builtin.document() == %{
               "extends" => %{
                 "git" => @builtin_git,
                 "ref" => @builtin_ref,
                 "path" => "examples/hello"
               }
             }

      assert Document.check(@builtin) == {:ok, Builtin.document()}
    end

    test "resolves with the built-in harness when queued, in a software and an example workspace: no job, no call, no link",
         ctx do
      covering_builtin!(ctx)
      example = with_domain(scope_fixture(), "example")

      for scope <- [ctx.scope, example] do
        # The workspace's levels, which a run that is no test would walk.
        setting(scope, @setting)
        recording(%{scope: scope}, "hello", :write)

        run = test_run!(scope)

        assert %RunHarness{
                 state: :resolved,
                 origin: :builtin,
                 workflow: "hello",
                 access_level: :read,
                 target_version: nil,
                 stack_id: nil,
                 owner_organisation_id: nil,
                 harness_hidden: false,
                 harness_links: []
               } = row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

        assert row.document == Builtin.document()
        assert row.pins == [%{"git" => @builtin_git, "ref" => @builtin_ref, "at" => @builtin_ref}]

        # No token: no link to read the source through, and its host for the stack proxy
        # alone.
        assert Harnesses.entries(run) == []
        assert ComposedConfiguration.stack_hosts(row.pins) == ["github.com"]
        refute_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
      end

      assert calls() == []
      assert Repo.aggregate(Assignment, :count) == 0
    end

    test "never reads write: the row's check refuses write, a link, a stack, an owner or a hidden harness",
         ctx do
      run = test_run!(ctx.scope)
      row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)
      stack = setting(ctx.scope, @setting)

      for change <- [
            [access_level: :write],
            [harness_links: [%{"grant_id" => ctx.grant.id, "resources" => ["R_qory"]}]],
            [stack_id: stack.id],
            [owner_organisation_id: ctx.scope.organisation.id],
            [harness_hidden: true]
          ] do
        assert_raise Ecto.ConstraintError, ~r/run_harnesses_builtin_check/, fn ->
          row |> Ecto.Changeset.change(change) |> Repo.update()
        end
      end

      assert Repo.reload!(row).access_level == :read
    end

    test "keeps the built-in harness whatever the workspace's harness choice", ctx do
      covering_builtin!(ctx)

      for choose <- [:qory, :shared, :none] do
        case choose do
          :qory -> {:ok, _stack} = Sources.choose(ctx.scope, :qory)
          :shared -> {:ok, _stack} = Sources.choose(ctx.scope, :qory, shared: true)
          :none -> {:ok, _stack} = Stacks.delete_stack({:organisation, ctx.scope.organisation})
        end

        run = test_run!(ctx.scope)

        assert %RunHarness{state: :resolved, origin: :builtin} =
                 row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

        assert row.document == Builtin.document()
        refute_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
      end

      assert calls() == []
    end

    test "a work item that is no test is walked as before, beside a test", ctx do
      test_run!(ctx.scope)
      run = queued(ctx)

      assert %RunHarness{state: :pending, workflow: "explore-a-ticket"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
    end

    test "any other document with the built-in source has it looked up at the adapters",
         ctx do
      covering_builtin!(ctx)

      # The built-in source's host does not serve it to anyone here, so the walk reads it
      # through a grant only.
      PublicGitServer.serve(%{},
        answer: fn conn ->
          if String.starts_with?(conn.request_path, "/qoryai/qory/"),
            do: Plug.Conn.send_resp(conn, 404, "")
        end
      )

      module =
        "  - source: {git: \"#{@builtin_git}\", ref: \"#{@builtin_ref}\", path: examples/hello}\n"

      # The built-in document itself, and the source as a module's.
      for document <- [@builtin, "modules:\n" <> module] do
        setting(ctx.scope, document)
        calls()

        assert {:failed, %{failure: :not_allowed, source: @builtin_git}} = Walk.run(ctx.input)
        assert [@builtin_git] in resolves(calls())
      end

      # Once an assignment allows the instance's grant, the run reads the source through it.
      Repo.insert!(%Assignment{
        organisation_id: ctx.scope.organisation.id,
        every_organisation: false,
        source: %{"git" => @builtin_git, "ref" => @builtin_ref},
        created_by_id: instance_admin_scope().user.id
      })

      setting(ctx.scope, "modules:\n" <> module)
      calls()
      assert {:ok, walked} = Walk.run(ctx.input)
      assert [%{"resources" => ["R_qory"]}] = walked.harness_links
      assert [@builtin_git] in resolves(calls())
    end
  end

  ## Explore with no row on the Workflow page

  describe "a stage's run of explore-a-ticket" do
    @describetag needs: [:factory, :workflow_model]

    setup do
      :ok = Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
      :ok
    end

    # `ctx` for `workspace`, which takes the target's collection.
    defp moved_to(ctx, %Workspace{} = workspace) do
      organisation_id = ctx.scope.organisation.id

      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.organisation_id == ^organisation_id),
          set: [workspace_id: workspace.id]
        )

      %{ctx | scope: %{ctx.scope | workspace: workspace}}
    end

    # A workspace from a template of the stack `web` of `@harness`, with the process of the
    # copied template, and no row with a workflow.
    defp repository_template!(ctx) do
      path = "../../fixtures/harness/v1/sources/factory/modules/support-desk/process.yaml"
      {:ok, read} = __DIR__ |> Path.join(path) |> File.read!() |> Reader.template()

      template =
        Map.merge(read, %{
          module: "support-desk",
          stack: "web",
          process: Apiary.Processes.default_document("software")
        })

      {:ok, workspace} =
        Organisations.create_workspace_from_template(ctx.scope, %{
          source: shared!(ctx, {:branch, "main"}, "main"),
          commit: @commit,
          template: template
        })

      workspace
    end

    # The run of a work item taken in, walked by its job, and the documents of its claim.
    defp explored!(ctx) do
      assert Stacks.workflow_for(ctx.scope.workspace, nil) == nil
      run = queued(ctx)

      assert %DispatchRun{stage_id: "st_r79kph11eg", workflow: "explore-a-ticket"} = run

      assert %RunHarness{state: :pending, workflow: "explore-a-ticket"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
      assert :ok = job(run)

      assert %RunHarness{state: :resolved, origin: :setting, access_level: :read} =
               walk = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      {run, walk, claimed_harness(ctx)}
    end

    # The run's end with a proposal, which Explore's gate waits on.
    defp at_the_gate?(run) do
      work_item =
        Apiary.WorkItems.WorkItem
        |> Repo.get!(run.work_item_id)
        |> Apiary.StagesFixtures.end_run!(understood_result())

      Enum.any?(Apiary.Artifacts.list(work_item), &(&1.type == "proposal")) and
        work_item.stage_state == :at_gate
    end

    test "a workspace of the Qory template walks it and reads, with the workflow in its documents",
         ctx do
      {:ok, workspace} = Organisations.create_workspace_of_kind(ctx.scope, Domain.Software, :any)
      ctx = moved_to(ctx, workspace)
      serve([ctx.run], covered: covering(ctx), files: %{})

      {_run, walk, documents} = explored!(ctx)

      assert %{"extends" => %{"stack" => "software"}} = walk.document
      assert %{workflow: "explore-a-ticket", access: :read} = documents
      assert %{"extends" => %{"stack" => "software"}} = documents.harness
      assert at_the_gate?(queued(ctx))
    end

    test "a workspace of a repository template walks its stack and reads, with the workflow in its documents",
         ctx do
      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring("  explore-a-ticket: {access: read}\n")
      )

      ctx = moved_to(ctx, repository_template!(ctx))

      {_run, walk, documents} = explored!(ctx)

      assert %{"extends" => %{"stack" => "web"}} = walk.document
      assert %{workflow: "explore-a-ticket", access: :read} = documents
      assert %{"extends" => %{"stack" => "web"}} = documents.harness
      assert at_the_gate?(queued(ctx))
    end

    test "a workspace with no harness row walks the Qory harness, and a gap shows that workflow",
         ctx do
      serve([ctx.run], covered: covering(ctx), files: %{})

      {run, walk, documents} = explored!(ctx)

      assert walk.stack_id == nil
      assert %{workflow: "explore-a-ticket", access: :read} = documents

      %Apiary.Runs.Run{id: id} =
        Repo.get_by!(Apiary.Runs.Run, dispatch_run_id: run.id)

      {1, _rows} =
        Repo.update_all(from(r in Apiary.Runs.Run, where: r.id == ^id),
          set: [reason: "workflow_not_in_harness"]
        )

      assert WorkflowGap.of_dispatch_run(run, nil) ==
               %{workflow: "explore-a-ticket", source: :qory}
    end

    test "a repository template's workspace moved to the Qory harness waits: core lists none",
         ctx do
      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring("  explore-a-ticket: {access: read}\n")
      )

      ctx = moved_to(ctx, repository_template!(ctx))
      workspace = ctx.scope.workspace
      assert workspace.qory_stack == nil

      # The repository's stack listed it, the workspace's snapshot has it.
      assert {:ok, names} = Sources.chosen_workflows(ctx.scope, workspace)
      assert "explore-a-ticket" in names
      :ok = Apiary.Processes.record_declared(workspace, names)

      assert {:ok, _row} = Sources.choose(ctx.scope, :qory)
      assert %{choice: :qory, stack: "core", saved: true} = Sources.chosen(workspace)

      # What the Workflow page, the Stages page and Check again record once it moved.
      assert Sources.chosen_workflows(ctx.scope, workspace) == {:ok, []}
      :ok = Apiary.Processes.record_declared(workspace, [])
      assert Apiary.Processes.declared_workflows(workspace) == []

      work_item =
        work_item_fixture(ctx.scope, target_system: "code.example.com", target_path: "acme/app")

      assert {:ok, nil} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

      assert %Apiary.WorkItems.WorkItem{stage_state: :waiting_workflow} =
               Repo.reload!(work_item)
    end

    test "a row of its workflow lowers it", ctx do
      declared!(ctx, "  explore-a-ticket: {access: write}\n")
      recording(ctx, "explore-a-ticket", :read)

      assert walked_level(queued(ctx)) == :read
    end

    test "a row of its workflow that records write does not raise a declared read", ctx do
      declared!(ctx, "  explore-a-ticket: {access: read}\n")
      recording(ctx, "explore-a-ticket", :write)

      assert walked_level(queued(ctx)) == :read
    end

    test "a row of another workflow gives it neither that name nor that level", ctx do
      declared!(ctx, "  review: {access: write}\n")
      recording(ctx, "review", :write)
      run = queued(ctx)

      assert walked_level(run) == :read

      assert %RunHarness{workflow: "explore-a-ticket"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)
    end

    test "two rows of other workflows leave it its walk", ctx do
      declared!(ctx, "  explore-a-ticket: {access: read}\n")
      recording(ctx, "review", :write)
      recording(ctx, "lint", :write)
      run = queued(ctx)

      assert walked_level(run) == :read

      assert %RunHarness{origin: :setting, workflow: "explore-a-ticket"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)
    end

    test "a level its harness declares stays with no row, and with a row removed", ctx do
      declared!(ctx, "  explore-a-ticket: {access: write}\n")
      assert walked_level(queued(ctx)) == :write

      recording(ctx, "explore-a-ticket", nil)
      run = queued(ctx)
      {:ok, _stack} = Stacks.delete_stack({:workspace, ctx.scope.workspace, "explore-a-ticket"})

      assert walked_level(run) == :write
    end

    test "its entry's read lowers a level its harness declares, at the claim", ctx do
      declared!(ctx, "  explore-a-ticket: {access: write}\n")
      process!(ctx, %{"workflow" => "explore-a-ticket", "access" => "read"})

      assert walked_level(queued(ctx)) == :write
      assert claimed_level(ctx) == :read
    end
  end

  ## The harness choices

  describe "the harness choices" do
    @qory_git "https://github.com/qoryai/harness"
    @qory_ref "main"
    @pin String.duplicate("c3", 20)

    # A harness repository whose root is its stack, with a local module.
    @root_files %{
      {"R_harness", "qory-stack.yaml"} =>
        "modules:\n  - name: core\n    source: {path: modules/core}\n" <>
          "workflows:\n  explore: {access: write}\n"
    }

    # The target's harness file.
    @target_files %{{"R_app", "harness.yaml"} => @file_section}

    defp linked(git), do: %{id: "linked:harness", label: "acme/harness", git: git}

    # The workspace's row for `explore` with a document, which no walk reads.
    defp workflow_row!(ctx) do
      {:ok, _row} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace, "explore"}, @setting)

      :ok
    end

    # A document that extends the stack `web` of `@harness`, with `name`.
    defp named(name), do: "name: #{name}\n" <> @setting

    test "none: the target's file, else the Qory harness of the workspace's type on main, with the target's version; the workflow row's document is not read",
         ctx do
      workflow_row!(ctx)

      assert Domain.definition(Domain.Software).harness == %{
               "git" => @qory_git,
               "ref" => @qory_ref,
               "stack" => "core"
             }

      assert Sources.chosen(ctx.scope.workspace) ==
               %{
                 choice: :qory,
                 git: @qory_git,
                 stack: "software",
                 version: {:branch, "main"},
                 pin: @qory_ref,
                 saved: false,
                 shared: false
               }

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert {:ok, walked} = Walk.run(ctx.input)
      assert walked.origin == :setting

      assert walked.document == %{
               "extends" => %{"git" => @qory_git, "ref" => @qory_ref, "stack" => "software"}
             }

      assert %{target_version: "c-R_app", stack_id: nil, owner_organisation_id: nil} = walked
      refute walked.harness_hidden
      # No adapter covers it: read from its host, with no link, at main's commit.
      assert walked.pins == [
               %{"git" => @qory_git, "ref" => @qory_ref, "at" => QoryHarnessFixture.commit()}
             ]

      assert walked.harness_links == []

      calls = calls()

      assert reads(calls) == [
               {"R_app", "harness.yaml", "HEAD"},
               {"R_app", "qory.yaml", "c-R_app"}
             ]

      assert resolves(calls) == [[@target], [@qory_git]]

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: Map.merge(@base_files, @target_files)
      )

      assert {:ok, %{origin: :file, target_version: "c-R_app"}} = Walk.run(ctx.input)
    end

    test "a workspace with no template: the walk, its choice and a saved row keep the stack core",
         ctx do
      {1, _rows} =
        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.scope.workspace.id),
          set: [qory_stack: nil]
        )

      workspace = Repo.reload!(ctx.scope.workspace)
      core = %{"git" => @qory_git, "ref" => @qory_ref, "stack" => "core"}
      input = %{ctx.input | workspace: workspace}
      workflow_row!(ctx)
      serve([ctx.run], covered: covering(ctx), files: @base_files)

      assert %{choice: :qory, stack: "core", saved: false} = Sources.chosen(workspace)
      assert {:ok, %{document: %{"extends" => ^core}}} = Walk.run(input)

      assert {:ok, _row} = Sources.choose(%{ctx.scope | workspace: workspace}, :qory)
      assert %{choice: :qory, stack: "core", saved: true} = Sources.chosen(workspace)
      assert {:ok, %{document: %{"extends" => ^core}}} = Walk.run(input)
    end

    test "the Qory harness: saved on main with no call to an adapter; the target's file first, else its row's document on main",
         ctx do
      serve([ctx.run], covered: covering(ctx), files: @base_files)
      workflow_row!(ctx)

      assert {:ok, stack} = Sources.choose(ctx.scope, :qory)
      assert calls() == []

      assert %{choice: :qory, workflow: nil, target_id: nil} = stack
      assert stack.workspace_id == ctx.scope.workspace.id

      assert Sources.chosen(ctx.scope.workspace) ==
               %{
                 choice: :qory,
                 git: @qory_git,
                 stack: "software",
                 version: {:branch, "main"},
                 pin: @qory_ref,
                 saved: true,
                 shared: false
               }

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.document == %{
               "extends" => %{"git" => @qory_git, "ref" => @qory_ref, "stack" => "software"}
             }

      assert walked.stack_id == stack.id
      assert walked.owner_organisation_id == ctx.scope.organisation.id
      assert walked.target_version == "c-R_app"
      refute walked.harness_hidden
      assert {"R_app", "harness.yaml", "HEAD"} in reads(calls())

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: Map.merge(@base_files, @target_files)
      )

      assert {:ok, %{origin: :file, target_version: "c-R_app", stack_id: nil}} =
               Walk.run(ctx.input)
    end

    test "a harness repository's root, in the pages' form: the save pins its branch to the commit the walk read; the target's file first, else the walk reads at the pin",
         ctx do
      # The target's file defines a stack: modules without extends.
      target_files = %{
        {"R_app", "harness.yaml"} =>
          "harness:\n  modules:\n    - name: core\n      source: {path: modules/core}\n"
      }

      serve([ctx.run],
        covered: covering(ctx),
        files: Map.merge(@root_files, target_files),
        versions: %{"R_harness" => @pin}
      )

      assert {:ok, stack} = Sources.choose(ctx.scope, {:repository, linked(@harness), " main "})
      assert stack.choice == :repository
      assert stack.version_kind == nil
      assert stack.harness == "extends:\n  git: \"#{@harness}\"\n  ref: \"#{@pin}\"\n"
      assert {"R_harness", "qory-stack.yaml", "main"} in reads(calls())

      assert Sources.chosen(ctx.scope.workspace) ==
               %{
                 choice: :repository,
                 git: @harness,
                 stack: nil,
                 version: nil,
                 pin: @pin,
                 saved: true,
                 shared: false
               }

      # The target's file applies, under the harness repository too.
      assert {:ok, %{origin: :file, stack_id: nil, document: nil}} = Walk.run(ctx.input)
      assert {"R_app", "harness.yaml", "HEAD"} in reads(calls())

      serve([ctx.run],
        covered: covering(ctx),
        files: @root_files,
        versions: %{"R_harness" => @pin}
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert walked.origin == :setting
      assert walked.document == %{"extends" => %{"git" => @harness, "ref" => @pin}}
      assert walked.stack_id == stack.id
      assert walked.target_version == "c-R_app"
      assert walked.pins == [%{"git" => @harness, "ref" => @pin, "at" => @pin}]
      assert [%{"grant_id" => grant_id, "resources" => ["R_harness"]}] = walked.harness_links
      assert grant_id == ctx.grant.id

      assert Enum.all?(reads(calls()), fn {resource, _path, at} ->
               resource == "R_app" or (resource == "R_harness" and at == @pin)
             end)
    end

    test "a harness repository that cannot be read is refused with the walk's reason, and the choice stays",
         ctx do
      refuse = fn opts -> serve([ctx.run], [covered: covering(ctx)] ++ opts) end
      source = linked(@harness)
      {:ok, _choice} = Sources.choose(ctx.scope, :qory)

      refuse.(files: @root_files, refuse: {404, "version_not_found"})

      assert {:error, {:walk, %{failure: :invalid, rule: rule}}} =
               Sources.choose(ctx.scope, {:repository, source, "no-such-branch"})

      assert rule == %{"rule" => "version", "values" => %{"ref" => "no-such-branch"}}

      # The version the read returned is no full commit id.
      refuse.(files: @root_files)

      assert {:error, {:walk, %{failure: :invalid, rule: rule}}} =
               Sources.choose(ctx.scope, {:repository, source, "main"})

      assert rule == %{"rule" => "version", "values" => %{"ref" => "main"}}

      # A module the stack lists from the same repository, at a ref the read does not
      # find: the failure has the module's ref.
      stack = "modules:\n  - source: {git: \"#{@harness}\", ref: no-such-tag}\n"

      refuse.(
        files: %{{"R_harness", "qory-stack.yaml"} => stack},
        versions: %{"R_harness" => @pin},
        refuse_at: %{"no-such-tag" => "version_not_found"}
      )

      assert {:error, {:walk, %{failure: :invalid, source: @harness, rule: rule}}} =
               Sources.choose(ctx.scope, {:repository, source, "main"})

      assert rule == %{"rule" => "version", "values" => %{"ref" => "no-such-tag"}}

      # The root has no stack.
      refuse.(files: %{}, versions: %{"R_harness" => @pin})

      assert {:error, {:walk, %{failure: :invalid, rule: %{"rule" => "no_stack_file"}}}} =
               Sources.choose(ctx.scope, {:repository, source, "main"})

      # No grant of the organisation covers it.
      refuse.(files: @root_files, versions: %{"R_harness" => @pin})
      uncovered = linked("https://code.example.com/acme/elsewhere")

      assert {:error, {:walk, %{failure: :not_covered}}} =
               Sources.choose(ctx.scope, {:repository, uncovered, "main"})

      # A ref the save rules refuse fails before any call.
      calls()

      assert {:error, {:walk, %{failure: :invalid}}} =
               Sources.choose(ctx.scope, {:repository, source, "pull/1/head"})

      assert calls() == []

      assert %{choice: :qory} = Stacks.choice(ctx.scope.workspace)
      assert Sources.choose(ctx.scope, {:repository, nil, "main"}) == {:error, :invalid}
      assert Sources.choose(ctx.scope, :target_file) == {:error, :invalid}
    end

    test "the order: the target's file, a target's stack, the workspace's choice, else the organisation's shared harness, the Qory harness",
         ctx do
      # The target's file in three forms: one that extends a stack, one that lists
      # modules without extends, and one with neither, which is passed over.
      extends = Map.merge(@base_files, @target_files)

      modules =
        Map.put(
          @base_files,
          {"R_app", "harness.yaml"},
          "harness:\n  modules:\n    - name: core\n      source: {path: modules/core}\n"
        )

      neither = Map.put(@base_files, {"R_app", "harness.yaml"}, "harness:\n  name: app\n")
      covered = covering(ctx, %{@tools => {"G_run", "R_tools"}})

      walk = fn files ->
        :ok = serve([ctx.run], covered: covered, files: files)
        Walk.run(ctx.input)
      end

      # Under each choice, a file that sets a harness applies, and one with neither, or
      # none, takes the next place, with the target's version.
      applies = fn name ->
        for files <- [extends, modules] do
          assert {:ok, %{origin: :file, document: nil, target_version: "c-R_app"}} =
                   walk.(files)
        end

        for files <- [neither, @base_files] do
          assert {:ok, walked} = walk.(files)
          assert %{origin: :setting, target_version: "c-R_app"} = walked
          assert walked.document["name"] == name
          walked
        end
      end

      target =
        Repo.insert!(%Apiary.Runs.Target{
          organisation_id: ctx.scope.organisation.id,
          workspace_id: ctx.scope.workspace.id,
          system: "code.example.com",
          path: "acme/app",
          first_seen_at: DateTime.utc_now()
        })

      choose = fn place, name, choice ->
        {:ok, row} = Stacks.put_stack(ctx.scope, place, named(name), choice: choice)
        row
      end

      shared = choose.({:organisation, ctx.scope.organisation}, "shared", :repository)
      workspace = choose.({:workspace, ctx.scope.workspace}, "workspace", :repository)
      by_target = choose.({:target, target}, "target", :repository)

      # 1. The target's file, then 2. a target's stack.
      assert [%{stack_id: id}, %{stack_id: id}] = applies.("target")
      assert id == by_target.id

      # 3. The workspace's choice, before the organisation's shared harness.
      {:ok, _row} = Stacks.delete_stack({:target, target})
      assert [%{stack_id: id}, _walked] = applies.("workspace")
      assert id == workspace.id

      # 3. The shared harness, where the workspace has no choice, a harness repository
      # or the Qory harness.
      {:ok, _row} = Stacks.delete_stack({:workspace, ctx.scope.workspace})
      assert [%{stack_id: id}, _walked] = applies.("shared")
      assert id == shared.id

      # A row of the Qory harness's choice extends the Qory harness.
      qory =
        "name: shared\nextends: {git: \"#{Apiary.Harnesses.Qory.git()}\", ref: main, stack: software}\n"

      {:ok, shared} =
        Stacks.put_stack(ctx.scope, {:organisation, ctx.scope.organisation}, qory, choice: :qory)

      assert [%{stack_id: id}, _walked] = applies.("shared")
      assert id == shared.id

      # 4. The Qory harness, after the target's file.
      {:ok, _row} = Stacks.delete_stack({:organisation, ctx.scope.organisation})
      assert {:ok, %{origin: :file}} = walk.(extends)
      assert {:ok, walked} = walk.(neither)
      assert %{origin: :setting, stack_id: nil, target_version: "c-R_app"} = walked

      assert walked.document == %{
               "extends" =>
                 Map.put(Domain.definition(Domain.Software).harness, "stack", "software")
             }
    end

    test "a target of a domain without harness files: no file is read under any choice", ctx do
      ctx = %{ctx | scope: with_domain(ctx.scope, "example")}
      input = %{ctx.input | workspace: ctx.scope.workspace}

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: Map.merge(@base_files, @target_files)
      )

      {:ok, _row} =
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, named("workspace"),
          choice: :repository
        )

      assert {:ok, %{origin: :setting, target_version: nil}} = Walk.run(input)
      refute Enum.any?(reads(calls()), &match?({"R_app", _path, _at}, &1))
    end

    test "who may: owners and admins; a member saves nothing", ctx do
      %{scope: member} = member_fixture(ctx.scope)
      assert Sources.choose(member, :qory) == {:error, :forbidden}
      assert Stacks.choice(ctx.scope.workspace) == nil

      %{scope: admin} = member_fixture(ctx.scope, :admin)
      assert {:ok, %{choice: :qory}} = Sources.choose(admin, :qory)
    end
  end
end
