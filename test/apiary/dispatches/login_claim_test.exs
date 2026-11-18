defmodule Apiary.Dispatches.LoginClaimTest do
  # A claim of a run whose model provider's keys are sign-ins (`Apiary.ModelKeys.Login`):
  # a key that needs a new sign-in is a cooldown with no end, a sign-in that expires before
  # the end of the run's time limit is refreshed in the background, and the claim calls no
  # provider (the `Req.Test` stub of `LoginRefresh` records no request). What the run's page
  # says while it waits (`Apiary.Runs.Waiting`), and what the run keeps of the provider's API
  # (`runs.provider_api`, `runs.model_keys`) within the columns' bounds.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelChoices, ModelKeys}
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.ModelKeys.{Login, LoginRefresh, LoginRefreshJob}
  alias Apiary.Runs.{ProviderCredential, Projector, Run, Waiting}
  alias Apiary.Secrets.Value

  @moduletag needs: [:factory, :secrets]

  @body ~s({"version":1,"time":"2026-11-18T12:00:00Z"})

  setup do
    %{scope: scope} = sign_up_fixture()

    ctx =
      scope
      |> handover_place_fixture(allow_secrets: true)
      |> Map.put(:scope, scope)

    stub!()
    ctx
  end

  # Every call to the provider's login server is recorded.
  defp stub! do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})
      tokens = login_tokens(tag: "refreshed")

      Req.Test.json(conn, %{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token
      })
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, body} -> requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A provider with the keys `keys`, `[{value_id, login_tokens opts}]`, chosen at the
  # workspace with the runtime `codex`.
  defp provider!(ctx, keys) do
    {:ok, provider} =
      Connections.create_provider(ctx.scope, %{
        provider: "openai-subscription",
        keys:
          for({value_id, opts} <- keys) do
            %{value_id: value_id, value: login_paste(tokens: login_tokens(opts))}
          end
      })

    {:ok, _choice} =
      ModelChoices.put_choice(ctx.scope, :workspace, %{
        provider: provider.public_id,
        runtime: "codex",
        model: "gpt-6-sol"
      })

    Repo.get!(Connection, provider.id)
  end

  defp value(provider, name), do: key_value!(provider, name)

  defp sign_in_needed!(provider, name) do
    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, name).id),
        set: [state: "sign_in_needed", sign_in_cause: "refresh_token_expired"]
      )
  end

  # The login signed in `seconds` ago, so a new sign-in is not read as just made.
  defp aged!(provider, name, seconds \\ 3600) do
    {1, _rows} =
      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, name).id),
        set: [signed_in_at: DateTime.add(DateTime.utc_now(), -seconds)]
      )
  end

  defp queued!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    queued
  end

  defp claim(ctx), do: walked_claim(ctx.key, Dispatches.now(), @body)

  defp value_ids(%Run{model_keys: keys}) do
    by_id = Map.new(Repo.all(Value), &{&1.id, &1.value_id})
    for %{"id" => id} <- keys, do: by_id[id]
  end

  defp waiting!(queued, provider) do
    assert %DispatchRun{state: :waiting} = waiting = Repo.get!(DispatchRun, queued.id)
    assert waiting.model_provider_ids == [provider.id]

    assert Repo.aggregate(from(d in Dispatch, where: d.dispatch_run_id == ^queued.id), :count) ==
             0

    waiting
  end

  describe "a key that needs a new sign-in" do
    test "is the run's only key: the run waits, with no end and no call", ctx do
      provider = provider!(ctx, [{"main", []}])
      sign_in_needed!(provider, "main")
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)

      assert {:sign_in, public_id, "main"} = Waiting.reason(waiting)
      assert public_id == provider.public_id
      assert requests() == []
      assert ModelKeys.first_to_leave([provider.id], DateTime.utc_now()) == nil

      # The next claims pass the run by: its provider has no key left to take.
      assert {:ok, :none} = claim(ctx)
      refute_enqueued(worker: LoginRefreshJob)
    end

    test "has another key of the provider: the run moves to it", ctx do
      provider = provider!(ctx, [{"main", []}, {"spare", [tag: "b"]}])
      sign_in_needed!(provider, "main")
      queued!(ctx)

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["spare"]
      assert requests() == []
    end

    test "has another key in cooldown: the run waits, until the cooldown ends", ctx do
      provider = provider!(ctx, [{"main", []}, {"spare", [tag: "b"]}])
      sign_in_needed!(provider, "main")
      until = in_seconds(3600)
      key_state!(provider, "spare", until: until)
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)

      assert {:cooldown, name, at} = Waiting.reason(waiting)
      assert name == provider.name
      assert DateTime.compare(at, until) == :eq
      assert requests() == []

      key_state!(provider, "spare", until: in_seconds(-1))
      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["spare"]
    end

    test "is replaced by a new sign-in: the run starts on it", ctx do
      provider = provider!(ctx, [{"main", []}])
      sign_in_needed!(provider, "main")
      queued = queued!(ctx)
      assert {:ok, :none} = claim(ctx)
      waiting!(queued, provider)

      {:ok, _provider} =
        Connections.update_provider_key(ctx.scope, provider, "main", %{
          value_id: "main",
          value: login_paste(tokens: login_tokens(tag: "new"))
        })

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["main"]
    end
  end

  describe "a run whose only key loses its sign-in while it runs" do
    test "pauses at the key's limit, and its continuation waits until a new sign-in", ctx do
      provider = provider!(ctx, [{"main", []}])
      queued = queued!(ctx)

      %{run: run, dispatch_run: dispatch_run} =
        handed_over(ctx.scope, ctx.key, queued, %{})

      assert value_ids(Repo.get!(Run, run.id)) == ["main"]

      # The provider rejects the sign-in for good while the run runs.
      sign_in_needed!(provider, "main")

      event_fixture(run, 9, "run.exited", %{
        "state" => "paused",
        "reason" => "model_key_limit",
        "exit_code" => 143
      })

      assert {:ok, %Run{state: "paused"}} = Projector.project(run)

      assert [{1, :ended}, {2, :waiting}] =
               Repo.all(
                 from d in DispatchRun,
                   where: d.work_item_id == ^dispatch_run.work_item_id,
                   order_by: d.attempt,
                   select: {d.attempt, d.state}
               )

      # The continuation is passed by, with no end time and no call, and says why.
      assert {:ok, :none} = claim(ctx)

      continuation =
        Repo.get_by!(DispatchRun, work_item_id: dispatch_run.work_item_id, attempt: 2)

      assert {:sign_in, public_id, "main"} = Waiting.reason(continuation)
      assert public_id == provider.public_id
      assert requests() == []

      {:ok, _provider} =
        Connections.update_provider_key(ctx.scope, provider, "main", %{
          value_id: "main",
          value: login_paste(tokens: login_tokens(tag: "new"))
        })

      assert {:ok, %{registered: next}} = claim(ctx)
      assert value_ids(Repo.get!(Run, next.id)) == ["main"]
    end
  end

  describe "a stored token with no account id" do
    test "needs a new sign-in: the run waits and nothing is sent to the provider", ctx do
      provider = provider!(ctx, [{"main", [account: false]}])
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)

      assert {:sign_in, _public_id, "main"} = Waiting.reason(waiting)
      assert requests() == []
      assert Repo.get_by!(Login, secret_value_id: value(provider, "main").id).state == "signed_in"
    end
  end

  describe "a sign-in that expires before the end of the run's time limit" do
    test "is refreshed in the background and the run waits, then starts on it", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)
      assert {:refreshing, _public_id, "main"} = Waiting.reason(waiting)

      # The claim made no call: the job does.
      assert requests() == []
      assert_enqueued(worker: LoginRefreshJob)

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_safety: false)
      assert [%{"refresh_reason" => "proactive_expiry"}] = requests()

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["main"]
      assert requests() == []
    end

    test "is enqueued once while the job waits", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued!(ctx)

      for _claim <- 1..3, do: assert({:ok, :none} = claim(ctx))

      assert [_one] = all_enqueued(worker: LoginRefreshJob)
    end

    test "is not blocked when it expires after the time limit", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 4 * 3600]}])
      aged!(provider, "main")
      queued!(ctx)

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["main"]
      refute_enqueued(worker: LoginRefreshJob)
    end

    test "that failed to refresh leaves the run waiting for the retry", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      retry_at = DateTime.add(DateTime.utc_now(), 90)

      Repo.update_all(from(l in Login, where: l.secret_value_id == ^value(provider, "main").id),
        set: [retry_at: retry_at, failures: 1]
      )

      queued = queued!(ctx)
      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)

      assert {:refreshing, _public_id, "main"} = Waiting.reason(waiting)
      assert requests() == []
    end
  end

  describe "while the node is stopping" do
    @describetag :stopping

    setup do
      previous = Application.get_env(:apiary, Login, [])
      on_exit(fn -> Application.put_env(:apiary, Login, previous) end)
      Application.put_env(:apiary, Login, Keyword.put(previous, :stopping, fn -> true end))
      :ok
    end

    test "no refresh is started, and the run's line says the server restarts", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)

      assert {:restart, _public_id, "main"} = Waiting.reason(waiting)
      refute_enqueued(worker: LoginRefreshJob)
      assert requests() == []
    end
  end

  describe "what the run keeps" do
    test "has the provider's paths, and the account header and claim in its auth", ctx do
      provider = provider!(ctx, [{"main", []}])
      queued!(ctx)

      assert {:ok, %{registered: run}} = claim(ctx)

      assert %Run{provider_api: %{"paths" => ["/backend-api/codex/*"], "auth" => auth}} =
               Repo.get!(Run, run.id)

      assert auth["account_header"] == "chatgpt-account-id"
      assert auth["account_claim"] == "/https:~1~1api.openai.com~1auth/chatgpt_account_id"
      assert Repo.get!(Run, run.id).provider_connection_id == provider.id

      assert {:ok, credential} = ProviderCredential.for_run(Repo.get!(Run, run.id))
      [%{entry: entry}] = credential.keys
      entry = Jason.decode!(Jason.encode!(entry))
      assert entry["paths"] == ["/backend-api/codex/*"]
      assert entry["auth"]["account_header"] == "chatgpt-account-id"
    end

    test "fits runs.model_keys at 6 keys with every member and runs.provider_api at 8192", ctx do
      provider = provider!(ctx, [{"main", []}])
      name = fn n -> String.duplicate("k", 62) <> "-#{n}" end
      time = "2026-11-18T14:00:00Z"

      keys =
        for n <- 1..6 do
          first = if n == 1, do: %{"start" => true, "chosen" => true}, else: %{}

          Map.merge(first, %{
            "id" => Ecto.UUID.generate(),
            "name" => name.(n),
            "pause_for_s" => 604_800,
            "resets_at" => time,
            "schedule_resets_at" => time,
            "cooldown_until" => time,
            "use_up_to_percent" => 99
          })
        end

      auth = %{
        "scheme" => "bearer",
        "oauth" => true,
        "account_header" => String.duplicate("X", 64),
        "account_claim" => "/" <> String.duplicate("c", 255)
      }

      api = %{
        "format" => "openai-responses",
        "endpoint" => "https://chatgpt.com/backend-api/codex",
        "auth" => auth,
        "paths" => for(n <- 1..32, do: "/" <> String.duplicate("p", 200) <> "#{n}"),
        "use_up_to_windows" => ~w(five_hour seven_day)
      }

      assert byte_size(Jason.encode!(api)) <= 8192

      pool = Apiary.NodesFixtures.pool_fixture(ctx.scope)
      %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(ctx.scope, pool)

      %{run: run} =
        handed_over_fixture(ctx.scope, key, %{
          provider_connection_id: provider.id,
          provider_secret_id: provider.secret_id,
          provider_chain: "organisation",
          provider_api: api,
          model_keys: keys,
          run_settings: %{}
        })

      assert %Run{model_keys: ^keys, provider_api: ^api} = Repo.get!(Run, run.id)

      size =
        Repo.one(
          from r in Run,
            where: r.id == ^run.id,
            select: fragment("octet_length(?::text)", r.model_keys)
        )

      assert size <= 4096

      # Past the bounds the checks refuse: a path without its slash, 33 paths, a member the
      # check does not list.
      for bad <- [
            Map.put(api, "paths", ["backend-api"]),
            Map.put(api, "paths", for(n <- 1..33, do: "/p#{n}")),
            Map.put(api, "paths", []),
            Map.put(api, "other", true)
          ] do
        assert_raise Postgrex.Error, ~r/runs_provider_api_check/, fn ->
          Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [provider_api: bad])
        end
      end
    end
  end
end
