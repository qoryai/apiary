defmodule Apiary.RunListFixtures do
  @moduledoc """
  Runs as the list and the connections pages read them: events stored and projected, timed
  back from now so that the default range (the last seven days) holds them.
  """

  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  @doc """
  A run that started `ago:` seconds ago (default 60) with `labels`, projected. Options:
  `about:` (what `run.started` says the run is about, such as `%{"title" => "Fix the
  build"}`), `runtime:`, `host:`, `opened_by: "gateway"` (a start a gateway sent, with no
  session), `egress:` (a list of overrides of `egress_data/1`), `exit:` (the
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
      |> Keyword.take([:about, :runtime, :host])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    data =
      case opts[:opened_by] do
        "gateway" -> gateway_started_data(Map.put(extra, "labels", labels))
        nil -> started_data(Map.put(extra, "labels", labels))
      end

    event_fixture(run, 2, "run.started", data, time: time)

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

  def shop(system \\ "github.example"), do: %{"forge" => system, "repository" => "acme/shop"}
end
