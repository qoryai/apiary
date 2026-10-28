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

  alias Apiary.{Dispatches, Harnesses, Stacks, WorkItems}
  alias Apiary.Adapters.{Calls, Collection, Grant}
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{Assignment, Builtin, Reader, RunHarness, Walk, WalkJob}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Policy.ComposedConfiguration
  alias Apiary.Stacks.{Document, Sources}

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

  # The workspace's harness choice, the Qory harness with `document`, saved by the scope's
  # person, which applies where the target's file does not; and, where the workspace has
  # no workflow, its row for `explore` with no document. The choice's row.
  defp setting(scope, document) do
    if Stacks.workflow_for(scope.workspace, nil) == nil,
      do: {:ok, _row} = Stacks.put_stack(scope, {:workspace, scope.workspace, "explore"}, nil)

    {:ok, stack} = Stacks.put_stack(scope, {:workspace, scope.workspace}, document, choice: :qory)
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
  # resource, `{grant_ref, resource_ref}`, to those and its public ref, `{grant_ref,
  # resource_ref, {:public, public_ref}}`, or to its public ref alone, `{:public,
  # public_ref}`, whose resource_ref is `N_<public_ref>`; `files` maps a resource or a
  # public ref and a path to a document, read with a grant or as public. A resource's
  # version is `c-<resource>`, whatever the version asked, or its value in `versions`.
  # `refuse` answers every read with a signed refusal, `refuse_public` every public read,
  # and `refuse_at`, a map of a version a read asks for (`at`) to a code, each read at that
  # version, with a 404; `down` makes every call reach no one.
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
                {:public, public_ref} ->
                  %{
                    "address" => address,
                    "resource_ref" => "N_" <> public_ref,
                    "public" => true,
                    "public_ref" => public_ref
                  }

                {grant_ref, resource_ref, {:public, public_ref}} ->
                  %{
                    "address" => address,
                    "grant_ref" => grant_ref,
                    "resource_ref" => resource_ref,
                    "public" => true,
                    "public_ref" => public_ref
                  }

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

        path in ["read", "read-public"] and is_map_key(opts[:refuse_at] || %{}, call["at"]) ->
          answer(conn, 404, %{"error" => opts[:refuse_at][call["at"]]}, adapter)

        path == "read-public" and opts[:refuse_public] ->
          {status, code} = opts[:refuse_public]
          answer(conn, status, %{"error" => code}, adapter)

        path in ["read", "read-public"] ->
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

  defp public_reads(calls),
    do:
      for(
        {_host, "read-public", call} <- calls,
        do: {call["resource_ref"], call["path"], call["at"]}
      )

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
      qory = Domain.definition(Domain.Software).harness

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
        Stacks.put_stack(ctx.scope, {:workspace, ctx.scope.workspace}, @setting, choice: :qory)

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

      assert {:ok, walked} = Walk.run(ctx.input)
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
      {"R_public", "harness.yaml"} => "exports:\n  stacks: [web]\n",
      {"R_public", "stacks/web/qory-stack.yaml"} =>
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

    defp no_reads_of(calls, resource),
      do: refute(Enum.any?(reads(calls), &match?({^resource, _path, _at}, &1)))

    # No call of any path sends `ref` as a resource.
    defp never_sent(calls, ref) do
      for {_host, path, call} <- calls do
        refute call["resource_ref"] == ref, path
        refute ref in Map.get(call, "resources", []), path
      end
    end

    test "1. a grant of the run's organisation comes before an assigned grant at an adapter earlier in order",
         ctx do
      setting(ctx.scope, @setting)
      %{instance: instance} = instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      serve([ctx.run, instance],
        covered:
          Map.put(covering(ctx, %{@tools => {"G_run", "R_tools"}}), instance.adapter.id, %{
            @harness => {"G_i", "R_harness", {:public, "P_harness"}},
            @tools => {"G_i", "R_tools", {:public, "P_tools"}}
          }),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert public_reads(calls()) == []
    end

    test "2. an assignment comes before a public result", ctx do
      setting(ctx.scope, @setting)

      %{instance: instance, grant: instance_grant} =
        instance(ctx, [{@harness, "v1"}, {@tools, "v2"}])

      serve([ctx.run, instance],
        covered:
          Map.put(
            %{ctx.run.adapter.id => %{@target => {"G_run", "R_app"}}},
            instance.adapter.id,
            %{
              @harness => {"G_i", "R_harness", {:public, "P_harness"}},
              @tools => {"G_i", "R_tools", {:public, "P_tools"}}
            }
          ),
        files: @base_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = instance_grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert public_reads(calls()) == []
    end

    test "3. a public result with no grant is read as public: its ref pinned, its stack followed, its access read, no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      serve([ctx.run],
        covered:
          covering(ctx, %{@public => {:public, "R_public"}, @tools => {"G_run", "R_tools"}}),
        files: @public_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.pins == [
               %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"},
               %{"git" => @public, "ref" => "main", "at" => "c-R_public"}
             ]

      # The base's stack declares write, and no row records a level.
      assert walked.access_level == :write

      # A link for the module alone: the public base is none.
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links

      assert ComposedConfiguration.stack_hosts(walked.pins) ==
               ["code.example.com", "public.example.org"]

      calls = calls()

      assert public_reads(calls) == [
               {"R_public", "harness.yaml", "main"},
               {"R_public", "qory.yaml", "c-R_public"},
               {"R_public", "stacks/web/qory-stack.yaml", "c-R_public"}
             ]

      no_reads_of(calls, "R_public")
      never_sent(calls, "N_R_public")
      assert resolves(calls) == [[@target], [@public], [@tools]]
      refute Enum.any?(calls, &match?({_host, "run-credential", _call}, &1))
    end

    test "3. a public result comes before a full commit id: the source is read", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: \"#{@commit}\", stack: web}\n")

      serve([ctx.run],
        covered:
          covering(ctx, %{@public => {:public, "R_public"}, @tools => {"G_run", "R_tools"}}),
        files: @public_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert %{"git" => @public, "ref" => @commit, "at" => "c-R_public"} in walked.pins
      assert {"R_public", "harness.yaml", @commit} in public_reads(calls())
    end

    test "3. another organisation's covered and public result: read at its public_ref, never its resource_ref, with no link",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      other = scope_fixture()
      {connection, _nonce} = connection_fixture(other, ctx.run.adapter, :listed)
      grant(other.organisation.id, ctx.run.adapter, connection, "G_other")

      serve([ctx.run],
        covered:
          covering(ctx, %{
            @public => {"G_other", "9001", {:public, "R_public"}},
            @tools => {"G_run", "R_tools"}
          }),
        files: @public_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links

      calls = calls()
      assert {"R_public", "harness.yaml", "main"} in public_reads(calls)
      no_reads_of(calls, "R_public")
      never_sent(calls, "9001")
    end

    test "3. another organisation's covered and public base and module: each public read is at the public_ref",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      other = scope_fixture()
      {connection, _nonce} = connection_fixture(other, ctx.run.adapter, :listed)
      grant(other.organisation.id, ctx.run.adapter, connection, "G_other")

      serve([ctx.run],
        covered:
          covering(ctx, %{
            @public => {"G_other", "9001", {:public, "R_public"}},
            @tools => {"G_other", "9003", {:public, "R_tools"}}
          }),
        files: @public_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      assert walked.access_level == :write
      assert walked.harness_links == []

      calls = calls()

      # The base's first read, its exports, its stack followed with the access it declares,
      # and the module's version.
      assert public_reads(calls) == [
               {"R_public", "harness.yaml", "main"},
               {"R_public", "qory.yaml", "c-R_public"},
               {"R_public", "stacks/web/qory-stack.yaml", "c-R_public"},
               {"R_tools", "harness.yaml", "v2"}
             ]

      assert reads(calls) == [
               {"R_app", "harness.yaml", "HEAD"},
               {"R_app", "qory.yaml", "c-R_app"}
             ]

      never_sent(calls, "9001")
      never_sent(calls, "9003")
    end

    test "3. the instance's grant with no assignment and a public result: read as public, not not_allowed",
         ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      %{instance: instance} = instance(ctx, [])

      serve([ctx.run, instance],
        covered:
          Map.put(covering(ctx, %{@tools => {"G_run", "R_tools"}}), instance.adapter.id, %{
            @public => {"G_i", "9002", {:public, "R_public"}}
          }),
        files: @public_files
      )

      assert {:ok, walked} = Walk.run(ctx.input)
      grant_id = ctx.grant.id
      assert [%{"grant_id" => ^grant_id, "resources" => ["R_tools"]}] = walked.harness_links

      calls = calls()

      assert [{instance_host, "read-public", _call} | _] =
               for({_host, "read-public", _call} = call <- calls, do: call)

      assert instance_host == instance.host
      no_reads_of(calls, "R_public")
      never_sent(calls, "9002")
    end

    test "3. the first public result in the adapters' order is read", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      %{instance: first} = instance(ctx, [])

      serve([ctx.run, first],
        covered:
          Map.put(
            covering(ctx, %{@public => {:public, "R_public"}, @tools => {"G_run", "R_tools"}}),
            first.adapter.id,
            %{@public => {:public, "R_public"}}
          ),
        files: @public_files
      )

      assert {:ok, _walked} = Walk.run(ctx.input)
      hosts = for {host, "read-public", _call} <- calls(), uniq: true, do: host
      assert hosts == [first.host]
    end

    test "5. a source at a branch that no adapter answers public fails not_covered", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      serve([ctx.run], covered: covering(ctx), files: @public_files)
      assert {:failed, %{failure: :not_covered, source: @public}} = Walk.run(ctx.input)
      assert public_reads(calls()) == []
    end

    test "a public read refused resource_not_public fails not_covered", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      serve([ctx.run],
        covered: covering(ctx, %{@public => {:public, "R_public"}}),
        files: @public_files,
        refuse_public: {403, "resource_not_public"}
      )

      assert {:failed, %{failure: :not_covered, source: @public}} = Walk.run(ctx.input)
    end

    test "a private base whose stack lists a public module at a branch: the module is pinned, with no link",
         ctx do
      setting(ctx.scope, @setting)

      files =
        Map.put(
          @base_files,
          {"R_harness", "stacks/web/qory-stack.yaml"},
          "modules:\n  - source: {git: \"#{@tools}\", ref: v2}\n" <>
            "  - source: {git: \"#{@public}\", ref: main, path: lint}\n"
        )

      serve([ctx.run],
        covered:
          covering(ctx, %{@tools => {"G_run", "R_tools"}, @public => {:public, "R_public"}}),
        files: files
      )

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.pins == [
               %{"git" => @harness, "ref" => "v1", "at" => "c-R_harness"},
               %{"git" => @tools, "ref" => "v2", "at" => "c-R_tools"},
               %{"git" => @public, "ref" => "main", "at" => "c-R_public"}
             ]

      grant_id = ctx.grant.id

      assert [%{"grant_id" => ^grant_id, "resources" => ["R_harness", "R_tools"]}] =
               walked.harness_links

      assert ComposedConfiguration.stack_hosts(walked.pins) ==
               ["code.example.com", "public.example.org"]

      calls = calls()
      assert public_reads(calls) == [{"R_public", "harness.yaml", "main"}]
      no_reads_of(calls, "R_public")
    end

    test "a module source of a public base is checked as any other", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")

      files =
        Map.put(
          @public_files,
          {"R_public", "stacks/web/qory-stack.yaml"},
          "modules:\n  - source: {git: \"https://localhost/acme/tools\", ref: v2}\n"
        )

      serve([ctx.run], covered: covering(ctx, %{@public => {:public, "R_public"}}), files: files)

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

      more =
        for {source, n} <- Enum.with_index(linked, 1), into: %{} do
          grant(ctx.scope.organisation.id, ctx.run.adapter, ctx.connection, "G_#{n}")
          {source, {"G_#{n}", "R_#{n}"}}
        end
        |> Map.merge(
          Map.new(Enum.with_index(public, 1), fn {s, n} -> {s, {:public, "R_p#{n}"}} end)
        )
        |> Map.put(@tools, {"G_run", "R_tools"})

      serve([ctx.run], covered: covering(ctx, more), files: @base_files)
      assert {:ok, walked} = Walk.run(ctx.input)
      assert length(walked.harness_links) == Walk.max_links()

      assert Enum.sort(public_reads(calls())) == [
               {"R_p1", "harness.yaml", "v1"},
               {"R_p2", "harness.yaml", "v1"}
             ]
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
    # `ref`: linked at `R_harness` for `@harness`, public at `R_public` for `@public`.
    defp walk_ref(ctx, git, ref) do
      serve([ctx.run],
        covered: covering(ctx, %{@public => {:public, "R_public"}}),
        files: %{
          {"R_app", "harness.yaml"} => "harness:\n  extends: {git: \"#{git}\", ref: '#{ref}'}\n",
          {"R_harness", "qory-stack.yaml"} => @ref_stack,
          {"R_public", "qory-stack.yaml"} => @ref_stack
        }
      )

      Walk.run(ctx.input)
    end

    test "each allowed form is read, for a linked and a public source", ctx do
      for git <- [@harness, @public], ref <- @allowed_refs do
        assert {:ok, walked} = walk_ref(ctx, git, ref), "#{git} #{ref}"
        assert Enum.any?(walked.pins, &match?(%{"git" => ^git, "ref" => ^ref}, &1))
        calls = calls()

        {resource, read} =
          if git == @harness,
            do: {"R_harness", reads(calls)},
            else: {"R_public", public_reads(calls)}

        assert {resource, "qory-stack.yaml", ref} in read
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
      end
    end

    test "a module of a public base's stack at another ref under refs/ fails invalid", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main}\n")

      serve([ctx.run],
        covered: covering(ctx, %{@public => {:public, "R_public"}}),
        files: %{
          {"R_public", "qory-stack.yaml"} =>
            "modules:\n  - source: {git: \"#{@tools}\", ref: refs/pull/1/head}\n"
        }
      )

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

    test "an adapter that answers no one is a retry, with its name", ctx do
      setting(ctx.scope, @setting)
      serve([ctx.run], down: true)

      assert {:retry, %{failure: :adapter_unavailable, adapter: name}} =
               Walk.run(ctx.input, call_opts: [attempt: 100, total: 500, retry_wait: {1, 2}])

      assert name == ctx.run.adapter.name
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

    test "a run of a workspace with no workflow gets a row resolved with no origin read, and no job",
         ctx do
      run = queued(ctx)

      assert %RunHarness{state: :resolved, origin: :none, workflow: nil} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      refute_enqueued(worker: WalkJob)
      assert Harnesses.entries(run) == []
    end

    test "a run with a workflow is pending, with its job, which writes the walk", ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      assert %RunHarness{state: :pending, workflow: "explore"} =
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

      serve([ctx.run],
        covered:
          covering(ctx, %{
            @public => {:public, "R_public"},
            "https://public.example.org/qory/lint" => {:public, "R_lint"}
          }),
        files: %{
          {"R_public", "harness.yaml"} => "exports:\n  stacks: [web]\n",
          {"R_public", "stacks/web/qory-stack.yaml"} =>
            "modules:\n  - source: {git: \"https://public.example.org/qory/lint\", ref: main}\n"
        }
      )

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, harness_links: []} =
               row = Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert row.pins == [
               %{
                 "git" => "https://public.example.org/qory/lint",
                 "ref" => "main",
                 "at" => "c-R_lint"
               },
               %{"git" => @public, "ref" => "main", "at" => "c-R_public"}
             ]

      assert ComposedConfiguration.stack_hosts(row.pins) == ["public.example.org"]
      assert Harnesses.entries(run) == []
    end

    test "a public read that fails otherwise ends the run adapter_failed, at the read", ctx do
      setting(ctx.scope, "extends: {git: \"#{@public}\", ref: main, stack: web}\n")
      run = queued(ctx)

      serve([ctx.run],
        covered: covering(ctx, %{@public => {:public, "R_public"}}),
        refuse_public: {400, "invalid_request"}
      )

      assert :ok = job(run)
      adapter_id = ctx.run.adapter.id

      assert %DispatchRun{
               end_detail: "adapter_failed",
               adapter_failure_id: ^adapter_id,
               adapter_failure: :refused,
               adapter_failure_call: "read",
               adapter_failure_code: "invalid_request"
             } = Repo.get!(DispatchRun, run.id)
    end

    test "the job writes the access level the walk resolved", ctx do
      setting(ctx.scope, @setting)
      recording(ctx, "explore", nil)
      run = queued(ctx)
      assert Repo.get_by!(RunHarness, dispatch_run_id: run.id).access_level == :read

      serve([ctx.run],
        covered: covering(ctx, %{@tools => {"G_run", "R_tools"}}),
        files: declaring("  explore: {access: write}\n")
      )

      assert :ok = job(run)

      assert %RunHarness{state: :resolved, access_level: :write} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)
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
    end

    test "a call that fails otherwise ends the run adapter_failed, with the call it stopped at",
         ctx do
      setting(ctx.scope, @setting)
      run = queued(ctx)

      serve([ctx.run], refuse_resolve: {400, "invalid_request"})
      assert :ok = job(run)

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
    @builtin_ref "2148b3ae11eff8ccbeb93d1a7c10aeb05595c95b"
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

    test "is the hello example at its commit, a document the save rules take" do
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
      end

      refute_enqueued(worker: WalkJob)
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
      end

      refute_enqueued(worker: WalkJob)
      assert calls() == []
    end

    test "a work item that is no test is walked as before, beside a test", ctx do
      test_run!(ctx.scope)

      assert %RunHarness{origin: :none} =
               Repo.get_by!(RunHarness, dispatch_run_id: queued(ctx).id)

      setting(ctx.scope, @setting)
      run = queued(ctx)

      assert %RunHarness{state: :pending, workflow: "explore"} =
               Repo.get_by!(RunHarness, dispatch_run_id: run.id)

      assert_enqueued(worker: WalkJob, args: %{"dispatch_run_id" => run.id})
    end

    test "any other document with the built-in source has it looked up at the adapters",
         ctx do
      covering_builtin!(ctx)

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

  ## The harness choices

  describe "the harness choices" do
    @qory_git "https://github.com/qoryai/harness"
    @qory_ref "fe3b3ab4a02cd7c57d9efa16bbaf498d5f5de305"
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

    test "none: the target's file, else the Qory harness of the workspace's type at its pin, with the target's version; the workflow row's document is not read",
         ctx do
      workflow_row!(ctx)

      assert Domain.definition(Domain.Software).harness == %{
               "git" => @qory_git,
               "ref" => @qory_ref,
               "stack" => "core"
             }

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :qory, git: @qory_git, pin: @qory_ref, saved: false, shared: false}

      serve([ctx.run], covered: covering(ctx), files: @base_files)
      assert {:ok, walked} = Walk.run(ctx.input)
      assert walked.origin == :setting

      assert walked.document == %{
               "extends" => %{"git" => @qory_git, "ref" => @qory_ref, "stack" => "core"}
             }

      assert %{target_version: "c-R_app", stack_id: nil, owner_organisation_id: nil} = walked
      refute walked.harness_hidden
      # No adapter covers it: pinned at its commit, with no link, and not read.
      assert walked.pins == [%{"git" => @qory_git, "ref" => @qory_ref, "at" => @qory_ref}]
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

    test "the Qory harness: saved with no read; the target's file first, else its row's document at its pin",
         ctx do
      serve([ctx.run], covered: covering(ctx), files: @base_files)
      workflow_row!(ctx)

      assert {:ok, stack} = Sources.choose(ctx.scope, :qory)
      assert calls() == []

      assert %{choice: :qory, workflow: nil, target_id: nil} = stack
      assert stack.workspace_id == ctx.scope.workspace.id

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :qory, git: @qory_git, pin: @qory_ref, saved: true, shared: false}

      assert {:ok, walked} = Walk.run(ctx.input)

      assert walked.document == %{
               "extends" => %{"git" => @qory_git, "ref" => @qory_ref, "stack" => "core"}
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

    test "a harness repository: the save pins its branch to the commit the walk read, and the walk reads there, not the target's file",
         ctx do
      serve([ctx.run],
        covered: covering(ctx),
        files: Map.merge(@root_files, @target_files),
        versions: %{"R_harness" => @pin}
      )

      assert {:ok, stack} = Sources.choose(ctx.scope, {:repository, linked(@harness), " main "})
      assert stack.choice == :repository
      assert stack.harness == "extends:\n  git: \"#{@harness}\"\n  ref: \"#{@pin}\"\n"
      assert {"R_harness", "qory-stack.yaml", "main"} in reads(calls())

      assert Sources.chosen(ctx.scope.workspace) ==
               %{choice: :repository, git: @harness, pin: @pin, saved: true, shared: false}

      assert {:ok, walked} = Walk.run(ctx.input)
      assert walked.origin == :setting
      assert walked.document == %{"extends" => %{"git" => @harness, "ref" => @pin}}
      assert walked.stack_id == stack.id
      assert walked.target_version == nil
      assert walked.pins == [%{"git" => @harness, "ref" => @pin, "at" => @pin}]
      assert [%{"grant_id" => grant_id, "resources" => ["R_harness"]}] = walked.harness_links
      assert grant_id == ctx.grant.id

      reads = reads(calls())
      assert reads != []

      assert Enum.all?(reads, fn {resource, _path, at} ->
               resource == "R_harness" and at == @pin
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

    test "the order: a target's stack, the workspace's choice, the organisation's shared harness, the target's file, the Qory harness",
         ctx do
      files = Map.merge(@base_files, @target_files)
      covered = covering(ctx, %{@tools => {"G_run", "R_tools"}})

      walk = fn files ->
        :ok = serve([ctx.run], covered: covered, files: files)
        Walk.run(ctx.input)
      end

      target_reads = fn -> Enum.filter(reads(calls()), &match?({"R_app", _path, _at}, &1)) end

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
      by_target = choose.({:target, target}, "target", :qory)

      # 1. A target's stack, the Qory harness among them: the target's file is not read.
      assert {:ok, walked} = walk.(files)
      assert %{origin: :setting, target_version: nil, document: %{"name" => "target"}} = walked
      assert walked.stack_id == by_target.id
      assert target_reads.() == []

      # 2. The workspace's choice, before the organisation's shared harness.
      {:ok, _row} = Stacks.delete_stack({:target, target})
      assert {:ok, walked} = walk.(files)
      assert %{target_version: nil, document: %{"name" => "workspace"}} = walked
      assert walked.stack_id == workspace.id
      assert target_reads.() == []

      # 2. The shared harness, where the workspace has no choice: a harness repository
      # before the target's file, the Qory harness after it.
      {:ok, _row} = Stacks.delete_stack({:workspace, ctx.scope.workspace})
      assert {:ok, walked} = walk.(files)
      assert %{target_version: nil, document: %{"name" => "shared"}} = walked
      assert walked.stack_id == shared.id
      assert target_reads.() == []

      shared = choose.({:organisation, ctx.scope.organisation}, "shared", :qory)
      assert {:ok, %{origin: :file, target_version: "c-R_app"}} = walk.(files)
      assert {:ok, walked} = walk.(@base_files)
      assert %{target_version: "c-R_app", document: %{"name" => "shared"}} = walked
      assert walked.stack_id == shared.id

      # 3. The target's file, then 4. the Qory harness.
      {:ok, _row} = Stacks.delete_stack({:organisation, ctx.scope.organisation})
      assert {:ok, %{origin: :file, target_version: "c-R_app"}} = walk.(files)
      assert {:ok, walked} = walk.(@base_files)
      assert %{origin: :setting, stack_id: nil, target_version: "c-R_app"} = walked
      assert walked.document == %{"extends" => Domain.definition(Domain.Software).harness}
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
