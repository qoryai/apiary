defmodule Apiary.RunListFixtures do
  @moduledoc """
  Runs as the list and the connections pages read them: events stored and projected, timed
  back from now so that the default range (the last seven days) holds them.
  """

  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  @doc """
  A run that started `ago:` seconds ago (default 60) with `labels`, projected. Options:
  `runtime:`, `host:`, `egress:` (a list of overrides of `egress_data/1`), `exit:` (the
  data of `run.exited`), `heartbeat:` `{seconds_ago_received, elapsed, interval}`.
  """
  def started_run(scope, labels \\ %{}, opts \\ []) do
    run = run_fixture(scope)
    now = DateTime.utc_now()
    time = DateTime.add(now, -Keyword.get(opts, :ago, 60), :second)

    extra =
      opts |> Keyword.take([:runtime, :host]) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    event_fixture(run, 2, "run.started", started_data(Map.put(extra, "labels", labels)),
      time: time
    )

    for {egress, n} <- Enum.with_index(Keyword.get(opts, :egress, []), 3) do
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

  def shop(forge \\ "github.example"), do: %{"forge" => forge, "repository" => "acme/shop"}
end
