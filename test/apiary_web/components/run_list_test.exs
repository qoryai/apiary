defmodule ApiaryWeb.RunListTest do
  # The Run list (`ApiaryWeb.PreparationComponents.run_list/1`): the heading with the
  # pool and the run's state, and its total time; the steps' names and their order; Queue
  # the run, Request a machine; each Agent session with Prepare the session, Run the agent
  # and the Timeline inside it, closed or open by default, and Save the outputs; Skipped
  # rows after a failure; the cause line; helper steps; the rows of every pool. Start the
  # machine and Prepare the machine are in `ApiaryWeb.PreparationStepsTest`, Remove the
  # machine in `ApiaryWeb.PreparationCleanUpTest`.
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ApiaryWeb.{Format, PreparationComponents}

  @queued ~U[2026-11-06 00:30:00.000000Z]

  # Seconds after the run was queued.
  defp at(seconds), do: DateTime.add(@queued, round(seconds * 1000), :millisecond)

  defp machine(changes \\ %{}) do
    Map.merge(
      %{
        dispatch_id: "dp_0123456789abcdef",
        pool: %{id: "np_0123456789abcdef", name: "build-pool", place: :workspace, operator: nil},
        queued_at: @queued,
        machine_type: nil,
        requested_at: at(12),
        requested_ms: 2_000,
        started_as: nil,
        release_reason: nil,
        handed_over_at: at(14),
        ended_at: at(400),
        end: nil,
        removal_cause: :run_ended,
        started: %{state: "succeeded", started_at: at(14), ended_at: at(55), duration_ms: 41_000}
      },
      changes
    )
  end

  # A step from `started` seconds after the queue, for `took` seconds. Its place among
  # the run's events, its sequence, is its start in seconds, as an agent session's is.
  defp step(number, kind, name, started, took, changes \\ %{}) do
    Map.merge(
      %{
        number: number,
        name: name,
        kind: kind,
        state: "succeeded",
        exit_code: 0,
        started_at: at(started),
        exited_at: at(started + took),
        started_sequence: round(started),
        exited_sequence: round(started + took),
        duration_ms: round(took * 1000),
        output: %{lines: [], truncated: false, lines_cut: false}
      },
      changes
    )
  end

  defp session_end(changes \\ %{}) do
    Map.merge(
      %{
        result_at: at(380),
        outcome: "success",
        turns: 14,
        duration_ms: 229_000,
        cost_usd: 0.84,
        exited_at: at(382),
        state: "succeeded",
        exit_code: 0,
        model: "model-large-1"
      },
      changes
    )
  end

  # A run that ended: queued at 0 s, claimed at 12 s, `dispatched` at 14 s, redeemed at
  # 55 s, the fetch from 56 s to 60 s, the join from 60 s to 70 s, its session from 70 s
  # to 382 s, a push from 383 s to 385 s, its end at 400 s. Its one agent session is the
  # one from `session_started_at` to `session_end`, with the sequence 70, unless
  # `sessions` is given.
  defp preparation(changes \\ %{}) do
    %{}
    |> Map.merge(%{
      machine: machine(),
      steps: [step(1, "fetch", "Fetch", 56, 4), step(2, "join", "Join session 1", 60, 10)],
      after_session: [
        step(3, "push", "Push proposal", 383, 2, %{output: %{lines: [], truncated: false}})
      ],
      log_pruned_at: nil,
      session_started_at: at(70),
      session_end: session_end(),
      outputs: [%{type: "proposal", number: 3, at: at(384)}],
      stopped: nil
    })
    |> Map.merge(changes)
    |> then(&Map.put_new(&1, :sessions, sessions(&1)))
  end

  defp sessions(%{session_started_at: nil}), do: []

  defp sessions(%{session_started_at: at, session_end: finished}),
    do: [%{session: 1, sequence: 70, started_at: at, end: finished}]

  defp list(preparation, opts \\ []) do
    assigns = %{
      preparation: preparation,
      alive: Keyword.get(opts, :alive, false),
      clean_up: Keyword.get(opts, :clean_up),
      session_open: Keyword.get(opts, :session_open),
      run_state: Keyword.get(opts, :run_state),
      machine_log: Keyword.get(opts, :machine_log, :hidden),
      wall: Keyword.get(opts, :wall, true)
    }

    ~H"""
    <PreparationComponents.run_list
      preparation={@preparation}
      alive={@alive}
      clean_up={@clean_up}
      session_open={@session_open}
      run_state={@run_state}
      machine_log={@machine_log}
      wall={@wall}
    >
      <:session :let={session}>
        <ol id={"timeline-in-session-#{session}"}></ol>
      </:session>
    </PreparationComponents.run_list>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp text(html), do: html |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # The ids of the list's top-level rows.
  defp rows(html),
    do: html |> LazyHTML.query("#prepare-machine > ol > li > [id]") |> LazyHTML.attribute("id")

  # The ids of the rows directly inside the row `id`.
  defp children(html, id),
    do: html |> LazyHTML.query("##{id} > .q-xb > ol > li > [id]") |> LazyHTML.attribute("id")

  # The names of the rows that `selector` matches.
  defp names(html, selector) do
    html
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.query(".q-prep-name") |> Enum.at(0) |> text()))
  end

  defp top_names(html), do: names(html, "#prepare-machine > ol > li > [id]")
  defp child_names(html, id), do: names(html, "##{id} > .q-xb > ol > li > [id]")

  defp started(html, id),
    do:
      html
      |> LazyHTML.query("##{id} .q-tc1 time")
      |> LazyHTML.attribute("datetime")
      |> Enum.take(1)

  defp took(html, id) do
    html
    |> LazyHTML.query("##{id}.q-prep-row .q-tc2, ##{id} > summary .q-tc2")
    |> text()
  end

  defp facts(html, id) do
    terms = html |> LazyHTML.query("##{id} dl dt") |> Enum.map(&text/1)
    values = html |> LazyHTML.query("##{id} dl dd") |> Enum.map(&text/1)
    Enum.zip(terms, values)
  end

  defp count(html, selector), do: html |> LazyHTML.query(selector) |> Enum.count()

  defp iso(seconds), do: [DateTime.to_iso8601(at(seconds))]

  # An event's time as a row's line shows it.
  defp clock(seconds), do: Format.time(at(seconds), seconds: true)

  defp skipped(html),
    do:
      html
      |> LazyHTML.query("div.q-prep-skipped[data-state=skipped]")
      |> LazyHTML.attribute("id")

  test "the rows of a run that ended, in time order" do
    html = list(preparation(), clean_up: {:report, :gone, at(430)})

    assert rows(html) == [
             "prepare-machine-queue",
             "prepare-machine-request",
             "prepare-machine-start",
             "prepare-machine-prepare",
             "prepare-machine-session",
             "prepare-machine-remove"
           ]

    assert html |> LazyHTML.query("#prepare-machine-h") |> text() == "Run on build-pool"
  end

  describe "the steps' names" do
    test "the top-level steps in order; an agent session's steps, Start the agent first" do
      steps = [
        step(1, "fetch", "Fetch", 56, 4),
        step(2, "join", "Join session 1", 60, 9),
        step(3, "wall", "Wall", 75, 1)
      ]

      html = list(preparation(%{steps: steps}), clean_up: {:report, :gone, at(430)})

      assert top_names(html) == [
               "Queue the run",
               "Request a machine",
               "Start the machine",
               "Prepare the machine",
               "Agent session 1",
               "Remove the machine"
             ]

      assert child_names(html, "prepare-machine-prepare") == ["Clone the repository"]

      assert child_names(html, "prepare-machine-session") == [
               "Prepare the session",
               "Run the agent",
               "Save the outputs"
             ]

      assert child_names(html, "prepare-machine-session-prepare") == [
               "Start the agent",
               "Start the wall"
             ]
    end

    test "a wall that ran before the join comes first in Prepare the session" do
      steps = [
        step(1, "fetch", "Fetch", 56, 2),
        step(2, "wall", "Wall", 58, 1),
        step(3, "join", "Join session 1", 60, 9)
      ]

      html = list(preparation(%{steps: steps}))

      assert child_names(html, "prepare-machine-session-prepare") == [
               "Start the wall",
               "Start the agent"
             ]

      assert children(html, "prepare-machine-session-prepare") == [
               "prepare-machine-step-2",
               "prepare-machine-step-3"
             ]
    end
  end

  describe "the heading" do
    test "has the pool and the run's state" do
      for {state, word} <- [
            {"completed", "Completed"},
            {"failed", "Failed"},
            {"cancelled", "Cancelled"},
            {"lost", "Lost"}
          ] do
        html = list(preparation(), run_state: state)
        assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run on build-pool · " <> word
      end

      live = preparation(%{session_end: nil, after_session: [], outputs: []})
      html = list(live, alive: true, run_state: "running")
      assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run on build-pool · Running"
    end

    test "has the word of the run's badge for every state, Pending for a pending run" do
      live = preparation(%{session_end: nil, after_session: [], outputs: []})

      for state <- Apiary.Runs.Run.states() do
        html = list(live, alive: state in Apiary.Runs.Run.alive_states(), run_state: state)

        assert text(LazyHTML.query(html, "#prepare-machine-h")) ==
                 "Run on build-pool · " <> ApiaryWeb.RunComponents.state_label(state)
      end

      html = list(live, alive: true, run_state: "pending")
      assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run on build-pool · Pending"
    end

    test "is Run for a run no pool claimed" do
      html = list(preparation(%{machine: nil}), run_state: "completed")
      assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run · Completed"

      html = list(preparation(%{machine: nil}))
      assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run"
    end

    test "has the time from the start of Queue the run to the end of Remove the machine" do
      html = list(preparation(), clean_up: {:report, :gone, at(430)})
      assert text(LazyHTML.query(html, "#prepare-machine-total")) == "7 m 10 s"
    end

    test "with no removal report, ends at the latest end of a row" do
      html = list(preparation(), clean_up: {:waiting, at(1300)})
      # The run's end at 400 s.
      assert text(LazyHTML.query(html, "#prepare-machine-total")) == "6 m 40 s"
    end

    test "counts up from the start of Queue the run on a running run, with so far" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)
      total = LazyHTML.query(html, "#prepare-machine-total[data-tick=duration]")
      assert LazyHTML.attribute(total, "data-since") == iso(0)
      assert html |> LazyHTML.query(".q-prep-hd") |> text() =~ "so far"
    end
  end

  test "Queue the run spans from the queue to the claim, with Queued, and is closed" do
    html = list(preparation())
    assert started(html, "prepare-machine-queue") == iso(0)
    assert took(html, "prepare-machine-queue") == "12 s"
    assert count(html, "details#prepare-machine-queue:not([open])") == 1
    assert facts(html, "prepare-machine-queue") == [{"Queued", clock(0)}]
  end

  test "a run with no time in the queue has no Queue the run row" do
    html = list(preparation(%{machine: machine(%{queued_at: nil})}))
    refute "prepare-machine-queue" in rows(html)
  end

  test "Request a machine spans from the claim to `dispatched`, with the pool and its type" do
    html = list(preparation())
    assert started(html, "prepare-machine-request") == iso(12)
    assert took(html, "prepare-machine-request") == "2 s"

    assert facts(html, "prepare-machine-request") == [
             {"Machine requested", clock(12)},
             {"Pool", "build-pool"},
             {"Machine type", "pool default"}
           ]
  end

  test "Request a machine has the machine type of the claim answer, its name, key and spec" do
    spec = %{
      "vcpus" => 4,
      "memory_mib" => 16_384,
      "disk_gib" => 60,
      "arch" => "amd64",
      "virtualization" => false
    }

    html =
      list(
        preparation(%{
          machine: machine(%{machine_type: %{key: "large", name: "Large", spec: spec}})
        })
      )

    assert facts(html, "prepare-machine-request") == [
             {"Machine requested", clock(12)},
             {"Pool", "build-pool"},
             {"Machine type", "Large large (4 vCPUs, 16 GiB, 60 GiB disk)"}
           ]

    one = %{spec | "vcpus" => 1, "memory_mib" => 1536, "virtualization" => true}

    html =
      list(preparation(%{machine: machine(%{machine_type: %{key: "kvm", name: nil, spec: one}})}))

    assert facts(html, "prepare-machine-request") == [
             {"Machine requested", clock(12)},
             {"Pool", "build-pool"},
             {"Machine type", "kvm (1 vCPU, 1.5 GiB, 60 GiB disk, virtualization)"}
           ]
  end

  describe "an Agent session" do
    test "spans from its first step's start to the end of Save the outputs" do
      html = list(preparation())
      # From the join at 60 s to the end of the push at 385 s.
      assert started(html, "prepare-machine-session") == iso(60)
      assert took(html, "prepare-machine-session") == "5 m 25 s"

      assert children(html, "prepare-machine-session") == [
               "prepare-machine-session-prepare",
               "prepare-machine-session-agent",
               "prepare-machine-session-outputs"
             ]
    end

    test "Run the agent has Started, Finished, Result and Model, then the Timeline" do
      html = list(preparation())

      assert facts(html, "prepare-machine-session-agent") == [
               {"Started", clock(70)},
               {"Finished", clock(380)},
               {"Result", "exit 0 · success · 14 turns · 3 m 49 s · $0.84"},
               {"Model", "model-large-1"}
             ]

      assert count(html, "#prepare-machine-session-agent > .q-xb > #timeline-in-session-70") ==
               1
    end

    test "is closed on a run that ended, and open with a link to an event inside it" do
      closed = list(preparation())
      assert count(closed, "#prepare-machine-session[open]") == 0
      assert count(closed, "#prepare-machine-session-agent[open]") == 0

      open = list(preparation(), session_open: 70)
      assert count(open, "#prepare-machine-session[open]") == 1
      assert count(open, "#prepare-machine-session-agent[open]") == 1
    end

    test "is open on a running run, and its time counts up from its first step's start" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)
      assert count(html, "#prepare-machine-session[open][data-state=running]") == 1
      assert count(html, "#prepare-machine-session-agent[open][data-state=running]") == 1

      clock = LazyHTML.query(html, "#prepare-machine-session-clock[data-tick=duration]")
      assert LazyHTML.attribute(clock, "data-since") == iso(60)
      assert text(LazyHTML.query(html, "#prepare-machine-session > summary")) =~ "Running"
    end

    test "a running run shows only the rows that have happened" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)

      assert rows(html) == [
               "prepare-machine-queue",
               "prepare-machine-request",
               "prepare-machine-start",
               "prepare-machine-prepare",
               "prepare-machine-session"
             ]

      assert children(html, "prepare-machine-session") == [
               "prepare-machine-session-prepare",
               "prepare-machine-session-agent"
             ]
    end

    test "a session that ended with no exit is cancelled; Agent session 1 spans its steps" do
      html = list(preparation(%{session_end: session_end(%{exited_at: nil, exit_code: nil})}))
      assert count(html, "#prepare-machine-session-agent[data-state=cancelled]") == 1
      assert count(html, "#prepare-machine-session[data-state=cancelled]") == 1
      # From the join at 60 s to the end of the push at 385 s.
      assert took(html, "prepare-machine-session") == "5 m 25 s"
    end

    test "a session with an exit and no result is Finished at the exit, with no model" do
      html =
        list(
          preparation(%{
            session_end:
              session_end(%{
                result_at: nil,
                outcome: nil,
                turns: nil,
                duration_ms: nil,
                cost_usd: nil,
                model: nil,
                exit_code: 137,
                state: "failed"
              })
          })
        )

      assert facts(html, "prepare-machine-session-agent") == [
               {"Started", clock(70)},
               {"Finished", clock(382)},
               {"Result", "exit 137"}
             ]

      assert count(html, "#prepare-machine-session-agent[data-state=failed]") == 1
    end

    test "an exit code of -1 is no exit status, and has no words" do
      html = list(preparation(%{session_end: session_end(%{exit_code: -1})}))

      assert {"Result", "success · 14 turns · 3 m 49 s · $0.84"} in facts(
               html,
               "prepare-machine-session-agent"
             )
    end
  end

  describe "Save the outputs" do
    test "has the versions the session saved, and its push steps" do
      html = list(preparation())

      assert facts(html, "prepare-machine-session-outputs") == [
               {"Outputs saved", clock(384)},
               {"proposal", "Version 3"}
             ]

      assert count(html, "#prepare-machine-session-outputs #prepare-machine-step-3") == 1
    end

    test "the end of the last push is the end of its Agent session" do
      pushes = [
        step(3, "push", "Push proposal", 383, 1),
        step(4, "push", "Push questions", 386, 2)
      ]

      html = list(preparation(%{after_session: pushes}))
      # From the join at 60 s to the end of the second push at 388 s.
      assert took(html, "prepare-machine-session") == "5 m 28 s"
    end

    test "while a push runs, it is running and open, and its Agent session's time counts" do
      pushes = [
        step(3, "push", "Push proposal", 383, 1),
        step(4, "push", "Push questions", 386, 2, %{
          state: "running",
          exited_at: nil,
          duration_ms: nil
        })
      ]

      html = list(preparation(%{after_session: pushes}), alive: true)

      assert count(html, "#prepare-machine-session-outputs[open][data-state=running]") == 1
      assert count(html, "#prepare-machine-session[data-state=running]") == 1
      clock = LazyHTML.query(html, "#prepare-machine-session-clock[data-tick=duration]")
      assert LazyHTML.attribute(clock, "data-since") == iso(60)
    end

    test "with versions and no push step, ends its Agent session at the last version" do
      versions = [
        %{type: "proposal", number: 3, at: at(384)},
        %{type: "questions", number: 1, at: at(390)}
      ]

      html = list(preparation(%{after_session: [], outputs: versions}))

      assert facts(html, "prepare-machine-session-outputs") == [
               {"Outputs saved", clock(384)},
               {"proposal", "Version 3"},
               {"questions", "Version 1"}
             ]

      # From the join at 60 s to the last version at 390 s.
      assert took(html, "prepare-machine-session") == "5 m 30 s"

      html = list(preparation(%{after_session: [], outputs: [hd(versions)]}))
      assert took(html, "prepare-machine-session") == "5 m 24 s"
    end

    test "a failed push opens the row, which is failed" do
      failed = step(3, "push", "Push proposal", 383, 2, %{state: "failed", exit_code: 1})
      html = list(preparation(%{after_session: [failed], outputs: []}))

      assert count(html, "#prepare-machine-session-outputs-failed[open][data-state=failed]") == 1

      assert count(html, "#prepare-machine-session-outputs-failed #prepare-machine-step-3-failed") ==
               1
    end

    test "a push during the session is in that session's Save the outputs" do
      html =
        list(
          preparation(%{
            after_session: [step(3, "push", "Push proposal", 300, 2)],
            outputs: [%{type: "proposal", number: 3, at: at(301)}]
          })
        )

      assert children(html, "prepare-machine-session") == [
               "prepare-machine-session-prepare",
               "prepare-machine-session-agent",
               "prepare-machine-session-outputs"
             ]

      assert count(html, "#prepare-machine-session-outputs #prepare-machine-step-3") == 1
    end

    test "is not there when the run pushed nothing" do
      html = list(preparation(%{after_session: [], outputs: []}))
      refute "prepare-machine-session-outputs" in children(html, "prepare-machine-session")
    end
  end

  describe "two agent sessions" do
    # The first session from 70 s to 200 s, the second's join from 201 s to 202 s, the
    # second session from 203 s to 382 s.
    defp two_sessions(changes \\ %{}) do
      first = session_end(%{result_at: at(198), exited_at: at(200), model: "model-small-1"})

      preparation(
        Map.merge(
          %{
            steps: [
              step(1, "fetch", "Fetch", 56, 4),
              step(2, "join", "Join session 1", 60, 10),
              step(4, "join", "Join session 2", 201, 1)
            ],
            sessions: [
              %{session: 1, sequence: 70, started_at: at(70), end: first},
              %{session: 2, sequence: 203, started_at: at(203), end: session_end()}
            ]
          },
          changes
        )
      )
    end

    test "each is an Agent session with its steps, in time order" do
      html = list(two_sessions(), clean_up: {:report, :gone, at(430)})

      assert rows(html) == [
               "prepare-machine-queue",
               "prepare-machine-request",
               "prepare-machine-start",
               "prepare-machine-prepare",
               "prepare-machine-session",
               "prepare-machine-session-2",
               "prepare-machine-remove"
             ]

      # From the first join at 60 s to the first session's exit at 200 s.
      assert took(html, "prepare-machine-session") == "2 m 20 s"
      # From the second join at 201 s to the end of the push at 385 s.
      assert started(html, "prepare-machine-session-2") == iso(201)
      assert took(html, "prepare-machine-session-2") == "3 m 04 s"

      assert {"Model", "model-small-1"} in facts(html, "prepare-machine-session-agent")
      assert {"Model", "model-large-1"} in facts(html, "prepare-machine-session-2-agent")
    end

    test "a wall that fails after the next join, before its session starts, is that session's" do
      # Session 1 from 70 s to 200 s; join 2 from 201 s to 202 s; wall 2 fails at 203 s,
      # and session 2 never starts.
      html =
        list(
          two_sessions(%{
            steps: [
              step(1, "fetch", "Fetch", 56, 4),
              step(2, "join", "Join session 1", 60, 10),
              step(4, "join", "Join session 2", 201, 1),
              step(5, "wall", "Wall", 203, 1, %{state: "failed", exit_code: 125})
            ],
            sessions: [
              %{
                session: 1,
                sequence: 70,
                started_at: at(70),
                end: session_end(%{result_at: at(198), exited_at: at(200)})
              }
            ],
            after_session: [],
            outputs: [],
            stopped: %{
              cause: :step_failed,
              step: 5,
              fixer: :workspace_admin,
              text: "",
              what: "Start the wall failed with exit code 125.",
              fix: "",
              detail: nil
            }
          }),
          run_state: "failed"
        )

      assert children(html, "prepare-machine-session-prepare") == ["prepare-machine-step-2"]

      assert children(html, "prepare-machine-session-2-prepare") == [
               "prepare-machine-step-4",
               "prepare-machine-step-5"
             ]

      assert count(
               html,
               "#prepare-machine-session-2-prepare #prepare-machine-step-5[data-state=failed]"
             ) ==
               1

      refute "prepare-machine-session-2-wall" in skipped(html)
      assert "prepare-machine-session-2-agent" in skipped(html)
    end

    test "a step that runs after a session's start goes into the next Agent session" do
      # A setup step at 150 s, while session 1 runs, before session 2 starts at 203 s.
      setup = step(3, "setup", "setup npm ci", 150, 2)
      html = list(two_sessions(%{steps: two_sessions().steps ++ [setup]}))

      assert children(html, "prepare-machine-session-prepare") == ["prepare-machine-step-2"]

      assert children(html, "prepare-machine-session-2-prepare") == [
               "prepare-machine-step-3",
               "prepare-machine-step-4"
             ]
    end

    test "a step after the last session's start, with no later session, goes into one that has not started" do
      # A setup step at 300 s, while session 2 runs; no session starts after it.
      setup = step(5, "setup", "setup npm ci", 300, 2)
      html = list(two_sessions(%{steps: two_sessions().steps ++ [setup]}))

      assert children(html, "prepare-machine-session-2-prepare") == ["prepare-machine-step-4"]
      assert "prepare-machine-session-3" in rows(html)
      assert children(html, "prepare-machine-session-3-prepare") == ["prepare-machine-step-5"]
    end

    test "each Run the agent opens to its session's Timeline, and opens for a link into it" do
      html = list(two_sessions())

      assert count(html, "#prepare-machine-session-agent > .q-xb > #timeline-in-session-70") ==
               1

      assert count(html, "#prepare-machine-session-2-agent > .q-xb > #timeline-in-session-203") ==
               1

      open = list(two_sessions(), session_open: 203)
      assert count(open, "#prepare-machine-session-2[open]") == 1
      assert count(open, "#prepare-machine-session-2-agent[open]") == 1
      assert count(open, "#prepare-machine-session[open]") == 0
    end

    test "a later session that runs is running, with its clock; the first has ended" do
      running = %{session: 2, sequence: 203, started_at: at(203), end: nil}
      [first, _second] = two_sessions().sessions

      html =
        list(two_sessions(%{sessions: [first, running], after_session: [], outputs: []}),
          alive: true
        )

      assert count(html, "#prepare-machine-session[data-state=succeeded]") == 1
      assert count(html, "#prepare-machine-session-2[open][data-state=running]") == 1

      clock = LazyHTML.query(html, "#prepare-machine-session-2-clock[data-tick=duration]")
      assert LazyHTML.attribute(clock, "data-since") == iso(201)

      refute "Finished" in Enum.map(facts(html, "prepare-machine-session-2-agent"), &elem(&1, 0))
    end

    test "a join goes to the session after it, a wall and a version to the session before" do
      steps = [
        step(1, "fetch", "Fetch", 56, 4),
        step(2, "join", "Join session 1", 60, 5),
        step(3, "wall", "Wall", 150, 1),
        step(4, "join", "Join session 2", 201, 1)
      ]

      versions = [
        %{type: "questions", number: 1, at: at(190)},
        %{type: "proposal", number: 3, at: at(384)}
      ]

      html = list(two_sessions(%{steps: steps, after_session: [], outputs: versions}))

      assert top_names(html) == [
               "Queue the run",
               "Request a machine",
               "Start the machine",
               "Prepare the machine",
               "Agent session 1",
               "Agent session 2"
             ]

      for key <- ["session", "session-2"] do
        assert child_names(html, "prepare-machine-#{key}") == [
                 "Prepare the session",
                 "Run the agent",
                 "Save the outputs"
               ]
      end

      assert children(html, "prepare-machine-session-prepare") == [
               "prepare-machine-step-2",
               "prepare-machine-step-3"
             ]

      assert children(html, "prepare-machine-session-2-prepare") == ["prepare-machine-step-4"]

      assert facts(html, "prepare-machine-session-outputs") == [
               {"Outputs saved", clock(190)},
               {"questions", "Version 1"}
             ]

      assert facts(html, "prepare-machine-session-2-outputs") == [
               {"Outputs saved", clock(384)},
               {"proposal", "Version 3"}
             ]

      assert count(html, "#prepare-machine-session-agent > .q-xb > #timeline-in-session-70") ==
               1

      assert count(html, "#prepare-machine-session-2-agent > .q-xb > #timeline-in-session-203") ==
               1
    end

    test "a session that saved nothing has no Save the outputs; one with a version has" do
      versions = [%{type: "proposal", number: 3, at: at(384)}]
      html = list(two_sessions(%{after_session: [], outputs: versions}))

      assert children(html, "prepare-machine-session") == [
               "prepare-machine-session-prepare",
               "prepare-machine-session-agent"
             ]

      assert children(html, "prepare-machine-session-2") == [
               "prepare-machine-session-2-prepare",
               "prepare-machine-session-2-agent",
               "prepare-machine-session-2-outputs"
             ]
    end
  end

  describe "Skipped" do
    # A run whose wall failed with exit code 125, in the contract's order: the join, the
    # session's start at 62 s, then the wall at 63 s. The session never ran its agent, so
    # the preparation has no agent session (`Apiary.Runs.Preparation`).
    defp failed_wall(changes \\ %{}) do
      preparation(
        Map.merge(
          %{
            steps: [
              step(1, "fetch", "Fetch", 56, 4),
              step(2, "join", "Join session 1", 60, 2),
              step(3, "wall", "Wall", 63, 1, %{state: "failed", exit_code: 125})
            ],
            after_session: [],
            outputs: [],
            session_started_at: nil,
            session_end: nil,
            sessions: [],
            stopped: %{
              cause: :step_failed,
              step: 3,
              fixer: :workspace_admin,
              text: "",
              what: "Start the wall failed with exit code 125.",
              fix: "An admin of Northwind reads the cause in the step's output.",
              detail: nil
            }
          },
          changes
        )
      )
    end

    # A run whose join failed with exit code 1 before its session started.
    defp failed_join(changes \\ %{}) do
      failed_wall(
        Map.merge(
          %{
            steps: [
              step(1, "fetch", "Fetch", 56, 4),
              step(2, "join", "Join session 1", 60, 2, %{state: "failed", exit_code: 1})
            ],
            session_started_at: nil,
            sessions: [],
            stopped: %{
              cause: :step_failed,
              step: 2,
              fixer: :workspace_admin,
              text: "",
              what: "Start the agent failed with exit code 1.",
              fix: "",
              detail: nil
            }
          },
          changes
        )
      )
    end

    # A run whose pool did not start a machine within 10 minutes.
    defp failed_start do
      preparation(%{
        machine:
          machine(%{
            started: %{state: "failed", started_at: at(14), ended_at: at(614), duration_ms: nil}
          }),
        steps: [],
        after_session: [],
        outputs: [],
        session_started_at: nil,
        session_end: nil,
        sessions: [],
        stopped: %{
          cause: :lease_lapsed,
          step: nil,
          fixer: :support,
          text: "",
          what: "Qory Pool did not start a machine within 10 minutes.",
          fix: "Contact support with run run_0123456789abcdef.",
          detail: nil
        }
      })
    end

    test "after a failed Start the agent, the wall, Run the agent and Save the outputs are Skipped" do
      html = list(failed_join(), clean_up: {:report, :gone, at(430)})

      assert skipped(html) == [
               "prepare-machine-session-wall",
               "prepare-machine-session-agent",
               "prepare-machine-session-outputs"
             ]

      assert text(LazyHTML.query(html, "#prepare-machine-session-agent")) ==
               "Run the agent Skipped"

      assert text(LazyHTML.query(html, "#prepare-machine-session-outputs")) ==
               "Save the outputs Skipped"

      assert count(html, "#prepare-machine-session-prepare[data-state=failed]") == 1
    end

    test "after a failed step of Prepare the machine, Agent session 1 and Remove the machine are Skipped" do
      html =
        list(
          failed_join(%{
            steps: [step(1, "fetch", "Fetch", 56, 4, %{state: "failed", exit_code: 128})],
            stopped: %{
              cause: :step_failed,
              step: 1,
              fixer: :workspace_admin,
              text: "",
              what: "Clone the repository failed with exit code 128.",
              fix: "",
              detail: nil
            }
          }),
          run_state: "failed"
        )

      assert count(html, "#prepare-machine-prepare[data-state=failed]") == 1
      assert skipped(html) == ["prepare-machine-session", "prepare-machine-remove"]
    end

    test "after a failed Run the agent, Save the outputs is Skipped" do
      failed = session_end(%{state: "failed", exit_code: 1, outcome: "error"})
      html = list(preparation(%{session_end: failed, after_session: [], outputs: []}))

      assert count(html, "#prepare-machine-session-agent[data-state=failed]") == 1
      assert skipped(html) == ["prepare-machine-session-outputs", "prepare-machine-remove"]
    end

    test "after a failed push on a run with no removal report, Remove the machine is Skipped" do
      push = step(3, "push", "Push proposal", 383, 2, %{state: "failed", exit_code: 1})
      html = list(preparation(%{after_session: [push]}), run_state: "failed")

      assert count(html, "#prepare-machine-session-outputs-failed[data-state=failed]") == 1
      assert skipped(html) == ["prepare-machine-remove"]
    end

    test "a session that ran after a failed session clears the failure for the steps after it" do
      first =
        session_end(%{result_at: at(198), exited_at: at(200), state: "failed", exit_code: 1})

      html =
        list(
          two_sessions(%{
            sessions: [
              %{session: 1, sequence: 70, started_at: at(70), end: first},
              %{session: 2, sequence: 203, started_at: at(203), end: session_end()}
            ],
            after_session: [],
            outputs: []
          }),
          run_state: "completed"
        )

      assert count(html, "#prepare-machine-session-agent[data-state=failed]") == 1
      assert count(html, "#prepare-machine-session-2-agent[data-state=succeeded]") == 1
      # Session 1 saved nothing after its failure: its Save the outputs is Skipped.
      assert skipped(html) == ["prepare-machine-session-outputs"]
      refute "prepare-machine-session-2-outputs" in children(html, "prepare-machine-session-2")
      refute "prepare-machine-remove" in rows(html)
    end

    test "after a failed Start the machine, the steps after it are Skipped" do
      html = list(failed_start())

      assert count(html, "#prepare-machine-start[data-state=failed]") == 1

      assert skipped(html) == [
               "prepare-machine-prepare",
               "prepare-machine-session",
               "prepare-machine-remove"
             ]

      assert Enum.map(skipped(html), &text(LazyHTML.query(html, "##{&1}"))) == [
               "Prepare the machine Skipped",
               "Agent session 1 Skipped",
               "Remove the machine Skipped"
             ]
    end

    test "a run that ended with no failure has no Skipped row" do
      html = list(preparation(%{after_session: [], outputs: []}))

      assert skipped(html) == []
      refute "prepare-machine-session-outputs" in children(html, "prepare-machine-session")
      refute "prepare-machine-remove" in rows(html)
    end

    test "a live run with a failed step has no Skipped row" do
      html = list(failed_join(), alive: true)

      assert skipped(html) == []

      assert rows(html) == [
               "prepare-machine-queue",
               "prepare-machine-request",
               "prepare-machine-start",
               "prepare-machine-prepare",
               "prepare-machine-session"
             ]

      assert children(html, "prepare-machine-session") == ["prepare-machine-session-prepare"]
    end

    test "Remove the machine is green after a failed step once the machine is gone" do
      html = list(failed_wall(), clean_up: {:report, :gone, at(430)})

      assert count(html, "#prepare-machine-remove[data-state=succeeded][data-clean-up=gone]") ==
               1

      assert count(html, "#prepare-machine-remove > summary .q-prep-ok") == 1

      assert text(LazyHTML.query(html, "#prepare-machine-remove > summary .sr-only")) ==
               "Succeeded"

      refute "prepare-machine-remove" in skipped(html)
    end

    test "a failed Start the agent skips Start the wall only for a run with a wall" do
      walled = list(failed_join(), run_state: "failed")
      assert "prepare-machine-session-wall" in skipped(walled)

      html = list(failed_join(), run_state: "failed", wall: false)
      refute "prepare-machine-session-wall" in skipped(html)
      refute text(LazyHTML.query(html, "#prepare-machine-session")) =~ "Start the wall"
      assert "prepare-machine-session-agent" in skipped(html)
    end
  end

  describe "the cause line" do
    test "of a failed step states what happened, with no advice" do
      html = list(failed_wall())

      assert text(LazyHTML.query(html, "#prepare-machine-step-3 #prepare-machine-cause")) ==
               "Start the wall failed with exit code 125."

      refute text(html) =~ "reads the cause"
      refute text(html) =~ "Contact support"
    end

    test "of a machine's cause is its first sentence alone" do
      html = list(failed_start())

      assert text(LazyHTML.query(html, "#prepare-machine-start #prepare-machine-cause")) ==
               "Qory Pool did not start a machine within 10 minutes."

      refute text(html) =~ "Contact support"
    end
  end

  describe "helper steps" do
    defp with_helpers do
      helpers = [
        step(5, "join", "Join session 2", 386, 1, %{helper: true}),
        step(6, "wall", "Start the wall", 387, 1, %{helper: true})
      ]

      copy = step(4, "copy", "Bring the work back", 386, 14, %{helper: true, state: "failed"})

      preparation(%{
        machine: machine(%{ended_at: at(390)}),
        steps: preparation().steps ++ helpers,
        after_session: preparation().after_session ++ [copy]
      })
    end

    test "a copy, and the join and the wall of a bare session, have no row or time" do
      html = list(with_helpers(), clean_up: {:waiting, at(1300)})

      assert count(
               html,
               "#prepare-machine-step-4, #prepare-machine-step-5, #prepare-machine-step-6"
             ) ==
               0

      refute text(html) =~ "Bring the work back"
      assert count(html, "#prepare-machine-session-outputs[data-state=succeeded]") == 1

      # From the queue at 0 s to the machine's end at 390 s: the copy's end at 400 s is
      # no row's.
      assert text(LazyHTML.query(html, "#prepare-machine-total")) == "6 m 30 s"
    end

    test "the join and the wall of a bare session make no Agent session" do
      html = list(with_helpers(), clean_up: {:waiting, at(1300)})

      refute "prepare-machine-session-2" in rows(html)
      assert Enum.filter(top_names(html), &(&1 =~ "Agent session")) == ["Agent session 1"]
    end
  end

  describe "a run on the Qory Pool or on another organisation's pool" do
    test "has every row of the pool, with Started as and the machine log" do
      for {place, name, operator} <- [
            {:instance, "Qory Pool", nil},
            {:operator, "Northwind pool", "Northwind"}
          ] do
        pool = %{id: "np_0123456789abcdef", name: name, place: place, operator: operator}
        image = step(3, "image", "registry.example.com/web:1", 61, 2)

        html =
          list(
            preparation(%{
              machine: machine(%{pool: pool, started_as: "standard-4"}),
              steps: [
                step(1, "fetch", "Fetch", 56, 4),
                image,
                step(2, "join", "Join session 1", 64, 6)
              ]
            }),
            clean_up: {:report, :gone, at(430)},
            machine_log: {:ok, "Docker started\n", false},
            run_state: "completed"
          )

        assert rows(html) == [
                 "prepare-machine-queue",
                 "prepare-machine-request",
                 "prepare-machine-start",
                 "prepare-machine-prepare",
                 "prepare-machine-session",
                 "prepare-machine-remove"
               ]

        assert text(LazyHTML.query(html, "#prepare-machine-h")) == "Run on #{name} · Completed"

        assert children(html, "prepare-machine-prepare") == [
                 "prepare-machine-step-1",
                 "prepare-machine-step-3"
               ]

        assert text(LazyHTML.query(html, "#prepare-machine-start #prepare-machine-started-as")) ==
                 "Started as (instance admins) standard-4"

        assert html
               |> LazyHTML.query("#prepare-machine-start #prepare-machine-machine-log-lines")
               |> LazyHTML.query(".q-log-x")
               |> Enum.map(&text/1) == ["Docker started"]

        # From the queue at 0 s to the removal report at 430 s.
        assert text(LazyHTML.query(html, "#prepare-machine-total")) == "7 m 10 s"
      end
    end

    test "with no step, has the machine's rows" do
      pool = %{id: "np_0123456789abcdef", name: "Qory Pool", place: :instance, operator: nil}

      html =
        list(
          preparation(%{
            machine: machine(%{pool: pool}),
            steps: [],
            after_session: [],
            outputs: [],
            session_started_at: nil,
            session_end: nil
          }),
          clean_up: {:report, :gone, at(430)}
        )

      assert rows(html) == [
               "prepare-machine-queue",
               "prepare-machine-request",
               "prepare-machine-start",
               "prepare-machine-remove"
             ]
    end
  end

  test "rows inside a step show no start or duration; the top-level rows do" do
    html = list(preparation())

    for id <- ~w(queue request start prepare session) do
      assert started(html, "prepare-machine-#{id}") != [], id
      assert took(html, "prepare-machine-#{id}") != "", id
    end

    for id <- ~w(step-1 step-2 session-prepare session-agent session-outputs step-3) do
      summary = LazyHTML.query(html, "#prepare-machine-#{id} > summary")
      assert Enum.count(summary) == 1, id
      assert count(summary, ".q-tc1 time") == 0, id
      assert text(LazyHTML.query(summary, ".q-tc2")) == "", id
    end

    live = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)
    assert count(live, "#prepare-machine-session-clock") == 1
    assert count(live, "#prepare-machine-session-agent-clock") == 0
  end

  test "a run with no session's start, whose session ended, has Run the agent from its end" do
    html = list(preparation(%{session_started_at: nil, sessions: []}))

    assert rows(html) == [
             "prepare-machine-queue",
             "prepare-machine-request",
             "prepare-machine-start",
             "prepare-machine-prepare",
             "prepare-machine-session"
           ]

    assert facts(html, "prepare-machine-session-agent") == [
             {"Finished", clock(380)},
             {"Result", "exit 0 · success · 14 turns · 3 m 49 s · $0.84"},
             {"Model", "model-large-1"}
           ]
  end

  describe "a run on a permanent machine" do
    test "keeps its list, whose last row is Machine stays registered, with no time" do
      html = list(preparation(%{machine: nil}), clean_up: :stays)

      assert List.last(rows(html)) == "prepare-machine-remove"
      row = LazyHTML.query(html, "#prepare-machine-remove")
      assert text(LazyHTML.query(row, ".q-prep-name")) == "Machine stays registered"
      refute text(row) =~ "Machine removed"
      assert row |> LazyHTML.query("time") |> Enum.count() == 0
      assert LazyHTML.attribute(row, "data-clean-up") == ["stays"]
    end
  end

  describe "a queued run" do
    # A queued run's preparation (`Apiary.Runs.Preparation`): no machine and no steps,
    # the time it was queued and why it waits.
    defp queued(reason) do
      %{
        machine: nil,
        steps: [],
        after_session: [],
        sessions: [],
        log_pruned_at: nil,
        session_started_at: nil,
        session_end: nil,
        outputs: [],
        stopped: nil,
        queued: %{queued_at: @queued, machine_type: nil, reason: reason}
      }
    end

    defp why(reason),
      do:
        reason
        |> queued()
        |> list(alive: true, run_state: "queued")
        |> LazyHTML.query("#prepare-machine-why")
        |> text()

    test "has Queue the run, running since it was queued, then the steps to come with no time" do
      html = list(queued({:pool, "build-pool"}), alive: true, run_state: "queued")

      assert html |> LazyHTML.query("#prepare-machine-h") |> text() == "Run · Queued"

      # Under Queue the run, the line of why it waits is no row.
      assert names(html, "#prepare-machine > ol > li > [id]:not(.q-prep-why)") == [
               "Queue the run",
               "Request a machine",
               "Start the machine",
               "Prepare the machine",
               "Agent session 1",
               "Remove the machine"
             ]

      assert html |> LazyHTML.query("#prepare-machine-queue[data-state=running]") |> Enum.count() ==
               1

      assert started(html, "prepare-machine-queue") == iso(0)

      for key <- ~w(request start prepare session remove) do
        row = LazyHTML.query(html, "#prepare-machine-#{key}[data-state=not_run]")
        assert Enum.count(row) == 1
        assert row |> LazyHTML.query("time") |> Enum.count() == 0
        assert text(LazyHTML.query(row, ".q-tc2")) == ""
      end

      assert why({:pool, "build-pool"}) == "Waiting for build-pool to run it."
    end

    test "shows why it waits, for each reason" do
      for {reason, words} <- [
            {:harness, "Waiting until Qory Apiary reads the harness."},
            {:no_pool, "Waiting: no pool can take the run"},
            {{:no_fit, "large", "build-pool"}, "Waiting: no pool can start machine type large"},
            {{:image, "acme/shop", :queued},
             "Waiting for the environment image: a build of acme/shop is queued."},
            {{:image, "acme/shop", :running},
             "Waiting for the environment image: a build of acme/shop is running."},
            {{:image, "acme/shop", nil}, "Waiting for the environment image of acme/shop."},
            {{:busy, "build-pool", 3, 3},
             "Waiting for a machine: build-pool runs 3 of its 3 machines."},
            {{:busy, "build-pool", 1, 1},
             "Waiting for a machine: build-pool runs 1 of its 1 machine."},
            {{:busy, :instance}, "Waiting for a machine: Qory Pool runs all of its machines."},
            {{:behind, 2}, "Waiting for a machine: 2 runs were queued before this one."},
            {{:behind, 1}, "Waiting for a machine: 1 run was queued before this one."},
            {{:pool, "Qory Pool"}, "Waiting for Qory Pool to run it."}
          ],
          do: assert(why(reason) == words, inspect(reason))

      assert why({:pool, nil}) == ""
    end
  end

  describe "a waiting run's machine type" do
    test "a waiting run whose type no pool offer fits has the type, the cause and who fixes it" do
      large = %{
        key: "ui-tests-large",
        name: "UI tests, large",
        spec: %{
          "vcpus" => 8,
          "memory_mib" => 32_768,
          "disk_gib" => 100,
          "arch" => "amd64",
          "virtualization" => false
        }
      }

      html =
        {:no_fit, "ui-tests-large", "build-pool"}
        |> queued()
        |> put_in([:queued, :machine_type], large)
        |> put_in([:queued, :instance_admin], true)
        |> list(alive: true, run_state: "queued")

      assert text(LazyHTML.query(html, "#prepare-machine-why")) ==
               "Waiting for a machine: no pool offers a machine that fits UI tests, large (ui-tests-large: 8 vCPUs, 32 GiB, 100 GiB disk)."

      assert text(LazyHTML.query(html, "#prepare-machine-why-fix")) ==
               "An instance admin makes the type fit an offer in Instance settings › Machine types, or the admin of build-pool adds an offer that fits."

      assert text(LazyHTML.query(html, "#prepare-machine-queue")) =~
               "Machine type UI tests, large ui-tests-large"
    end

    test "a reader who is not an instance admin reads Contact support with the run, and the pool's admin for a pool that is not the instance's" do
      large = %{
        key: "ui-tests-large",
        name: "UI tests, large",
        spec: %{"vcpus" => 8, "memory_mib" => 32_768, "disk_gib" => 100, "arch" => "amd64"}
      }

      fix = fn pool ->
        {:no_fit, "ui-tests-large", pool}
        |> queued()
        |> put_in([:queued, :machine_type], large)
        |> put_in([:queued, :instance_admin], false)
        |> put_in([:queued, :run], "rn_0123456789abcdef")
        |> list(alive: true, run_state: "queued")
        |> LazyHTML.query("#prepare-machine-why-fix")
        |> text()
      end

      assert fix.("build-pool") ==
               "Contact support with run rn_0123456789abcdef, or ask the admin of build-pool to add an offer that fits."

      assert fix.(:instance) == "Contact support with run rn_0123456789abcdef."
    end
  end

  describe "the cause line of an image not saved" do
    @dest "registry.example.com/0123456789abcdef/0f1e2d3c4b5a6978/targets/1a2b3c4d5e6f7081"
    @env "registry.example.com/0123456789abcdef/0f1e2d3c4b5a6978/environments/1a2b3c4d5e6f7081"
    @sent @env <> "@sha256:" <> String.duplicate("3b9d", 16)
    @other @env <> "@sha256:" <> String.duplicate("7a1c", 16)

    # The line as its text reads, with no markup, and the values in code font.
    defp line(refused, fix) do
      cause = PreparationComponents.built_cause(%{refused: refused, fix: fix})
      codes = for {:code, value} <- List.flatten(List.wrap(cause)), do: value
      {ApiaryWeb.RichText.plain_text(cause), codes}
    end

    test "each cause states what happened, with the values that differ as code" do
      assert line({:image_place, @dest <> "-x", @dest}, nil) ==
               {"The image was not saved: the run reported it at #{@dest}-x, but this run " <>
                  "saves images only under #{@dest}.", [@dest <> "-x", @dest]}

      assert line({:environment_image, @env <> "-x", {:destination, @env}}, nil) ==
               {"The image was not saved: the run reported its environment image at " <>
                  "#{@env}-x, but this run saves environment images only under #{@env}.",
                [@env <> "-x", @env]}

      assert line({:environment_image, @other, {:image, @sent}}, nil) ==
               {"The image was not saved: the run reported that it started from #{@other}, " <>
                  "but this run starts from #{@sent}.", [@other, @sent]}

      assert line(:no_destination, nil) ==
               {"The image was not saved: this run has no registry address to check the " <>
                  "image against.", []}

      assert line(:not_prebuild, {:support, "rn_0123456789abcdef"}) ==
               {"The image was not saved: this run is not recorded as a prebuild handed over " <>
                  "to a machine. Contact support with run rn_0123456789abcdef.", []}
    end

    test "a member that breaks its form, with its rule" do
      rules = [
        {"image",
         "is not a registry address pinned by its digest, @sha256: and 64 lower-case " <>
           "hexadecimal digits, of at most 327 characters"},
        {"environment_image",
         "is not a registry address pinned by its digest, @sha256: and 64 lower-case " <>
           "hexadecimal digits, of at most 327 characters"},
        {"size", "is not a whole number of bytes from 1 to 9,007,199,254,740,991"},
        {"commit", "is not 40 or 64 lower-case hexadecimal characters"},
        {"environment_ref", "is not 1 to 200 characters"}
      ]

      for {member, rule} <- rules do
        {text, codes} = line({:form, member}, {:support, "rn_0123456789abcdef"})

        assert text ==
                 "The image was not saved: #{member} in the image report #{rule}. " <>
                   "Contact support with run rn_0123456789abcdef."

        assert hd(codes) == member
      end
    end

    test "a build whose image never arrived: where each reader reads why" do
      what = "The image was not saved: the build finished, but no image arrived."

      for {fix, step} <- [
            {:machine_log, "Read the machine log under Start the machine for the cause."},
            {{:pool_log, "build-pool"}, "Read the cause in the log of build-pool on its host."},
            {{:operator_log, "Northwind", "partner-pool"},
             "Ask an admin of Northwind for the cause in the log of partner-pool."},
            {{:support, "rn_0123456789abcdef"}, "Contact support with run rn_0123456789abcdef."}
          ] do
        assert line(:not_sent, fix) == {what <> " " <> step, []}
      end
    end

    test "a run with no destination: Rebuild, or ask an admin of the workspace" do
      what =
        "The image was not saved: this run has no registry address to check the image against."

      assert line(:no_destination, {:rebuild, "northwind/storefront"}) ==
               {what <> " Rebuild northwind/storefront to build the image again.", []}

      assert line(:no_destination, {:ask_rebuild, "Main", "northwind/storefront"}) ==
               {what <> " Ask an admin of Main to rebuild northwind/storefront.", []}
    end

    test "How it ended has the first sentence alone, in plain text" do
      built = %{refused: {:image_place, @dest <> "-x", @dest}, fix: nil, at: nil, image: nil}

      assert PreparationComponents.built_line(%{built: built}) ==
               "The image was not saved: the run reported it at #{@dest}-x, but this run " <>
                 "saves images only under #{@dest}."

      assert PreparationComponents.built_line(%{
               built: %{built | refused: :not_sent, fix: :machine_log}
             }) == "The image was not saved: the build finished, but no image arrived."

      assert PreparationComponents.built_line(%{built: %{built | refused: nil}}) == nil
      assert PreparationComponents.built_line(%{built: nil}) == nil
      assert PreparationComponents.built_line(nil) == nil
    end
  end
end
