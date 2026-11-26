defmodule Apiary.Dispatches.LoginClaimTest do
  # A claim of a run whose model provider's keys are sign-ins (`Apiary.ModelKeys.Login`):
  # a key that needs a new sign-in is a cooldown with no end, a sign-in that expires before
  # the end of the run's time limit is refreshed in the background, and the claim calls no
  # provider (the `Req.Test` stub of `LoginRefresh` records no request). What the run's page
  # says while it waits (`Apiary.Runs.Waiting`), and what the run keeps of the provider's API
  # (`run_model_keys.api`) within the column's bounds.
  use Apiary.DataCase, async: true
  use Oban.Testing, repo: Apiary.Repo

  import Apiary.DispatchedRunsFixtures
  import Apiary.ModelKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, ModelKeys}
  alias Apiary.ModelChoicesFixtures
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
  defp stub!(opts \\ []) do
    test = self()

    Req.Test.stub(LoginRefresh, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})
      tokens = login_tokens([tag: "refreshed"] ++ opts)

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
            key(value_id, device_login(tokens: login_tokens(opts)))
          end
      })

    {:ok, _choice} =
      ModelChoicesFixtures.put_choice(ctx.scope, :workspace, %{
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

  # The key needs a new value, as after a provider rejected it (`Apiary.ModelKeys.reject/3`).
  defp rejected!(provider, name) do
    %Value{} = value = value(provider, name)
    now = DateTime.utc_now()

    Repo.insert!(%Apiary.ModelKeys.Rejection{
      secret_value_id: value.id,
      organisation_id: provider.organisation_id,
      rejected_at: now,
      value_set_at: value.value_set_at,
      updated_at: now
    })
  end

  # 6 keys that `block!` leaves for a person to fix, then one of another provider of the
  # key group whose sign-in expires within the run's time limit: the claim starts its
  # refresh alone. `:ok` once checked.
  defp past_person_fixed(ctx, block!) do
    blocked = for n <- 1..6, do: {"key-#{n}", [expires_in: 3600, tag: "north#{n}"]}
    provider = provider!(ctx, blocked)
    for n <- 1..6, do: block!.(provider, "key-#{n}")
    other = other_provider!(ctx)
    aged!(other, "key-1")
    queued!(ctx)

    assert {:ok, :none} = claim(ctx)
    jobs = for job <- all_enqueued(worker: LoginRefreshJob), do: job.args["secret_value_id"]
    assert jobs == [value(other, "key-1").id]
    :ok
  end

  # A key as `Apiary.Connections.create_provider/3` takes it, with no `key-<n>` value id:
  # Qory Apiary names a provider's keys `key-1` up, in order, and a given value id of that
  # form fails.
  defp key("key-" <> _number, value), do: %{value: value}
  defp key(value_id, value), do: %{value_id: value_id, value: value}

  # A second provider of the key group of `provider!/2`'s, with one key whose sign-in
  # expires in an hour.
  defp other_provider!(ctx) do
    {:ok, other} =
      Connections.create_provider(ctx.scope, %{
        provider: "openai-subscription",
        keys: [
          %{value: device_login(tokens: login_tokens(expires_in: 3600, tag: "south"))}
        ]
      })

    other
  end

  # The key is in cooldown until `until`, as after a provider reported its limit.
  defp cooled!(provider, name, until) do
    now = DateTime.utc_now()

    Repo.insert!(%Apiary.ModelKeys.State{
      secret_value_id: value(provider, name).id,
      window: "five_hour",
      organisation_id: provider.organisation_id,
      status: "rejected",
      resets_at: until,
      cooldown_until: until,
      source: "provider",
      observed_at: now,
      updated_at: now
    })
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

  defp value_ids(%Run{id: run_id}) do
    by_id = Map.new(Repo.all(Value), &{&1.id, &1.value_id})
    for %{secret_value_id: id} <- stored_keys(run_id), do: by_id[id]
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

      assert {:sign_in, public_id, %{id: key_id, identity: _line}} = Waiting.reason(waiting)

      assert key_id == value(provider, "main").id
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

      # The sign-in of main needs a new one, beside the cooldown of spare.
      assert {:cooldown_or_new_key, name, at} = Waiting.reason(waiting)
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
          value: device_login(tokens: login_tokens(tag: "new"))
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

      assert {:sign_in, public_id, %{id: key_id, identity: _line}} = Waiting.reason(continuation)

      assert key_id == value(provider, "main").id
      assert public_id == provider.public_id
      assert requests() == []

      {:ok, _provider} =
        Connections.update_provider_key(ctx.scope, provider, "main", %{
          value_id: "main",
          value: device_login(tokens: login_tokens(tag: "new"))
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

      # A value pasted with no account id is a row that is still signed in. The claim reads
      # the token to tell, as it does for a row stored before a refresh marked such a token
      # (`no_account`); the run's page reads the row alone and names the pool.
      assert {:pool, _name} = Waiting.reason(waiting)
      assert requests() == []
      assert Repo.get_by!(Login, secret_value_id: value(provider, "main").id).state == "signed_in"
    end
  end

  describe "a refresh whose token has no account id" do
    test "marks the key no_account, and the run waits for a new sign-in", ctx do
      stub!(account: false)
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)

      assert {:refreshing, _public_id, %{id: key_id, identity: _line}} =
               Waiting.reason(waiting!(queued, provider))

      assert key_id == value(provider, "main").id

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_safety: false)
      assert [%{"refresh_reason" => "proactive_expiry"}] = requests()

      row = Repo.get_by!(Login, secret_value_id: value(provider, "main").id)
      assert %Login{state: "sign_in_needed", sign_in_cause: "no_account"} = row

      # The row says it, so the page and the claim agree with no token read: the run waits
      # with the sign-in line, and the next claim sends nothing.
      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)
      assert {:sign_in, public_id, %{id: key_id, identity: _line}} = Waiting.reason(waiting)
      assert key_id == value(provider, "main").id
      assert public_id == provider.public_id
      assert requests() == []
      refute_enqueued(worker: LoginRefreshJob)
    end

    test "a new sign-in clears the mark, and the run starts on it", ctx do
      stub!(account: false)
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued = queued!(ctx)
      assert {:ok, :none} = claim(ctx)
      assert %{success: 1} = Oban.drain_queue(queue: :default, with_safety: false)
      waiting!(queued, provider)

      {:ok, _provider} =
        Connections.update_provider_key(ctx.scope, provider, "main", %{
          value_id: "main",
          value: device_login(tokens: login_tokens(tag: "new"))
        })

      assert %Login{state: "signed_in", sign_in_cause: nil} =
               Repo.get_by!(Login, secret_value_id: value(provider, "main").id)

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["main"]
    end
  end

  describe "a sign-in that expires before the end of the run's time limit" do
    test "is refreshed in the background and the run waits, then starts on it", ctx do
      provider = provider!(ctx, [{"main", [expires_in: 3600]}])
      aged!(provider, "main")
      queued = queued!(ctx)

      assert {:ok, :none} = claim(ctx)
      waiting = waiting!(queued, provider)
      assert {:refreshing, _public_id, %{id: key_id, identity: _line}} = Waiting.reason(waiting)
      assert key_id == value(provider, "main").id

      # The claim made no call: the job does.
      assert requests() == []
      assert_enqueued(worker: LoginRefreshJob)

      assert %{success: 1} = Oban.drain_queue(queue: :default, with_safety: false)
      assert [%{"refresh_reason" => "proactive_expiry"}] = requests()

      assert {:ok, %{registered: run}} = claim(ctx)
      assert value_ids(Repo.get!(Run, run.id)) == ["main"]
      assert requests() == []
    end

    test "is refreshed for the first 6 keys of the key group's order alone", ctx do
      # Two providers of one key group with 4 keys each whose sign-ins expire within the
      # run's time limit: a run gets at most 6 keys, so the claim starts a refresh for 6.
      keys = fn tag -> for n <- 1..4, do: {"key-#{n}", [expires_in: 3600, tag: "#{tag}#{n}"]} end
      provider = provider!(ctx, keys.("north"))

      {:ok, other} =
        Connections.create_provider(ctx.scope, %{
          provider: "openai-subscription",
          keys:
            for({value_id, opts} <- keys.("south")) do
              key(value_id, device_login(tokens: login_tokens(opts)))
            end
        })

      for p <- [provider, other], n <- 1..4, do: aged!(p, "key-#{n}")
      queued!(ctx)

      assert {:ok, :none} = claim(ctx)

      # The choice's provider's 4 keys, added first, then 2 of the other provider's.
      jobs = for job <- all_enqueued(worker: LoginRefreshJob), do: job.args["secret_value_id"]
      assert length(jobs) == 6
      for n <- 1..4, do: assert(value(provider, "key-#{n}").id in jobs)
      assert Enum.count(1..4, &(value(other, "key-#{&1}").id in jobs)) == 2
      assert requests() == []
    end

    test "is refreshed past 6 keys that need a new sign-in", ctx do
      assert past_person_fixed(ctx, &sign_in_needed!/2) == :ok
    end

    test "is refreshed past 6 keys that need a new value", ctx do
      assert past_person_fixed(ctx, &rejected!/2) == :ok
    end

    test "of a 7th key of the key group shows no refresh on a waiting run", ctx do
      # 6 keys in cooldown, then a 7th, of another provider of the key group, whose
      # sign-in expires within the run's time limit and whose cooldown ends last: no claim
      # refreshes it, so the run waits for the first cooldown to end.
      now = DateTime.utc_now()
      first_end = DateTime.add(now, 600)
      cooled = for n <- 1..6, do: {"key-#{n}", [expires_in: 30 * 86_400, tag: "north#{n}"]}
      provider = provider!(ctx, cooled)
      for n <- 1..6, do: cooled!(provider, "key-#{n}", DateTime.add(first_end, n))
      other = other_provider!(ctx)
      aged!(other, "key-1")
      cooled!(other, "key-1", DateTime.add(now, 3600))

      assert {:cooldown, %Connection{}, until} =
               ModelKeys.waiting_reason([provider.id, other.id], now,
                 expires_before: DateTime.add(now, 7200)
               )

      assert DateTime.compare(until, DateTime.add(first_end, 1)) == :eq

      # A claim of the run starts no refresh.
      queued!(ctx)
      assert {:ok, :none} = claim(ctx)
      assert all_enqueued(worker: LoginRefreshJob) == []
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

      assert {:refreshing, _public_id, %{id: key_id, identity: _line}} = Waiting.reason(waiting)

      assert key_id == value(provider, "main").id
      assert requests() == []
    end
  end

  describe "what the run keeps" do
    test "has the provider's paths, and the account header and claim in its auth", ctx do
      provider = provider!(ctx, [{"main", []}])
      queued!(ctx)

      assert {:ok, %{registered: run}} = claim(ctx)

      assert [%{api: %{"paths" => ["/backend-api/codex/*"], "auth" => auth}}] =
               stored_keys(run.id)

      assert auth["account_header"] == "chatgpt-account-id"
      assert auth["account_claim"] == "/https:~1~1api.openai.com~1auth/chatgpt_account_id"
      assert Repo.get!(Run, run.id).provider_connection_id == provider.id

      assert {:ok, credential} = ProviderCredential.for_run(Repo.get!(Run, run.id))
      [%{entry: entry}] = credential.keys
      entry = Jason.decode!(Jason.encode!(entry))
      assert entry["paths"] == ["/backend-api/codex/*"]
      assert entry["auth"]["account_header"] == "chatgpt-account-id"
    end

    test "a claim of 6 keys with every member stays within the bounds of run_model_keys.api",
         ctx do
      names = for n <- 1..6, do: String.duplicate("k", 56) <> "-#{n}"
      provider = provider!(ctx, for(name <- names, do: {name, [tag: name]}))

      for {name, n} <- Enum.with_index(names, 1) do
        {:ok, _setting} =
          put_key_setting(ctx.scope, value(provider, name), %{
            pause_seconds: 604_800,
            use_up_to_percent: 99,
            reset_weekday: 7,
            reset_time: "23:59:59",
            reset_time_zone: "Pacific/Kiritimati"
          })

        # Five keys are in cooldown, so each has its cooldown time and its reset.
        if n > 1, do: key_state!(provider, name, until: in_seconds(86_400 * n))
      end

      queued!(ctx)
      assert {:ok, %{registered: run}} = claim(ctx)

      keys = stored_keys(run.id)
      assert length(keys) == 6
      assert Enum.any?(keys, & &1.cooldown_until)
      assert Enum.any?(keys, & &1.schedule_resets_at)

      %{rows: [[api_size]]} =
        Repo.query!(
          "SELECT max(octet_length(api::text)) FROM run_model_keys WHERE run_id = $1",
          [Ecto.UUID.dump!(run.id)]
        )

      assert api_size <= 8192
    end

    test "the paths and the account members of the real entry keep a key's api within 8192",
         ctx do
      provider = provider!(ctx, [{"main", []}])
      queued!(ctx)
      assert {:ok, %{registered: run}} = claim(ctx)

      %{rows: [[size]]} =
        Repo.query!("SELECT max(octet_length(api::text)) FROM run_model_keys WHERE run_id = $1", [
          Ecto.UUID.dump!(run.id)
        ])

      assert size <= 8192

      # Past the bounds the check refuses: a path without its slash, 33 paths, an empty
      # list, a member the check does not list.
      [%{api: api} | _] = stored_keys(run.id)
      assert Repo.get!(Run, run.id).provider_connection_id == provider.id

      for bad <- [
            Map.put(api, "paths", ["backend-api"]),
            Map.put(api, "paths", for(n <- 1..33, do: "/p#{n}")),
            Map.put(api, "paths", []),
            Map.put(api, "other", true)
          ] do
        assert_raise Postgrex.Error, ~r/run_model_keys_api_check/, fn ->
          Repo.update_all(from(k in Apiary.Runs.ModelKey, where: k.run_id == ^run.id),
            set: [api: bad]
          )
        end
      end
    end
  end
end
