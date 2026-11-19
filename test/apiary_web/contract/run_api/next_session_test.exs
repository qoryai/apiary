defmodule ApiaryWeb.Contract.RunApi.NextSessionTest do
  # `POST /v1/runs/<run_id>/next-session`, the request a run of a stage whose workflows run
  # as sessions of one run sends after each session (`Apiary.Stages.next_session/2`). Not
  # async: the stubs of the run API are the whole node's (`ApiaryWeb.RunApiStubs`), and a
  # test sets the limit of the answer (`Application.put_env/3`).
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.ModelChoicesFixtures, only: [every_tier: 2, fallback_attrs: 2]
  import Apiary.ModelKeysFixtures, only: [key_state!: 3, in_seconds: 1, stored_keys: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Connections, ModelChoices, ModelChoicesFixtures, Processes, Repo, Stages}
  alias Apiary.Dispatches.RunSettings
  alias Apiary.Kinds.{Providers, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{ModelKey, Run}
  alias Apiary.Sources.Comment
  alias Apiary.Stages.{Escalation, Session}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets]

  @build "st_6ns22c4pav"
  @verify "st_m1mqbeywdg"
  @vendored Path.expand("../../../fixtures/contract", __DIR__)
  @run_fixtures Path.join(@vendored, "run/v1/fixtures")
  @base "https://qory.dev/contracts/"

  setup {Apiary.DataCase, :without_registry}

  setup do
    :ok = RunApiStubs.install()
    %{scope: scope} = sign_up_fixture()
    gateway_run = sealed_run_fixture(scope)

    %{
      scope: scope,
      key: gateway_run.secrets_key,
      gateway_run: gateway_run.run,
      provider: gateway_run.provider
    }
  end

  # The vendored schemas by their URL under the contracts' base, and Forager's from its
  # contract directory (`Apiary.ContractFixtures.contract_dir/0`), which the answer's
  # `model_credential` refers to. Nothing is fetched.
  defmodule Resolver do
    @moduledoc false
    @behaviour JSV.Resolver

    @base "https://qory.dev/contracts/"

    @impl JSV.Resolver
    def resolve(@base <> path, roots) do
      Enum.find_value(roots, {:error, {:not_vendored, path}}, fn root ->
        file = Path.expand(path, root)

        with true <- String.starts_with?(file, root <> "/"),
             {:ok, body} <- File.read(file),
             {:ok, schema} <- Jason.decode(body) do
          {:ok, schema}
        else
          _ -> nil
        end
      end)
    end

    def resolve(url, _roots), do: {:error, {:not_vendored, url}}
  end

  defp answer_valid?(body) do
    forager =
      case contract_dir() do
        nil -> []
        dir -> [Path.expand("../..", dir)]
      end

    validator =
      JSV.build!(%{"$ref" => @base <> "run/v1/next-session-answer.schema.json"},
        resolver: {Resolver, [@vendored | forager]},
        formats: true
      )

    match?({:ok, _}, JSV.validate(body, validator))
  end

  defp stage(id, name, sequence, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "name" => name,
        "inputs" => [],
        "sequence" => sequence,
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      extra
    )
  end

  defp workflows(names), do: Enum.map(names, &%{"workflow" => &1})

  # The scope's process with `stages`, a work item taken in at its first stage, and the
  # gateway's run of the context made the run record of that stage's first run of the queue,
  # handed over and claimed as a claim keeps it (`Apiary.Stages.claim_sessions!/3`), with
  # the models of its later sessions and the run's keys as the claim forms them
  # (`Apiary.Dispatches.RunSettings.build/2`).
  defp shared!(ctx, stages) do
    document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
    {:ok, _version} = Processes.save(ctx.scope, ctx.scope.workspace, document)
    work_item = taken_in_fixture(ctx.scope)
    run = Repo.one!(from r in DispatchRun, where: r.work_item_id == ^work_item.id)

    # The run record written when the run was queued, which a claim registers, gives way
    # to the gateway's run.
    {1, _rows} = Repo.delete_all(from(r in Run, where: r.dispatch_run_id == ^run.id))

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.gateway_run.id),
        set: [dispatch_run_id: run.id, started_at: DateTime.utc_now()]
      )

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id), set: [state: :handed_over])

    run = Repo.get!(DispatchRun, run.id)

    # The models of the later sessions, as a claim of the run forms them.
    {:ok, built} = run |> RunSettings.hold() |> RunSettings.build()

    {:ok, :ok} =
      Repo.transact(fn ->
        {:ok, Stages.claim_sessions!(run, %{}, Map.get(built, :sessions, %{}))}
      end)

    # The run's key rows, as the claim stores them, in place of those of the gateway's run.
    Repo.delete_all(from(k in ModelKey, where: k.run_id == ^ctx.gateway_run.id))
    rows = for key <- Map.get(built, :keys, []), do: Map.take(key, ModelKey.fields())
    rows = Enum.map(rows, &Map.put(&1, :run_id, ctx.gateway_run.id))
    {count, _rows} = Repo.insert_all(ModelKey, rows)
    ^count = length(rows)

    Map.merge(ctx, %{work_item: work_item, dispatch_run: run})
  end

  defp build_stage(names, extra \\ %{}),
    do: stage(@build, "Build", workflows(names), Map.merge(%{"shared_run" => true}, extra))

  defp request(ctx, body, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    target = "/v1/runs/#{Keyword.get(opts, :run_id, ctx.gateway_run.node_run_id)}/next-session"

    build_conn()
    |> Plug.Conn.assign(:raw_body, body)
    |> signed_post(key.key_id, seed, body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp ended(session, state \\ "succeeded", reason \\ nil),
    do: %{"session" => session, "state" => state, "reason" => reason}

  # The run stores the verdict `verdict` during its session, as a run does through the run API.
  defp verdict!(ctx, verdict) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, ctx.dispatch_run},
        Repo.get!(WorkItem, ctx.work_item.id),
        "verdict",
        %{"verdict" => verdict},
        stage_id: ctx.dispatch_run.stage_id
      )

    :ok
  end

  defp sessions(ctx),
    do:
      Repo.all(
        from s in Session,
          where: s.dispatch_run_id == ^ctx.dispatch_run.id,
          order_by: s.sequence,
          select: {s.sequence, s.forager_session, s.workflow, s.response}
      )

  defp reload(work_item), do: Repo.get!(WorkItem, work_item.id)

  defp comment!(work_item, n, body) do
    at = DateTime.add(DateTime.utc_now(:second), n, :second)

    Repo.insert!(%Comment{
      organisation_id: work_item.organisation_id,
      item_id: work_item.item_id,
      external_ref: "c#{n}",
      url: "https://forge.example.com/northwind/storefront/issues/12#c#{n}",
      author_name: "Avery Example",
      author_kind: :person,
      body: body,
      body_format: "markdown",
      source_created_at: at,
      source_updated_at: at
    })
  end

  defp answer_limit!(bytes) do
    Application.put_env(:apiary, Stages, session_answer_limit: bytes)
    on_exit(fn -> Application.delete_env(:apiary, Stages) end)
  end

  describe "a signed request" do
    setup ctx do
      shared!(ctx, [
        build_stage(~w(plan-the-build write-acceptance-checks)),
        stage(@verify, "Verify", workflows(["verify-a-ticket"]))
      ])
    end

    test "returns session 2 for the end of session 1, with the workspace's runtime and model",
         ctx do
      :ok = verdict!(ctx, "passed")
      conn = request(ctx, ended(1))
      assert signed_answer?(conn)
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      body = json_response(conn, 200)

      assert %{
               "next" => "session",
               "session" => 2,
               "workflow" => "write-acceptance-checks",
               "time_limit_minutes" => 180,
               "full_suite" => false,
               "inputs" => %{"version" => 1, "work_item" => %{}, "run" => %{}}
             } = body

      # The workspace's choice has no model: the provider's default model.
      assert %{"runtime" => "claude", "model" => model, "provider_models" => [_ | _]} =
               body["model_choice"]

      assert model == ctx.gateway_run.run_settings["model"]
      refute Map.has_key?(body, "model_credential")

      assert String.starts_with?(conn.resp_body, ~s({"next":"session","session":2,))

      assert [{1, 1, "plan-the-build", _}, {2, nil, "write-acceptance-checks", nil}] =
               sessions(ctx)
    end

    test "keeps the model of the claim: a choice saved after the claim changes nothing",
         ctx do
      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(ctx.scope, {:workspace, "write-acceptance-checks"}, %{
          provider: ctx.provider.public_id,
          model: "claude-sonnet-5-5"
        })

      :ok = verdict!(ctx, "passed")
      body = json_response(request(ctx, ended(1)), 200)

      assert body["model_choice"]["model"] == ctx.gateway_run.run_settings["model"]
      refute Map.has_key?(body, "model_credential")
    end

    @tag :contract
    test "every 200 body is valid against the run contract's answer", ctx do
      :ok = verdict!(ctx, "passed")
      assert answer_valid?(json_response(request(ctx, ended(1)), 200))
      :ok = verdict!(ctx, "passed")
      assert answer_valid?(json_response(request(ctx, ended(2)), 200))
    end

    test "returns end where no workflow of the stage follows", ctx do
      :ok = verdict!(ctx, "passed")
      assert %{"next" => "session"} = json_response(request(ctx, ended(1)), 200)
      :ok = verdict!(ctx, "passed")
      conn = request(ctx, ended(2))
      assert conn.resp_body == ~s({"next":"end"})
      assert %WorkItem{stage_id: @build, stage_state: :at_gate} = reload(ctx.work_item)
    end

    test "a repeat for the same session returns the same bytes and steps the runner once",
         ctx do
      :ok = verdict!(ctx, "passed")
      first = request(ctx, ended(1))
      assert first.status == 200
      stored = sessions(ctx)
      work_item = reload(ctx.work_item)

      # A verdict stored after the step changes nothing for the repeat.
      :ok = verdict!(ctx, "changes-requested")
      again = request(ctx, ended(1, "failed"))

      assert again.status == 200
      assert again.resp_body == first.resp_body
      assert sessions(ctx) == stored
      assert reload(ctx.work_item).stage_entry == work_item.stage_entry
      assert reload(ctx.work_item).updated_at == work_item.updated_at
    end

    test "a session older than the newest the run reported is 409 session_mismatch", ctx do
      :ok = verdict!(ctx, "passed")
      assert request(ctx, ended(2)).status == 200
      stored = sessions(ctx)
      conn = request(ctx, ended(1))
      assert signed_answer?(conn)

      assert json_response(conn, 409) == %{
               "error" => "session_mismatch",
               "message" =>
                 "Send the number of the session that ended last. A later session of this run ended already."
             }

      assert sessions(ctx) == stored
    end

    test "a body outside the run contract's request is 400 invalid_request with the member",
         ctx do
      stored = sessions(ctx)

      message =
        "Send session, state and reason as the run contract's next-session request has them."

      for {body, member} <- [
            {"not json", "body"},
            {"[]", "body"},
            {%{"state" => "succeeded", "reason" => nil}, "session"},
            {ended(0), "session"},
            {ended(1.0), "session"},
            {ended(1, "paused"), "state"},
            {%{"session" => 1, "state" => "succeeded"}, "reason"},
            {ended(1, "succeeded", "Timeout"), "reason"},
            {ended(1, "cancelled"), "reason"},
            {ended(1, "failed", "timeout"), "reason"},
            {ended(1, "cancelled", "gateway_lost"), "reason"},
            {Map.put(ended(1), "verdict", "passed"), "verdict"}
          ] do
        conn = request(ctx, body)
        assert signed_answer?(conn)

        assert json_response(conn, 400) == %{
                 "error" => "invalid_request",
                 "names" => [member],
                 "message" => message
               },
               "#{inspect(body)}"
      end

      assert sessions(ctx) == stored
    end

    test "the vendored request fixtures: each valid one is read, each invalid one is 400",
         ctx do
      valid = Path.wildcard(Path.join(@run_fixtures, "next-session-request/*.json"))
      invalid = Path.wildcard(Path.join(@run_fixtures, "invalid/next-session-request-*.json"))
      assert length(valid) == 6
      assert length(invalid) == 13

      for file <- valid do
        assert {:ok, _report} = ApiaryWeb.Contract.RunApi.Body.next_session(File.read!(file)),
               file
      end

      for file <- invalid do
        assert json_response(request(ctx, File.read!(file)), 400)["error"] == "invalid_request",
               file
      end
    end

    test "a body over 4 KiB is 413 payload_too_large and writes nothing", ctx do
      stored = sessions(ctx)
      body = Jason.encode!(ended(1)) <> String.duplicate(" ", 4 * 1024)
      conn = request(ctx, body)
      assert signed_answer?(conn)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert sessions(ctx) == stored
    end

    test "another gateway's run, an unknown run and a malformed id are the same 404", ctx do
      %{scope: scope} = sign_up_fixture()
      other_key = sealed_run_fixture(scope).secrets_key
      stored = sessions(ctx)

      answers =
        for conn <- [
              request(ctx, ended(1), key: other_key),
              request(ctx, ended(1), run_id: Ecto.UUID.generate()),
              request(ctx, ended(1), run_id: "not-a-run")
            ] do
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]
      assert sessions(ctx) == stored
    end

    test "a request signed with the wrong key is 401, unsigned", ctx do
      conn = request(ctx, ended(1), key: {elem(ctx.key, 0), :crypto.strong_rand_bytes(32)})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []
    end

    test "a run whose run of the queue ended is 409 run_ended and writes nothing", ctx do
      stored = sessions(ctx)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      conn = request(ctx, ended(1))
      assert signed_answer?(conn)

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" => "Close the run. It ended, so it starts no more sessions."
             }

      assert sessions(ctx) == stored
    end

    test "a run a member cancelled is 409 run_ended and writes nothing", ctx do
      stored = sessions(ctx)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.gateway_run.id),
          set: [state: "running"]
        )

      {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, ctx.gateway_run.id))

      assert json_response(request(ctx, ended(1)), 409) == %{
               "error" => "run_ended",
               "message" => "Close the run. A member cancelled it, so it starts no more sessions."
             }

      assert sessions(ctx) == stored
    end

    test "a run whose ticket is gone ends ticket_gone and is 409 run_ended", ctx do
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [item_id: nil]
        )

      stored = sessions(ctx)
      :ok = verdict!(ctx, "passed")
      conn = request(ctx, ended(1))
      assert signed_answer?(conn)

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "Close the run. The ticket of its work item is no longer in Qory Apiary, so the run ended."
             }

      assert %DispatchRun{state: :ended, end_cause: :ticket_gone, result_outcome: :error} =
               Repo.get!(DispatchRun, ctx.dispatch_run.id)

      assert sessions(ctx) == stored
      assert %WorkItem{stage_state: :escalated} = reload(ctx.work_item)

      assert [%Escalation{cause: :run_stopped, points: [point]}] =
               Repo.all(from e in Escalation, where: e.work_item_id == ^ctx.work_item.id)

      assert point["text"] ==
               "The run stopped: the work item's ticket is no longer in Qory Apiary, so the run ended after session 1."

      assert point["fix"] == "Close the work item, or take the ticket in again."

      # The repeat finds the run ended.
      assert %{"error" => "run_ended"} = json_response(request(ctx, ended(1)), 409)
    end
  end

  describe "the model of a later session, as the claim kept it" do
    defp choose!(ctx, place, attrs) do
      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(
          ctx.scope,
          place,
          Map.put(attrs, :provider, ctx.provider.public_id)
        )

      :ok
    end

    defp next!(ctx, stages) do
      ctx = shared!(ctx, stages)
      :ok = verdict!(ctx, "passed")
      json_response(request(ctx, ended(1)), 200)
    end

    @tag :contract
    test "is the workflow's choice, with its effort and tiers, valid against the answer's schema",
         ctx do
      # The session's model and effort are those of the thinking tier.
      :ok =
        choose!(ctx, {:workspace, "write-acceptance-checks"}, %{
          tiers: %{
            "light" => "claude-haiku-5-5",
            "balanced" => "claude-sonnet-5-5",
            "thinking" => %{"model" => "claude-opus-5-5", "effort" => "max"}
          }
        })

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{
               "model" => "claude-opus-5-5",
               "effort" => "max",
               "provider_models" => [_ | _],
               "tiers" => %{
                 "light" => "claude-haiku-5-5",
                 "balanced" => "claude-sonnet-5-5",
                 "thinking" => %{"model" => "claude-opus-5-5"}
               }
             } = body["model_choice"]

      assert body["model_choice"]["runtime"] == "claude"
      refute Map.has_key?(body, "model_credential")
      assert answer_valid?(body)
    end

    test "is the run's model where the workflow's choice is no longer valid", ctx do
      :ok =
        choose!(ctx, {:workspace, "write-acceptance-checks"}, %{
          tiers: every_tier("claude-sonnet-5-5", "high")
        })

      # An effort the model no longer offers, on every tier, written past the save's
      # checks.
      {1, _rows} =
        Repo.update_all(
          from(c in ModelChoice, where: c.workflow == "write-acceptance-checks"),
          set: [tiers: every_tier("claude-sonnet-5-5", "gone")]
        )

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{"runtime" => "claude", "model" => model} = body["model_choice"]
      assert model == ctx.gateway_run.run_settings["model"]
      refute Map.has_key?(body, "model_credential")
    end

    test "is the default runtime alone where the session's workflow resolves to no choice",
         ctx do
      # The run's provider comes from the choice of its first workflow alone.
      {:ok, _deleted} = ModelChoices.delete_choice(ctx.scope, :workspace)
      :ok = choose!(ctx, {:workspace, "plan-the-build"}, %{})

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{"workflow" => "write-acceptance-checks"} = body
      assert body["model_choice"] == %{"runtime" => "claude"}
      refute Map.has_key?(body, "model_credential")
    end

    test "is the fallback's where every key of the choice's provider is in cooldown at the claim",
         ctx do
      {:ok, fallback} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Fallback keys",
          keys: [%{value_id: "main", value: "sk-ant-fallback-0123456789"}]
        })

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
          provider: ctx.provider.public_id,
          model: "claude-opus-5-5",
          fallbacks: [fallback_attrs(fallback, every_tier("claude-sonnet-5-5", "high"))]
        })

      key_state!(ctx.provider, "main", until: in_seconds(3600))

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{"model" => "claude-sonnet-5-5", "effort" => "high"} = body["model_choice"]
      # The run's keys are the fallback's: the session joins with the start key's group.
      refute Map.has_key?(body, "model_credential")
    end

    test "is the workflow's choice on another provider with a free key, not the fall back onto the run's provider",
         ctx do
      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Checkout keys",
          keys: [%{value_id: "main", value: "sk-ant-other-0123456789"}]
        })

      # A workflow's choice falls back to the workspace's choice, on the run's provider,
      # only while every key of its provider is in cooldown. Checkout keys has a free key.
      :ok =
        choose!(ctx, :workspace, %{
          model: "claude-sonnet-5-5",
          tiers: every_tier("claude-sonnet-5-5", "high")
        })

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(ctx.scope, {:workspace, "write-acceptance-checks"}, %{
          provider: other.public_id,
          model: "claude-opus-5-5"
        })

      ctx = shared!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])
      :ok = verdict!(ctx, "passed")
      body = json_response(request(ctx, ended(1)), 200)

      # Session 2 starts on the first key of Checkout keys, with the choice's model.
      assert %{"runtime" => "claude", "model" => "claude-opus-5-5"} = body["model_choice"]
      assert body["model_credential"] == "#{other.public_id}-1"

      # The run keeps the keys of both providers, the start key's provider's first.
      providers = ctx.gateway_run |> stored_keys() |> Enum.map(& &1.connection_id)
      assert Enum.uniq(providers) == [ctx.provider.id, other.id]
    end

    test "is the workflow's choice on its provider, with that provider's first key, where its choice has another provider",
         ctx do
      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "anthropic",
          name: "Checkout keys",
          keys: [%{value_id: "main", value: "sk-ant-other-0123456789"}]
        })

      :ok = choose!(ctx, :workspace, %{model: "claude-opus-5-5"})

      {:ok, _choice} =
        ModelChoicesFixtures.put_choice(ctx.scope, {:workspace, "write-acceptance-checks"}, %{
          provider: other.public_id,
          model: "claude-sonnet-5-5"
        })

      ctx = shared!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])
      :ok = verdict!(ctx, "passed")
      body = json_response(request(ctx, ended(1)), 200)

      # Session 2 runs on Checkout keys: the choice's model, on its first key.
      assert %{"runtime" => "claude", "model" => "claude-sonnet-5-5"} = body["model_choice"]
      assert body["model_credential"] == "#{other.public_id}-1"

      # The run keeps the keys of both providers, the start key's provider's first.
      assert [%ModelKey{start: true} = start | rest] = stored_keys(ctx.gateway_run)
      assert start.connection_id == ctx.provider.id
      assert Enum.map(rest, &{&1.connection_id, &1.name}) == [{other.id, "#{other.public_id}-1"}]
    end

    @tag :contract
    test "is the workflow's runtime with its model where that runtime uses the run's API",
         ctx do
      # The default runtime and a copy of it under another name: it uses the same API.
      release = ModelChoices.default_runtime()
      second = %{release | name: release.name <> "-second", title: release.title <> " second"}
      :ok = Runtimes.put_test_list([release, second])

      :ok =
        choose!(ctx, {:workspace, "write-acceptance-checks"}, %{
          runtime: second.name,
          model: "claude-sonnet-5-5"
        })

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{"runtime" => runtime, "model" => "claude-sonnet-5-5"} = body["model_choice"]
      assert runtime == second.name
      refute Map.has_key?(body, "model_credential")
      assert answer_valid?(body)
    end

    test "is the workflow's runtime alone where that runtime uses another API of the run's provider",
         ctx do
      release = ModelChoices.default_runtime()
      second = %{release | name: release.name <> "-second", title: release.title <> " second"}
      :ok = Runtimes.put_test_list([release, second])

      # The run's provider with two APIs: the release's runtime uses the first, and the
      # second runtime the other, with another auth.
      providers =
        for provider <- Providers.list() do
          if provider.name == ctx.provider.provider_kind do
            [api] = provider.apis

            other =
              api
              |> Map.put("runtimes", [second.name])
              |> Map.put("auth", %{"scheme" => "bearer"})

            %{provider | apis: [Map.put(api, "runtimes", [release.name]), other]}
          else
            provider
          end
        end

      :ok = Providers.put_test_list(providers)

      :ok =
        choose!(ctx, {:workspace, "write-acceptance-checks"}, %{
          runtime: second.name,
          model: "claude-sonnet-5-5"
        })

      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert body["model_choice"] == %{"runtime" => second.name}
      refute Map.has_key?(body, "model_credential")
    end

    test "is the run's run_settings where the workflow's runtime is no longer in the catalogue",
         ctx do
      release = ModelChoices.default_runtime()
      second = %{release | name: release.name <> "-second", title: release.title <> " second"}
      :ok = Runtimes.put_test_list([release, second])

      :ok =
        choose!(ctx, {:workspace, "write-acceptance-checks"}, %{
          runtime: second.name,
          model: "claude-sonnet-5-5"
        })

      :ok = Runtimes.put_test_list([release])
      body = next!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])

      assert %{"runtime" => runtime, "model" => model} = body["model_choice"]
      assert runtime == release.name
      assert model == ctx.gateway_run.run_settings["model"]
      refute Map.has_key?(body, "model_credential")
    end

    test "is the workflow's choice, on its provider's first key, where session 1 has no provider's key",
         ctx do
      # No choice for the run's first workflow: session 1 uses the gateway's key.
      {:ok, _deleted} = ModelChoices.delete_choice(ctx.scope, :workspace)
      :ok = choose!(ctx, {:workspace, "write-acceptance-checks"}, %{model: "claude-sonnet-5-5"})

      ctx = shared!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])
      :ok = verdict!(ctx, "passed")
      body = json_response(request(ctx, ended(1)), 200)

      # Session 2 starts on the first key of its provider, which the run keeps; no key is
      # the start key.
      assert %{"runtime" => "claude", "model" => "claude-sonnet-5-5"} = body["model_choice"]
      first = "#{ctx.provider.public_id}-1"
      assert body["model_credential"] == first

      assert [%ModelKey{name: ^first, start: false, connection_id: id}] =
               stored_keys(ctx.gateway_run)

      assert id == ctx.provider.id
    end
  end

  describe "GET work-item of a run in a loop" do
    setup ctx do
      loop = %{
        "loop" => %{"rounds" => 3, "body" => workflows(~w(implement-changes review-changes))}
      }

      shared!(ctx, [stage(@build, "Build", [loop], %{"shared_run" => true})])
    end

    test "has the workflow and the round of the run's newest session", ctx do
      read = fn ->
        {key, seed} = ctx.key
        target = "/v1/runs/#{ctx.gateway_run.node_run_id}/work-item"
        json_response(signed_get(build_conn(), key.key_id, seed, target), 200)["run"]
      end

      assert %{"workflow" => "implement-changes", "round" => 1} = read.()

      # implement-changes stores no verdict: the ring runs review-changes.
      assert %{"workflow" => "review-changes"} = json_response(request(ctx, ended(1)), 200)
      assert %{"workflow" => "review-changes", "round" => 1} = read.()

      :ok = verdict!(ctx, "changes-requested")
      assert %{"workflow" => "implement-changes"} = json_response(request(ctx, ended(2)), 200)
      assert %{"workflow" => "implement-changes", "round" => 2} = read.()
    end
  end

  describe "the answer's limit" do
    setup ctx do
      shared!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])
    end

    test "leaves out the oldest comments for the answer to fit its limit", ctx do
      for n <- 1..6, do: comment!(ctx.work_item, n, "#{n} " <> String.duplicate("x", 2_000))
      answer_limit!(8_000)
      :ok = verdict!(ctx, "passed")
      conn = request(ctx, ended(1))
      body = json_response(conn, 200)
      assert byte_size(conn.resp_body) <= 8_000
      assert body["inputs"]["comments_omitted"] > 0

      assert body["inputs"]["comments_omitted"] + length(body["inputs"]["comments"]) == 6
      assert [%{"body" => "6 " <> _} | _] = Enum.reverse(body["inputs"]["comments"])
    end

    test "inputs that cannot fit with every comment left out end the run inputs_invalid",
         ctx do
      answer_limit!(400)
      :ok = verdict!(ctx, "passed")
      stored = sessions(ctx)
      conn = request(ctx, ended(1))

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "Close the run. The input of its next session breaks a rule for the agent's input, such as its size limit, so the run ended."
             }

      assert %DispatchRun{state: :ended, end_cause: :inputs_invalid, result_outcome: :error} =
               Repo.get!(DispatchRun, ctx.dispatch_run.id)

      assert sessions(ctx) == stored
      assert %WorkItem{stage_state: :escalated} = reload(ctx.work_item)

      assert [%Escalation{points: [point]}] =
               Repo.all(from e in Escalation, where: e.work_item_id == ^ctx.work_item.id)

      assert point["text"] ==
               "The run stopped: a value in the ticket or the work item breaks a rule for the input of the next session, such as its size limit, so the run ended after session 1."
    end
  end

  describe "a run of a stage without shared_run" do
    test "is 404 not_found and writes nothing", ctx do
      ctx =
        shared!(ctx, [
          stage(@build, "Build", workflows(~w(plan-the-build write-acceptance-checks)))
        ])

      assert sessions(ctx) == []
      conn = request(ctx, ended(1))
      assert signed_answer?(conn)
      assert conn.status == 404
      assert conn.resp_body == ~s({"error":"not_found"})
      assert sessions(ctx) == []
    end
  end

  describe "the feature" do
    test "is 404 where the instance does not have workflow_model", ctx do
      ctx = shared!(ctx, [build_stage(~w(plan-the-build write-acceptance-checks))])
      RunApiStubs.put(:flag, false)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.gateway_run.id),
          set: [features: Apiary.Features.recorded() -- ["workflow_model"]]
        )

      stored = sessions(ctx)
      conn = request(ctx, ended(1))
      assert conn.status == 404
      assert signed_answer?(conn)
      assert sessions(ctx) == stored
    end
  end
end
