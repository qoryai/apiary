defmodule Apiary.RunEventsFixtures do
  @moduledoc """
  Test helpers for the projections: a run and its events written straight into the
  tables, the way the receiver leaves them, without going through the receiver.
  """

  alias Apiary.Accounts.Scope
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}

  @t0 ~U[2026-09-16 12:00:00.000000Z]

  @doc "The time the synthetic record starts at."
  def t0, do: @t0

  @doc "`seconds` after `t0/0`."
  def at(seconds), do: DateTime.add(@t0, round(seconds * 1000), :millisecond)

  @doc "A pending run in the scope's hive, as the receiver creates it on a first event."
  def run_fixture(%Scope{organisation: organisation, hive: hive}, attrs \\ %{}) do
    %Run{organisation_id: organisation.id, hive_id: hive.id, run_id: Ecto.UUID.generate()}
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Repo.insert!()
  end

  @doc """
  Stores one event of the run, unprojected. `type` is given without the `ai.qory.`
  prefix; the time defaults to `sequence` seconds after `t0/0`.
  """
  def event_fixture(%Run{} = run, sequence, type, data, opts \\ []) do
    Repo.insert!(%Event{
      organisation_id: run.organisation_id,
      hive_id: run.hive_id,
      run_id: run.id,
      sequence: sequence,
      event_id: Ecto.UUID.generate(),
      type: "ai.qory." <> type,
      time: Keyword.get(opts, :time) || at(sequence),
      data: data,
      received_at: DateTime.utc_now()
    })
  end

  @doc "Stores `{sequence, type, data}` or `{sequence, type, data, opts}` tuples."
  def events_fixture(%Run{} = run, events) do
    for event <- events do
      case event do
        {sequence, type, data} -> event_fixture(run, sequence, type, data)
        {sequence, type, data, opts} -> event_fixture(run, sequence, type, data, opts)
      end
    end
  end

  @doc "A whole synthetic run: every type the projector folds, and two it only marks."
  def record do
    [
      {1, "ping", %{"runner_version" => "v0.4.0", "contract_version" => 1, "events" => []}},
      {2, "run.started", started_data()},
      {3, "run.policy_applied",
       %{
         "mode" => "enforce",
         "allow" => ["api.example.com"],
         "source" => "config",
         "digest" => String.duplicate("1a", 32)
       }},
      {4, "session.started", %{"session_id" => "session-1"}},
      {5, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("building\n")}},
      {6, "run.egress", egress_data()},
      {7, "run.egress",
       egress_data(%{
         "host" => "tracker.example.net",
         "decision" => "denied",
         "outcome" => "refused",
         "rule" => ""
       })},
      {8, "run.egress", egress_data(%{"outcome" => "dial_failed"})},
      {9, "run.log", %{"stream" => "stderr", "bytes" => Base.encode64(<<255, 0, 10>>)}},
      {10, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30}, time: at(30)},
      {11, "run.policy_applied",
       %{
         "mode" => "enforce",
         "allow" => ["api.example.com"],
         "source" => "fetched",
         "url" => "https://qory.example.com/v1/run-configuration",
         "digest" => String.duplicate("2b", 32),
         "run_configuration" => "sha256=" <> String.duplicate("3c", 32)
       }, time: at(31)},
      {12, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 30}, time: at(60)},
      {13, "something.unheard_of", %{"anything" => true}, time: at(61)},
      {14, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 61_500},
       time: at(61.5)}
    ]
  end

  def started_data(extra \\ %{}) do
    Map.merge(
      %{
        "runtime" => "claude",
        "runtime_version" => "2.1.0",
        "command" => "claude",
        "args" => ["-p", "fix the build"],
        "dir" => "/work",
        "interactive" => false,
        "runner_version" => "v0.4.0",
        "host" => "dev-laptop",
        "labels" => %{
          "forge" => "git.example.com",
          "repository" => "acme/shop",
          "task" => "issue-12"
        }
      },
      extra
    )
  end

  def egress_data(extra \\ %{}) do
    Map.merge(
      %{
        "host" => "api.example.com",
        "port" => 443,
        "method" => "CONNECT",
        "decision" => "allowed",
        "outcome" => "connected",
        "mode" => "enforce",
        "rule" => "api.example.com"
      },
      extra
    )
  end
end
