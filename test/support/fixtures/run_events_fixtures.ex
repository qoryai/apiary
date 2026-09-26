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

  @doc "A pending run in the scope's workspace, as the receiver creates it on a first event."
  def run_fixture(%Scope{organisation: organisation, workspace: workspace}, attrs \\ %{}) do
    %Run{
      organisation_id: organisation.id,
      workspace_id: workspace.id,
      run_id: Ecto.UUID.generate()
    }
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Repo.insert!()
  end

  @doc """
  Stores one event of the run, unprojected. `type` is given without the `dev.qory.`
  prefix; `time:` defaults to `sequence` seconds after `t0/0` and `received_at:` to a
  hundred seconds after the time, so that the two clocks are told apart and two receptions
  of one record project the same.
  """
  def event_fixture(%Run{} = run, sequence, type, data, opts \\ []) do
    time = Keyword.get(opts, :time) || at(sequence)

    Repo.insert!(%Event{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      sequence: sequence,
      event_id: Ecto.UUID.generate(),
      type: "dev.qory." <> type,
      time: time,
      data: data,
      received_at: Keyword.get(opts, :received_at) || DateTime.add(time, 100, :second)
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

  @doc """
  A whole synthetic run: every type the projector folds, and two it only marks. The two
  attempts on `api.example.com` carry one time, and so do the two heartbeats: only the
  sequence tells which is the last.
  """
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
      {8, "run.egress", egress_data(%{"outcome" => "dial_failed"}), time: at(6)},
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
      {12, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 20}, time: at(30)},
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

  @doc """
  A `run.policy_applied` whose run has one tool, `files`, serving `files.tools.internal`
  under a path rule. Not a line of `priv/demo`: the contract fixtures at the pinned ref
  have no tools yet.
  """
  def tool_policy_data(extra \\ %{}) do
    Map.merge(
      %{
        "mode" => "enforce",
        "allow" => ["api.example.com", "files.tools.internal"],
        "deny" => [],
        "source" => "config",
        "digest" => String.duplicate("4f", 32),
        "paths" => %{"files.tools.internal" => ["/media/acme/shop/*"]},
        "tools" => [%{"name" => "files", "hosts" => ["files.tools.internal"]}],
        "terminated" => ["files.tools.internal"]
      },
      extra
    )
  end

  @doc """
  A tool invocation: a request to `files.tools.internal` handed to the tool `files`, which
  answered 200.
  """
  def tool_invocation_data(extra \\ %{}) do
    egress_data(%{
      "host" => "files.tools.internal",
      "method" => "HTTPS",
      "request_method" => "PUT",
      "path" => "/media/acme/shop/checkout.png",
      "path_rule" => "/media/acme/shop/*",
      "tool" => "files",
      "request_id" => "8d0c3f6a1b2e4d5f9a7c6b5e4d3c2b1a",
      "status" => 200,
      "rule" => "files.tools.internal"
    })
    |> Map.merge(extra)
  end

  @doc """
  A run with a tool: a tunnel to `api.example.com`, two calls to `files` on one path, both
  answered, and one on a path no rule allows, refused before it reached the tool.
  """
  def tool_record do
    [
      {1, "run.started", started_data()},
      {2, "run.policy_applied", tool_policy_data()},
      {3, "run.egress", egress_data()},
      {4, "run.egress", tool_invocation_data()},
      {5, "run.egress",
       tool_invocation_data(%{
         "request_id" => "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
         "status" => 201
       })},
      {6, "run.egress",
       tool_invocation_data(%{
         "request_method" => "GET",
         "path" => "/media/acme/other/checkout.png",
         "path_rule" => "",
         "request_id" => "1f2e3d4c5b6a79880a9b8c7d6e5f4a3b",
         "decision" => "denied",
         "outcome" => "refused"
       })
       |> Map.delete("status")},
      {7, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 7_000}}
    ]
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
