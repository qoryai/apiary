defmodule Apiary.RunListFixtures do
  @moduledoc """
  Runs as the list and the connections pages read them: events stored and projected, timed
  back from now so that the default range (the last seven days) holds them.
  """

  import Apiary.RunEventsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Repo
  alias Apiary.Runs.{Projector, Run}
  alias Apiary.WorkItems.WorkItemEvent

  @doc """
  A run that started `ago:` seconds ago (default 60) with `labels`, projected. Options:
  `about:` (what `run.started` says the run is about, such as `%{"title" => "Fix the
  build"}`), `runtime:` (of its `session.started`), `host:`, `egress:` (a list of overrides of `egress_data/1`), `exit:` (the
  data of `run.exited`), `heartbeat:` `{seconds_ago_received, elapsed, interval}`, `now:`
  the moment `ago:` and the heartbeat count back from (default the clock), for a test that
  reads by UTC day: a clock just after midnight would put a run of a minute ago on
  yesterday.
  """
  def started_run(scope, labels \\ %{}, opts \\ []) do
    run = run_fixture(scope)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    time = DateTime.add(now, -Keyword.get(opts, :ago, 60), :second)

    extra =
      opts
      |> Keyword.take([:about, :host])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    data = started_data(Map.put(extra, "labels", labels))
    session = if runtime = opts[:runtime], do: %{"runtime" => runtime}, else: %{}

    event_fixture(run, 2, "run.started", data, time: time)
    event_fixture(run, 3, "session.started", session_started_data(session), time: time)

    for {egress, n} <- Enum.with_index(Keyword.get(opts, :egress, []), 4) do
      event_fixture(run, n, "run.egress", egress_data(egress),
        time: DateTime.add(time, n, :second)
      )
    end

    case opts[:heartbeat] do
      {received_ago, elapsed, interval} ->
        event_fixture(
          run,
          40,
          "run.heartbeat",
          %{"elapsed_seconds" => elapsed, "interval_seconds" => interval},
          time: DateTime.add(now, -received_ago, :second),
          received_at: DateTime.add(now, -received_ago, :second)
        )

      nil ->
        :ok
    end

    if exit = opts[:exit] do
      event_fixture(run, 50, "run.exited", exit, time: DateTime.add(time, 45, :second))
    end

    {:ok, run} = Projector.project(run)
    run
  end

  def shop(system \\ "github.example"), do: %{"forge" => system, "repository" => "acme/shop"}

  @doc """
  Makes `run`, a run of the scope's workspace, a run of its queue, as a claim registers
  one, and returns the run of the queue. Options: `step:` ("explore" unless set;
  "prebuild" makes a prebuild of a fresh collection and pool, with no work item),
  `work_item:` (a fresh work item of the workspace unless given), `take_in:` (1),
  `attempt:` (1) of `of:` (3), `walk:` its harness walk, `%{state:, origin:, workflow:}`
  (none unless given; a document is put for the origins that need one), and `queued:`,
  the other fields of the run of the queue (`image_requeue`, `stage_id`, `round`,
  `loop_entry`, `process_version_id`), as the stage runner writes them.
  """
  def queue_run!(%Scope{} = scope, %Run{} = run, opts \\ []) do
    queued =
      case Keyword.get(opts, :step, "explore") do
        "prebuild" ->
          collection =
            Apiary.WorkItemsFixtures.source_collection_fixture(
              scope,
              Apiary.WorkItemsFixtures.ticket_connection_fixture(scope)
            )

          %DispatchRun{organisation_id: run.organisation_id, workspace_id: run.workspace_id}
          |> DispatchRun.prebuild_changeset(%{
            source_collection_id: collection.id,
            pool_id: Apiary.NodesFixtures.pool_fixture(scope).id,
            environment_ref: "main",
            queued_at: DateTime.utc_now()
          })

        step ->
          work_item =
            Keyword.get_lazy(opts, :work_item, fn ->
              Apiary.WorkItemsFixtures.work_item_fixture(scope)
            end)

          %DispatchRun{organisation_id: run.organisation_id, workspace_id: run.workspace_id}
          |> DispatchRun.queue_changeset(%{
            work_item_id: work_item.id,
            step: step,
            take_in: Keyword.get(opts, :take_in, 1),
            attempt: Keyword.get(opts, :attempt, 1),
            of: Keyword.get(opts, :of, 3),
            queued_at: DateTime.utc_now()
          })
      end
      |> Ecto.Changeset.change(Map.new(Keyword.get(opts, :queued, [])))
      |> Ecto.Changeset.change(state: :handed_over)
      |> Repo.insert!()

    case opts[:walk] do
      %{} = walk ->
        document = if walk[:origin] in [:setting, :builtin], do: %{"modules" => []}

        Repo.insert!(%RunHarness{
          dispatch_run_id: queued.id,
          state: walk[:state],
          origin: walk[:origin],
          workflow: walk[:workflow],
          document: document
        })

      nil ->
        nil
    end

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [dispatch_run_id: queued.id])

    queued
  end

  @doc """
  Writes an event of `work_item` of `kind` (`:taken_in`, `:answered` or `:explore_again`)
  by `user`, with `data`, at `at` (now unless given), as the work item's moves write
  them.
  """
  def work_item_event!(work_item, kind, user, data, at \\ DateTime.utc_now()) do
    %WorkItemEvent{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id
    }
    |> WorkItemEvent.changeset(%{
      kind: kind,
      actor_kind: :person,
      actor_id: user.id,
      at: at,
      data: data
    })
    |> Repo.insert!()
  end
end
