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

  @doc "The next number of the workspace's runs, for a run a test writes straight to the table."
  def next_run_number(organisation_id, workspace_id) do
    {:ok, number} =
      Repo.transact(fn ->
        {:ok,
         Apiary.Runs.Number.next(%Apiary.Organisations.Workspace{
           id: workspace_id,
           organisation_id: organisation_id
         })}
      end)

    number
  end

  @doc "A pending run in the scope's workspace, as the receiver creates it on a first event."
  def run_fixture(%Scope{organisation: organisation, workspace: workspace}, attrs \\ %{}) do
    %Run{
      number: Apiary.RunEventsFixtures.next_run_number(organisation.id, workspace.id),
      organisation_id: organisation.id,
      workspace_id: workspace.id,
      node_run_id: Ecto.UUID.generate()
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
      node_event_id: Ecto.UUID.generate(),
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
      {1, "ping",
       %{
         "forager_version" => "v0.4.0",
         "contract_version" => 1,
         "events" => [],
         "interval_seconds" => 30
       }},
      {2, "run.started", started_data()},
      {3, "session.started", session_started_data()},
      {4, "run.policy_applied",
       %{
         "mode" => "enforce",
         "allow" => ["api.example.com"],
         "source" => "config",
         "digest" => String.duplicate("1a", 32)
       }},
      {5, "runtime.started", %{"session_id" => "session-1"}},
      {6, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("building\n")}},
      {7, "run.egress", egress_data()},
      {8, "run.egress",
       egress_data(%{
         "host" => "tracker.example.net",
         "decision" => "denied",
         "outcome" => "refused",
         "rule" => ""
       })},
      {9, "run.egress", egress_data(%{"outcome" => "dial_failed"}), time: at(7)},
      {10, "run.log", %{"stream" => "stderr", "bytes" => Base.encode64(<<255, 0, 10>>)}},
      {11, "run.heartbeat", %{"elapsed_seconds" => 30, "interval_seconds" => 30}, time: at(30)},
      {12, "run.policy_applied",
       %{
         "mode" => "enforce",
         "allow" => ["api.example.com"],
         "source" => "fetched",
         "url" => "https://qory.example.com/v1/run-configuration",
         "digest" => String.duplicate("2b", 32),
         "run_configuration" => "sha256=" <> String.duplicate("3c", 32)
       }, time: at(31)},
      {13, "run.heartbeat", %{"elapsed_seconds" => 60, "interval_seconds" => 20}, time: at(30)},
      {14, "something.unheard_of", %{"anything" => true}, time: at(61)},
      {15, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 61_500},
       time: at(61.5)}
    ]
  end

  @doc """
  A synthetic run with steps: a fetch and a compose of its host work, each with its log
  lines, the join step of its one session, the session and the run's exit.
  """
  def steps_record do
    [
      {1, "run.started", started_data()},
      {2, "run.step_started",
       %{"step" => 1, "name" => "fetch git.example.com/acme/shop", "kind" => "fetch"}},
      {3, "run.log", step_log_data(1, "Cloning into 'shop'...\n")},
      {4, "run.step_exited",
       %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1840}},
      {5, "run.step_started",
       %{"step" => 2, "name" => "compose the harness", "kind" => "compose"}},
      {6, "run.log", step_log_data(2, "composed 3 sources\n")},
      {7, "run.log", step_log_data(2, "wrote the settings\n")},
      {8, "run.step_exited",
       %{"step" => 2, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 620}},
      {9, "run.step_started", %{"step" => 3, "name" => "join session 1", "kind" => "join"}},
      {10, "run.step_exited",
       %{"step" => 3, "state" => "succeeded", "exit_code" => -1, "duration_ms" => 15}},
      {11, "session.started", session_started_data()},
      {12, "run.log",
       %{"stream" => "stdout", "bytes" => Base.encode64("all tests pass\n"), "session" => 1}},
      {13, "session.exited",
       %{"session" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 3000}},
      {14, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 14_000}}
    ]
  end

  @doc """
  A synthetic run of one session on pipes whose runtime reported its texts, tool results
  and denials (`dev.qory.runtime.text`, `.tool_result`, `.tool_denied`), as Forager maps a
  headless Claude Code session. A setup command of the session (step 1) prints 3 lines on
  stdout before the runtime starts; the runtime's stdout lines are numbered from 1 without
  them, and each event read from the output has its `line`.

  The runtime's stdout, by line: 1 the system record, 2 the first text, 3 the Skill call,
  4 its result, 5 the Bash call, 6 its denial, 7 thinking, 8 the last text, 9 the result.
  """
  def runtime_record do
    out = fn lines -> Enum.map_join(lines, &(&1 <> "\n")) end

    [
      {1, "run.started", started_data()},
      {2, "session.started", session_started_data()},
      {3, "run.step_started", %{"step" => 1, "name" => "prepare the inputs", "kind" => "setup"}},
      {4, "run.log",
       %{
         "stream" => "stdout",
         "bytes" => Base.encode64(out.(["setup 1", "setup 2", "setup 3"])),
         "session" => 1,
         "step" => 1
       }},
      {5, "run.step_exited",
       %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 40}},
      {6, "runtime.started",
       %{"session_id" => "session-1", "session" => 1, "source" => "startup", "model" => "opus"}},
      {7, "runtime.prompt_submitted",
       %{"session_id" => "session-1", "session" => 1, "prompt" => "/harness:hello"}},
      {8, "run.log",
       %{
         "stream" => "stdout",
         "bytes" =>
           Base.encode64(
             out.([
               ~s({"type":"system"}),
               ~s({"type":"assistant","text":1}),
               ~s({"type":"assistant","tool":"Skill"}),
               ~s({"type":"user","result":"Skill"})
             ])
           ),
         "session" => 1
       }},
      {9, "runtime.text",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "kind" => "text",
         "text" => "I'll greet **Dana** with the skill.",
         "line" => 2
       }},
      {10, "runtime.tool_started",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "tool" => "Skill",
         "tool_use_id" => "toolu_1",
         "input" => %{"skill" => "harness:greet", "args" => "Dana"},
         "summary" => "harness:greet",
         "line" => 3
       }},
      {11, "runtime.tool_result",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "tool_use_id" => "toolu_1",
         "content" => [%{"type" => "text", "text" => "Launching skill: harness:greet"}],
         "line" => 4
       }},
      {12, "runtime.tool_finished",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "tool" => "Skill",
         "tool_use_id" => "toolu_1",
         "input" => %{"skill" => "harness:greet", "args" => "Dana"},
         "summary" => "harness:greet",
         "duration_ms" => 80
       }},
      {13, "run.log",
       %{"stream" => "stderr", "bytes" => Base.encode64("warning: slow disk\n"), "session" => 1}},
      {14, "run.log",
       %{
         "stream" => "stdout",
         "bytes" =>
           Base.encode64(
             out.([
               ~s({"type":"assistant","tool":"Bash"}),
               ~s({"type":"user","denied":"Bash"}),
               ~s({"type":"assistant","thinking":1}),
               ~s({"type":"assistant","text":2}),
               ~s({"type":"result"})
             ])
           ),
         "session" => 1
       }},
      {15, "runtime.tool_started",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "tool" => "Bash",
         "tool_use_id" => "toolu_2",
         "input" => %{"command" => "echo \"Hello, Dana\""},
         "summary" => "echo \"Hello, Dana\"",
         "line" => 5
       }},
      {16, "runtime.tool_denied",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "tool" => "Bash",
         "tool_use_id" => "toolu_2",
         "message" => "Quoted text in this command can't be checked before it runs",
         "line" => 6
       }},
      {17, "runtime.text",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "kind" => "thinking",
         "text" => "The shell call was denied; answer in text.",
         "line" => 7
       }},
      {18, "runtime.text",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "kind" => "text",
         "text" => "# Hello, Dana\nWelcome to the Web shop of Acme.",
         "line" => 8
       }},
      {19, "runtime.turn_finished",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "message" => "# Hello, Dana\nWelcome to the Web shop of Acme."
       }},
      {20, "runtime.result",
       %{
         "session_id" => "session-1",
         "session" => 1,
         "outcome" => "success",
         "is_error" => false,
         "turns" => 6,
         "duration_ms" => 14_000,
         "cost_usd" => 0.0912,
         "result" => "# Hello, Dana\nWelcome to the Web shop of Acme.",
         "line" => 9
       }},
      {21, "runtime.ended", %{"session_id" => "session-1", "session" => 1, "reason" => "other"}},
      {22, "session.exited",
       %{"session" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 15_000}},
      {23, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 16_000}}
    ]
  end

  @doc "The data of a `run.log` line of step `step`, on stderr, as the host work writes it."
  def step_log_data(step, line),
    do: %{"stream" => "stderr", "bytes" => Base.encode64(line), "step" => step}

  @doc "The data of a `run.started`: the run's open, with no runtime."
  def started_data(extra \\ %{}) do
    Map.merge(
      %{
        "opened_by" => "run",
        "forager_version" => "v0.4.0",
        "host" => "dev-laptop",
        "labels" => %{
          "forge" => "git.example.com",
          "repository" => "acme/shop"
        }
      },
      extra
    )
  end

  @doc "The data of a `session.started`: session 1, the runtime it starts, on pipes."
  def session_started_data(extra \\ %{}) do
    Map.merge(
      %{
        "session" => 1,
        "runtime" => "claude",
        "runtime_version" => "2.1.0",
        "command" => "claude",
        "args" => ["-p", "fix the build"],
        "dir" => "/work",
        "interactive" => false
      },
      extra
    )
  end

  @doc """
  A `run.policy_applied` whose run has one tool, `files`, serving `files.tools.internal`
  under a path rule. Not a line of `priv/demo`.
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
  A run with one session and a tool: a tunnel to `api.example.com`, two calls to `files` on
  one path, both answered, and one on a path no rule allows, refused before it reached the
  tool.
  """
  def tool_record do
    [
      {1, "run.started", started_data()},
      {2, "session.started", session_started_data()},
      {3, "run.policy_applied", tool_policy_data()},
      {4, "run.egress", egress_data()},
      {5, "run.egress", tool_invocation_data()},
      {6, "run.egress",
       tool_invocation_data(%{
         "request_id" => "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
         "status" => 201
       })},
      {7, "run.egress",
       tool_invocation_data(%{
         "request_method" => "GET",
         "path" => "/media/acme/other/checkout.png",
         "path_rule" => "",
         "request_id" => "1f2e3d4c5b6a79880a9b8c7d6e5f4a3b",
         "decision" => "denied",
         "outcome" => "refused"
       })
       |> Map.delete("status")},
      {8, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 7_000}}
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
