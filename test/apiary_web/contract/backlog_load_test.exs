defmodule ApiaryWeb.Contract.BacklogLoadTest do
  @moduledoc """
  A gateway's backlog after an outage, delivered to one Apiary: the runs of one access key
  send what they recorded while the server was away, `@in_flight` batches at once, oldest
  first, through the endpoint in-process (`Phoenix.ConnTest`), each signed as the contract
  has it and under a delivery id of its own.

  It asserts that no event is lost and none is stored twice; that no run lost in the
  outage is brought back by its backlog, and that each stays lost until its exit arrives;
  that the only refusals are `429` and `503` and that each clears on retry, after the
  `Retry-After` of a `429` and with Forager's backoff after a `503`; that a new run's
  configuration is served during the flush on the same key; and that the ping of a new run
  from another instance of the full node, sent as Forager's gateway sends it, is refused by
  no instance limit, only by the key's bucket. It prints what it measured: the wall time,
  the refusals, the most projections in flight at once, how the pool held, and the new
  run's tries and whether it opened.

  The pool is the one an instance runs with: `@pool_size` connections of a
  `DBConnection.ConnectionPool`, outside the sandbox, with projections in tasks, as in
  production. What the test commits goes with its organisation and its user when it
  ends. The scale is `@runs` runs of `@events_per_run` events each.

  It is tagged `:load` and left out of the suite (`test/test_helper.exs`). `--only load`
  runs it whatever the features, and the run configuration is the security policy's, so
  run it with QORY_FEATURES unset, or with the security feature on:

      mix test --only load test/apiary_web/contract/backlog_load_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :load
  # The run configuration is the security policy's.
  @moduletag needs: :security
  @moduletag timeout: :timer.minutes(30)

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Ecto.Query

  alias Apiary.{Policy, Repo}
  alias Apiary.AccessKeys.PublicKey
  alias Apiary.Runs
  alias Apiary.Runs.{Delivery, Event, Liveness, Projector, Run}
  alias Ecto.Adapters.SQL.Sandbox

  @runs 50
  @events_per_run 100
  @in_flight 8
  @pool_size 10
  # Seconds between two heartbeats, as the runs' pings announce, and between two lines
  # of a burst of output.
  @interval 30
  @output_spacing 0.15
  # How long the server was away, longer than the tolerance of 300 s and three
  # intervals, and how long before the outage the runs opened. A run's record ends at
  # least `@quiet` seconds before the flush: the tolerance, three intervals and a minute.
  @outage 1800
  @opened_before 120
  @quiet 300 + 3 * @interval + 60
  # The liveness check's tick in production.
  @tick :timer.seconds(15)
  # Forager's backoff after an answer it does not take: 1 s, doubling to a minute. As a
  # run opens, its gateway waits 1 s, then 2 s, between the tries of its ping, and starts
  # none more than 6 s after the run request.
  @backoff_max 60_000
  @open_waits [1000, 2000]
  @open_window 6000
  # Of the batches accepted, every `@answer_lost`th is sent again under the same delivery
  # id, its answer having been lost, and every `@cut_again`th again under a new one, cut
  # again after a restart.
  @answer_lost 10
  @cut_again 25

  @backlog_instance "i_gYKDhIWGh4iJiouMjY6PkA"
  @new_instance "i_AAECAwQFBgcICQoLDA0ODw"
  @labels "forge=git.example.com&repository=example-org%2Fexample-repo"

  setup_all do
    repo = Application.fetch_env!(:apiary, Repo)
    projector = Application.get_env(:apiary, Projector, [])

    restart_repo(
      repo
      |> Keyword.drop([:timeout])
      |> Keyword.merge(pool: DBConnection.ConnectionPool, pool_size: @pool_size)
    )

    Application.put_env(:apiary, Projector, Keyword.put(projector, :async, true))

    on_exit(fn ->
      Application.put_env(:apiary, Projector, projector)
      restart_repo(repo)
      Sandbox.mode(Repo, :manual)
    end)
  end

  defp restart_repo(config) do
    Application.put_env(:apiary, Repo, config)
    :ok = Supervisor.terminate_child(Apiary.Supervisor, Repo)
    {:ok, _pid} = Supervisor.restart_child(Apiary.Supervisor, Repo)
  end

  setup do
    %{scope: scope, user: user} = sign_up_fixture()

    # A Node, which runs one instance at a time; its workspace serves a run configuration.
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)

    # The ledger of public keys outlives the organisation, so the key's row goes on its own.
    on_exit(fn ->
      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Repo.delete_all(from p in PublicKey, where: p.key_id == ^key.key_id)
    end)

    {:ok, _} = Policy.deny(scope, nil, %{host: "ads.example"})

    %{scope: scope, key: key, secret: secret, node: node}
  end

  test "a backlog flushed after an outage loses nothing, revives no run and refuses only for a while",
       ctx do
    now = DateTime.utc_now()
    outage = DateTime.add(now, -@outage, :second)
    lost_at = DateTime.add(outage, @opened_before, :second)

    runs = for i <- 1..@runs, do: open_before_the_outage(ctx, i, outage)

    # A check 120 s into the outage, three intervals after each run's last heartbeat,
    # finds every run lost.
    lost = Liveness.check(lost_at) |> Enum.map(& &1.id) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(runs, & &1.run.id), lost)

    runs = Enum.map(runs, &backlog(&1, outage))
    recorded = for %{backlog: backlog} <- runs, event <- backlog, do: recorded_at(event)
    assert DateTime.diff(now, Enum.max(recorded, DateTime)) > 300 + 3 * @interval
    batches = runs |> Enum.flat_map(& &1.batches) |> Enum.sort_by(& &1.first, DateTime)
    batches = List.to_tuple(batches)
    Runs.subscribe(ctx.scope)

    stats = new_stats()
    pool = watch_pool()
    sampler = Task.async(fn -> sample(pool.pid, %{tasks: 0, queue: 0, busy: 0, samples: 0}) end)
    ticker = Task.async(fn -> tick([]) end)
    flush = Map.merge(ctx, %{stats: stats, batches: batches})

    {{elapsed, probes}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        :timer.tc(
          fn ->
            probes = Task.async(fn -> probe(flush, div(tuple_size(batches), 3)) end)
            flush = Map.put(flush, :probe, probes.pid)
            workers = for _ <- 1..@in_flight, do: Task.async(fn -> work(flush) end)
            Task.await_many(workers, :infinity)
            Task.await(probes, :infinity)
          end,
          :millisecond
        )
      end)

    unprojected_at_end = unprojected(runs)
    {drained_in, _} = :timer.tc(fn -> drain() end, :millisecond)
    unprojected_after_drain = unprojected(runs)
    send(sampler.pid, :stop)
    send(ticker.pid, :stop)
    sampled = Task.await(sampler)
    ticked = Task.await(ticker)
    :telemetry.detach(pool.handler)

    # What a projection that failed left is projected by the next check's sweep.
    Liveness.sweep(DateTime.add(DateTime.utc_now(), 11, :second))
    seen = seen_states()

    report(%{
      batches: tuple_size(batches),
      events: counts_events(runs),
      raised_by: stats.table |> :ets.lookup(:raised_by) |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      elapsed: elapsed,
      drained_in: drained_in,
      counts: counts(stats),
      sampled: sampled,
      waited: waited(pool),
      unprojected: {unprojected_at_end, unprojected_after_drain},
      log: failures(log),
      probes: probes
    })

    # Only 429 and 503, each cleared, every answer signed, every 429 with Retry-After.
    counts = counts(stats)
    assert :ets.lookup(stats.table, :unexpected) == []
    assert counts.raised == 0
    assert counts.unsigned == 0
    assert counts.without_retry_after == 0
    accepted = :ets.lookup(stats.table, :accepted) |> Enum.map(&elem(&1, 1)) |> MapSet.new()
    sent = batches |> Tuple.to_list() |> MapSet.new(& &1.delivery)
    assert MapSet.subset?(sent, accepted)

    # No event lost, none stored twice, each counted once on its run.
    assert stored(ctx.scope, runs) == expected(runs)

    for %{run: run} = flushed <- runs do
      stored_run = Repo.get!(Run, run.id)
      assert stored_run.event_count == 6 + length(flushed.backlog)
    end

    deliveries =
      Repo.all(
        from d in Delivery,
          where: d.access_key_id == ^ctx.key.id and d.instance_id == ^@backlog_instance
      )

    assert MapSet.new(deliveries, & &1.delivery_id) == accepted
    assert Enum.sum(Enum.map(deliveries, & &1.inserted_count)) == counts_events(runs)

    # No run came back: every projection left each run lost or ended, no check during
    # the flush found one lost again, and those without their exit are lost still.
    ids = MapSet.new(runs, & &1.run.id)

    for %{run: run, exit: exit?} <- runs do
      states = Map.get(seen, run.id, MapSet.new())
      allowed = if exit?, do: ["lost", "succeeded"], else: ["lost"]
      assert MapSet.subset?(states, MapSet.new(allowed))
    end

    assert Enum.filter(ticked, &MapSet.member?(ids, &1)) == []

    for %{run: run, exit: exit?} <- runs do
      stored_run = Repo.get!(Run, run.id)

      if exit? do
        assert %Run{state: "succeeded", lost_at: nil} = stored_run
      else
        assert %Run{state: "lost"} = stored_run
        assert stored_run.lost_at == lost_at
      end
    end

    # During the flush, right after a 429, a new run's configuration was served, and the
    # new run's ping from another instance of the full node was never refused by the
    # instance limit: only by the key's bucket, and then it is no run.
    assert %{configuration: 200, configuration_signed: true, signed: true} = probes
    assert %{after_429: true, flushing: true} = probes
    assert Enum.all?(probes.tries, &(&1 in [202, 429]))
    opened? = List.last(probes.tries) == 202

    if opened? do
      assert %Run{instance_id: @new_instance, node_id: node_id} =
               Repo.one!(from r in Run, where: r.run_id == ^probes.subject)

      assert node_id == ctx.node.id
    else
      refute Repo.exists?(from r in Run, where: r.run_id == ^probes.subject)
    end

    assert Liveness.check(DateTime.utc_now()) |> Enum.filter(&MapSet.member?(ids, &1.id)) == []
    assert Runs.count_alive(ctx.scope) == if(opened?, do: 1, else: 0)

    # The exits the gateway records once it is back end the runs that had none.
    exits = for flushed <- runs, not flushed.exit, do: exit_batch(flushed)
    stats = new_stats()
    work(%{flush | batches: List.to_tuple(exits), stats: stats})
    drain()
    assert :ets.lookup(stats.table, :unexpected) == []

    for %{run: run, exit: false} <- runs do
      assert %Run{state: "failed", reason: "gateway_lost", lost_at: nil} = Repo.get!(Run, run.id)
    end

    assert Runs.lost_since(ctx.scope, DateTime.add(now, -7 * 86_400, :second)) == []
  end

  ## Before the outage

  # A run of the node's instance, opened `@opened_before` seconds before the outage, which
  # beat every interval until it, each event received as it was recorded. Its machine's
  # clock is up to two seconds behind the server's. Written straight into the tables, at
  # the times they had: the delivery of the record is what is under test.
  defp open_before_the_outage(ctx, i, outage) do
    skew = rem(i * 37, 2000)
    opened = DateTime.add(outage, -@opened_before, :second)
    recorded = &DateTime.add(&1, -skew, :millisecond)

    run =
      run_fixture(ctx.scope, %{
        access_key_id: ctx.key.id,
        node_id: ctx.node.id,
        instance_id: @backlog_instance,
        inserted_at: opened,
        event_count: 6,
        last_event_at: outage
      })

    ping = %{
      "forager_version" => "0.4.0",
      "events" => ["*"],
      "contract_version" => 1,
      "interval_seconds" => @interval
    }

    first = [
      event_fixture(run, 1, "ping", ping, time: recorded.(opened), received_at: opened),
      event_fixture(run, 2, "run.started", started_data(),
        time: recorded.(opened),
        received_at: opened
      )
    ]

    beats =
      for k <- 1..4 do
        at = DateTime.add(opened, k * @interval, :second)
        beat = %{"elapsed_seconds" => k * @interval, "interval_seconds" => @interval}
        event_fixture(run, 2 + k, "run.heartbeat", beat, time: recorded.(at), received_at: at)
      end

    assert {:ok, %Run{state: "running", clock_offset_ms: ^skew}} = Projector.project(run)

    %{
      i: i,
      run: run,
      skew: skew,
      started: recorded.(opened),
      exit: rem(i, 2) == 0,
      live: Map.new(first ++ beats, &{&1.sequence, &1.event_id})
    }
  end

  ## The backlog

  # What the run recorded during the outage, from its first interval on: a heartbeat each
  # interval and a burst of output after it, then, for every other run, its exit; the runs
  # start a second apart within an interval. Ten events an interval, or more when the
  # outage is too short for that: the record ends `@quiet` seconds before the flush, so no
  # heartbeat of it is within the tolerance and three intervals of its arrival. Cut into
  # batches as Forager cuts them: at a hundred events, or one second after the batch's
  # first event.
  defp backlog(%{run: run, skew: skew} = flushed, outage) do
    windows = min(div(@events_per_run, 10), div(@outage - @quiet, @interval) - 2)
    logs = @events_per_run - windows - if(flushed.exit, do: 1, else: 0)
    per_window = div(logs + windows - 1, windows)
    start = DateTime.add(outage, rem(flushed.i, @interval), :second)
    at = &DateTime.add(start, round(&1 * 1000) - skew, :millisecond)

    timed =
      Enum.flat_map(1..windows, fn w ->
        beat =
          {w * @interval, "run.heartbeat",
           %{"elapsed_seconds" => @opened_before + w * @interval, "interval_seconds" => @interval}}

        count = min(per_window, logs - (w - 1) * per_window) |> max(0)

        output =
          for j <- 1..count//1,
              do:
                {w * @interval + 0.1 + @output_spacing * j, "run.log",
                 %{"stream" => "stdout", "bytes" => Base.encode64("line #{w}.#{j}\n")}}

        [beat | output]
      end)

    timed =
      if flushed.exit do
        ended = windows * @interval + 2

        timed ++
          [
            {ended, "run.exited",
             %{
               "state" => "succeeded",
               "exit_code" => 0,
               "duration_ms" => (@opened_before + ended) * 1000
             }}
          ]
      else
        timed
      end

    events =
      timed
      |> Enum.with_index(7)
      |> Enum.map(fn {{offset, type, data}, sequence} ->
        time = at.(offset)
        {time, wire_event(run.run_id, sequence, type, data, time: stamp(time))}
      end)

    batches =
      for {first, batch} <- cut(events) do
        %{first: first, body: Jason.encode!(batch), delivery: Ecto.UUID.generate()}
      end

    Map.merge(flushed, %{backlog: Enum.map(events, &elem(&1, 1)), batches: batches})
  end

  defp cut(events) do
    Enum.chunk_while(
      events,
      nil,
      fn
        {time, event}, nil ->
          {:cont, {time, 1, [event]}}

        {time, event}, {first, count, batch} ->
          if count < 100 and DateTime.diff(time, first, :millisecond) < 1000,
            do: {:cont, {first, count + 1, [event | batch]}},
            else: {:cont, {first, Enum.reverse(batch)}, {time, 1, [event]}}
      end,
      fn
        nil -> {:cont, nil}
        {first, _count, batch} -> {:cont, {first, Enum.reverse(batch)}, nil}
      end
    )
  end

  # The exit Forager adds to a session's record that has none when the gateway sends it
  # again: numbered after the record's last event, dated by the clock of the machine that
  # sends it again, now, and lasting from the run's start to the record's last event.
  defp exit_batch(%{run: run, skew: skew, started: started, backlog: backlog}) do
    last = List.last(backlog)
    sequence = String.to_integer(last["sequence"]) + 1
    now = DateTime.add(DateTime.utc_now(), -skew, :millisecond)

    data = %{
      "state" => "failed",
      "exit_code" => -1,
      "reason" => "gateway_lost",
      "duration_ms" => DateTime.diff(recorded_at(last), started, :millisecond)
    }

    event = wire_event(run.run_id, sequence, "run.exited", data, time: stamp(now))
    %{first: now, body: Jason.encode!([event]), delivery: Ecto.UUID.generate()}
  end

  defp recorded_at(event) do
    {:ok, time, 0} = DateTime.from_iso8601(event["time"])
    time
  end

  defp stamp(time), do: time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  ## The gateway

  # One of `@in_flight`: takes the oldest batch nobody has taken and sends it until it is
  # accepted, then the next.
  defp work(%{batches: batches, stats: stats} = flush) do
    n = :atomics.add_get(stats.next, 1, 1)

    if n <= tuple_size(batches) do
      batch = elem(batches, n - 1)

      if deliver(flush, batch.body, batch.delivery) == 202 do
        if rem(n, @answer_lost) == 0, do: deliver(flush, batch.body, batch.delivery)
        if rem(n, @cut_again) == 0, do: deliver(flush, batch.body, Ecto.UUID.generate())
      end

      work(flush)
    else
      :ok
    end
  end

  # Sends one batch until an answer ends it, as Forager does: after a 429 it waits what
  # Retry-After says, after a 503 or no answer it backs off. Returns the last status.
  defp deliver(flush, body, delivery, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 0)

    case post(flush, body, delivery, @backlog_instance) do
      {:raised, module} ->
        bump(flush.stats, :raised)
        :ets.insert(flush.stats.table, {:raised_by, module})
        Process.sleep(backoff(attempt))
        deliver(flush, body, delivery, Keyword.put(opts, :attempt, attempt + 1))

      %Plug.Conn{status: status} = conn ->
        if not signed_answer?(conn), do: bump(flush.stats, :unsigned)

        case status do
          202 ->
            bump(flush.stats, :accepted)
            :ets.insert(flush.stats.table, {:accepted, delivery})
            202

          429 ->
            bump(flush.stats, :rate_limited)
            if probe = flush[:probe], do: send(probe, :refused)

            case Plug.Conn.get_resp_header(conn, "retry-after") do
              [seconds] ->
                Process.sleep(String.to_integer(seconds) * 1000)

              _ ->
                bump(flush.stats, :without_retry_after)
                Process.sleep(1000)
            end

            deliver(flush, body, delivery, opts)

          503 ->
            bump(flush.stats, :unavailable)
            Process.sleep(backoff(attempt))
            deliver(flush, body, delivery, Keyword.put(opts, :attempt, attempt + 1))

          status ->
            :ets.insert(flush.stats.table, {:unexpected, {status, conn.resp_body}})
            status
        end
    end
  end

  # One try: the answer, or what was raised in place of one.
  defp post(flush, body, delivery, instance) do
    signed_post(Phoenix.ConnTest.build_conn(), flush.key.key_id, flush.secret, body,
      delivery: delivery,
      instance_id: instance
    )
  rescue
    exception -> {:raised, exception.__struct__}
  end

  defp backoff(attempt), do: min(1000 * Integer.pow(2, attempt), @backoff_max)

  # Once a third of the backlog is in, a new run starts on another instance of the node,
  # right after a batch of the flush was refused 429, so the key's events bucket is empty.
  # Its gateway asks as Forager's does when a run opens: up to three tries of the ping,
  # under one delivery id, the second 1 s after the first ends and the third 2 s after the
  # second, again only after no answer, a 5xx or a signed 429 `rate_limited`, without
  # reading Retry-After, and none started more than 6 s after the run request. A ping still
  # refused is no run. The configuration is asked right after the ping's first try,
  # whatever its answer, so that it too is asked while the bucket is empty.
  defp probe(%{stats: stats} = flush, after_batches) do
    if :counters.get(stats.counters, index(:accepted)) < after_batches do
      Process.sleep(10)
      probe(flush, after_batches)
    else
      refused_before = :counters.get(stats.counters, index(:rate_limited))
      forget_refusals()
      after_429 = receive(do: (:refused -> true), after: (30_000 -> false))
      requested = System.monotonic_time(:millisecond)

      {subject, [ping, _started]} = first_events()
      body = Jason.encode!([ping])
      delivery = Ecto.UUID.generate()
      first = post(flush, body, delivery, @new_instance)
      ended = System.monotonic_time(:millisecond)

      configuration =
        signed_get(
          Phoenix.ConnTest.build_conn(),
          flush.key.key_id,
          flush.secret,
          "/v1/run-configuration?" <> @labels,
          instance_id: @new_instance
        )

      tries = ping_tries(flush, body, delivery, requested, [first], ended, @open_waits)

      %{
        configuration: configuration.status,
        configuration_signed: signed_answer?(configuration),
        tries: Enum.map(tries, &answered/1),
        signed:
          Enum.all?(tries, &match?(%Plug.Conn{}, &1)) and Enum.all?(tries, &signed_answer?/1),
        after_429: after_429,
        events_refused_before: refused_before,
        subject: subject,
        flushing: :counters.get(stats.counters, index(:accepted)) < tuple_size(flush.batches)
      }
    end
  end

  defp forget_refusals do
    receive do
      :refused -> forget_refusals()
    after
      0 -> :ok
    end
  end

  defp ping_tries(flush, body, delivery, requested, [last | _] = tries, ended, waits) do
    case waits do
      [wait | rest] ->
        if passing?(last) and ended + wait - requested <= @open_window do
          Process.sleep(max(wait - (System.monotonic_time(:millisecond) - ended), 0))
          answer = post(flush, body, delivery, @new_instance)
          ended = System.monotonic_time(:millisecond)
          ping_tries(flush, body, delivery, requested, [answer | tries], ended, rest)
        else
          Enum.reverse(tries)
        end

      [] ->
        Enum.reverse(tries)
    end
  end

  # What Forager asks again as a run opens: no answer, a 5xx, a signed 429 `rate_limited`.
  defp passing?({:raised, _module}), do: true
  defp passing?(%Plug.Conn{status: status}) when status >= 500, do: true

  defp passing?(%Plug.Conn{status: 429} = conn),
    do: signed_answer?(conn) and Jason.decode!(conn.resp_body)["error"] == "rate_limited"

  defp passing?(_answer), do: false

  defp answered({:raised, module}), do: module
  defp answered(%Plug.Conn{status: status}), do: status

  ## What is measured

  @counted [:accepted, :rate_limited, :unavailable, :raised, :unsigned, :without_retry_after]

  defp index(name), do: Enum.find_index(@counted, &(&1 == name)) + 1

  defp bump(stats, name), do: :counters.add(stats.counters, index(name), 1)

  defp counts(stats), do: Map.new(@counted, &{&1, :counters.get(stats.counters, index(&1))})

  # The next batch to take, the answers counted, and what is kept of them.
  defp new_stats do
    %{
      next: :atomics.new(1, signed: false),
      counters: :counters.new(length(@counted), [:write_concurrency]),
      table: :ets.new(:backlog_load, [:bag, :public, write_concurrency: true])
    }
  end

  # The pool's process, and from the repo's telemetry the longest a query waited for a
  # connection, in microseconds, how many waited longer than the pool's target of 50 ms,
  # and how many took one from the pool.
  defp watch_pool do
    handler = "backlog-load-#{System.unique_integer([:positive])}"
    queue = :atomics.new(3, signed: false)
    :telemetry.attach(handler, [:apiary, :repo, :query], &__MODULE__.queue_time/4, queue)
    %{handler: handler, queue: queue, pid: Ecto.Adapter.lookup_meta(Repo).pid}
  end

  @doc false
  def queue_time(_event, %{queue_time: native}, _metadata, queue) when is_integer(native) do
    waited = System.convert_time_unit(native, :native, :microsecond)
    :atomics.add(queue, 3, 1)
    if waited > 50_000, do: :atomics.add(queue, 2, 1)
    raise_to(queue, waited)
  end

  def queue_time(_event, _measurements, _metadata, _queue), do: :ok

  defp raise_to(queue, waited) do
    current = :atomics.get(queue, 1)

    if waited > current and :atomics.compare_exchange(queue, 1, current, waited) != :ok,
      do: raise_to(queue, waited),
      else: :ok
  end

  defp waited(pool), do: Enum.map(1..3, &:atomics.get(pool.queue, &1))

  # Every 5 ms: the projections in flight and the pool's connections, none free when the
  # pool is busy.
  defp sample(pool, acc) do
    receive do
      :stop -> acc
    after
      5 ->
        tasks = length(Task.Supervisor.children(Apiary.Runs.TaskSupervisor))

        [%{ready_conn_count: ready, checkout_queue_length: queue}] =
          DBConnection.get_connection_metrics(pool)

        sample(pool, %{
          tasks: max(acc.tasks, tasks),
          queue: max(acc.queue, queue),
          busy: acc.busy + if(ready == 0, do: 1, else: 0),
          samples: acc.samples + 1
        })
    end
  end

  # The liveness check at its production tick, through the flush: the runs it finds lost.
  defp tick(found) do
    receive do
      :stop -> found
    after
      @tick -> tick(found ++ Enum.map(Liveness.check(), & &1.id))
    end
  end

  # Until no projection task is left.
  defp drain do
    if Task.Supervisor.children(Apiary.Runs.TaskSupervisor) != [] do
      Process.sleep(20)
      drain()
    end
  end

  defp unprojected(runs) do
    ids = Enum.map(runs, & &1.run.id)
    Repo.aggregate(from(e in Event, where: e.run_id in ^ids and is_nil(e.projected_at)), :count)
  end

  # Each run's states, as every projection and check broadcast them.
  defp seen_states(acc \\ %{}) do
    receive do
      {:run_changed, %Run{id: id, state: state}} ->
        seen_states(Map.update(acc, id, MapSet.new([state]), &MapSet.put(&1, state)))
    after
      0 -> acc
    end
  end

  defp stored(scope, runs) do
    subjects = Enum.map(runs, & &1.run.run_id)

    Repo.all(
      from e in Event,
        join: r in Run,
        on: r.id == e.run_id,
        where: r.workspace_id == ^scope.workspace.id and r.run_id in ^subjects,
        select: {r.run_id, e.sequence, e.event_id}
    )
    |> Enum.sort()
  end

  defp expected(runs) do
    Enum.flat_map(runs, fn %{run: run, live: live, backlog: backlog} ->
      Enum.map(live, fn {sequence, id} -> {run.run_id, sequence, id} end) ++
        Enum.map(backlog, &{run.run_id, String.to_integer(&1["sequence"]), &1["id"]})
    end)
    |> Enum.sort()
  end

  defp counts_events(runs), do: Enum.sum(Enum.map(runs, &length(&1.backlog)))

  # The lines the receiver, the projector and the check log when the database fails them.
  defp failures(log) do
    for pattern <- [
          "a delivery could not be stored",
          "projection failed",
          "sweep failed",
          "key heartbeat not recorded",
          "event skipped"
        ],
        count = log |> String.split("\n") |> Enum.count(&String.contains?(&1, pattern)),
        count > 0,
        into: %{},
        do: {pattern, count}
  end

  defp report(m) do
    [waited, slow, queries] = m.waited
    {at_end, after_drain} = m.unprojected

    IO.puts("""

    Backlog load: #{@runs} runs × #{@events_per_run} events, #{m.events} events in #{m.batches} batches, #{@in_flight} in flight, pool of #{@pool_size}
      wall time            #{m.elapsed} ms, projections drained #{m.drained_in} ms later
      answers              #{m.counts.accepted} × 202, #{m.counts.rate_limited} × 429, #{m.counts.unavailable} × 503, #{m.counts.raised} raised #{inspect(m.raised_by)}
      projections          at most #{m.sampled.tasks} in flight at once; events unprojected #{at_end} at the end, #{after_drain} once drained
      pool                 longest wait #{div(waited, 1000)} ms, #{slow} of #{queries} checkouts waited over 50 ms, at most #{m.sampled.queue} waiting at once, none free in #{m.sampled.busy} of #{m.sampled.samples} samples
      failures logged      #{inspect(m.log)}
      new run              configuration #{m.probes.configuration}, ping tries #{inspect(m.probes.tries)}: #{if List.last(m.probes.tries) == 202, do: "opened", else: "no run"}; asked after #{m.probes.events_refused_before} batches had been refused 429
    """)
  end
end
