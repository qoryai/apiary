defmodule ApiaryWeb.RunListTest do
  # The Run list (`ApiaryWeb.PreparationComponents.run_list/1`): the heading's total time,
  # Queued, Machine requested, Session started with the Timeline inside it, closed or open
  # by default, Session finished, Outputs saved, and the rows in time order. Machine
  # started and Prepare are in `ApiaryWeb.PreparationStepsTest`, Machine removed in
  # `ApiaryWeb.PreparationCleanUpTest`.
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ApiaryWeb.PreparationComponents

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
  # 55 s, its steps from 56 s to 70 s, its session from 70 s to 382 s, a push from 383 s
  # to 385 s, its end at 400 s.
  defp preparation(changes \\ %{}) do
    Map.merge(
      %{
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
      },
      changes
    )
  end

  defp list(preparation, opts \\ []) do
    assigns = %{
      preparation: preparation,
      alive: Keyword.get(opts, :alive, false),
      clean_up: Keyword.get(opts, :clean_up),
      session_open: Keyword.get(opts, :session_open, false)
    }

    ~H"""
    <PreparationComponents.run_list
      preparation={@preparation}
      alive={@alive}
      clean_up={@clean_up}
      session_open={@session_open}
    >
      <:session>
        <ol id="timeline-in-session"></ol>
      </:session>
    </PreparationComponents.run_list>
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp text(html), do: html |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp rows(html),
    do: html |> LazyHTML.query("#prepare-machine > ol > li > [id]") |> LazyHTML.attribute("id")

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

  defp iso(seconds), do: [DateTime.to_iso8601(at(seconds))]

  test "the rows of a run that ended, in time order" do
    html = list(preparation(), clean_up: {:report, :gone, at(430)})

    assert rows(html) == [
             "prepare-machine-queued",
             "prepare-machine-requested",
             "prepare-machine-started",
             "prepare-machine-prepare",
             "prepare-machine-session",
             "prepare-machine-session-finished",
             "prepare-machine-outputs",
             "prepare-machine-removed"
           ]

    assert html |> LazyHTML.query("#prepare-machine-h") |> text() == "Run"
  end

  describe "the heading" do
    test "has the time from the start of Queued to the end of Machine removed" do
      html = list(preparation(), clean_up: {:report, :gone, at(430)})
      assert text(LazyHTML.query(html, "#prepare-machine-total")) == "7 m 10 s"
    end

    test "with no removal report, ends at the latest end of a row" do
      html = list(preparation(), clean_up: {:waiting, at(1300)})
      # The run's end at 400 s.
      assert text(LazyHTML.query(html, "#prepare-machine-total")) == "6 m 40 s"
    end

    test "counts up from the start of Queued on a running run, with so far" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)
      total = LazyHTML.query(html, "#prepare-machine-total[data-tick=duration]")
      assert LazyHTML.attribute(total, "data-since") == iso(0)
      assert html |> LazyHTML.query(".q-prep-hd") |> text() =~ "so far"
    end
  end

  test "Queued spans from the queue to the claim, and does not open" do
    html = list(preparation())
    assert started(html, "prepare-machine-queued") == iso(0)
    assert took(html, "prepare-machine-queued") == "12 s"
    assert html |> LazyHTML.query("div#prepare-machine-queued") |> Enum.count() == 1
  end

  test "a run with no time in the queue has no Queued row" do
    html = list(preparation(%{machine: machine(%{queued_at: nil})}))
    refute "prepare-machine-queued" in rows(html)
  end

  test "Machine requested spans from the claim to `dispatched`, with the pool and its type" do
    html = list(preparation())
    assert started(html, "prepare-machine-requested") == iso(12)
    assert took(html, "prepare-machine-requested") == "2 s"

    assert facts(html, "prepare-machine-requested") == [
             {"Pool", "build-pool"},
             {"Machine type", "pool default"}
           ]
  end

  test "Machine requested has the machine type of the claim answer, with its spec" do
    spec = %{
      "vcpus" => 4,
      "memory_mib" => 16_384,
      "disk_gib" => 60,
      "arch" => "amd64",
      "virtualization" => false
    }

    html = list(preparation(%{machine: machine(%{machine_type: %{name: "large", spec: spec}})}))

    assert facts(html, "prepare-machine-requested") == [
             {"Pool", "build-pool"},
             {"Machine type", "large (4 vCPUs, 16 GiB, 60 GiB disk)"}
           ]

    one = %{spec | "vcpus" => 1, "memory_mib" => 1536, "virtualization" => true}
    html = list(preparation(%{machine: machine(%{machine_type: %{name: "kvm", spec: one}})}))

    assert facts(html, "prepare-machine-requested") == [
             {"Pool", "build-pool"},
             {"Machine type", "kvm (1 vCPU, 1.5 GiB, 60 GiB disk, virtualization)"}
           ]
  end

  describe "Session started" do
    test "spans from the session's start to its exit, with the Timeline inside it" do
      html = list(preparation())
      assert started(html, "prepare-machine-session") == iso(70)
      assert took(html, "prepare-machine-session") == "5 m 12 s"

      assert html
             |> LazyHTML.query("#prepare-machine-session > .q-xb > #timeline-in-session")
             |> Enum.count() == 1
    end

    test "is closed on a run that ended, and open with a link to an event inside it" do
      closed = list(preparation())
      assert closed |> LazyHTML.query("#prepare-machine-session[open]") |> Enum.count() == 0

      open = list(preparation(), session_open: true)
      assert open |> LazyHTML.query("#prepare-machine-session[open]") |> Enum.count() == 1
    end

    test "is open on a running run, and its time counts up from the session's start" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)
      assert html |> LazyHTML.query("#prepare-machine-session[open]") |> Enum.count() == 1

      clock = LazyHTML.query(html, "#prepare-machine-session-clock[data-tick=duration]")
      assert LazyHTML.attribute(clock, "data-since") == iso(70)
      assert text(LazyHTML.query(html, "#prepare-machine-session > summary")) =~ "Running"
    end

    test "a running run shows only the rows that have happened" do
      html = list(preparation(%{session_end: nil, after_session: [], outputs: []}), alive: true)

      assert rows(html) == [
               "prepare-machine-queued",
               "prepare-machine-requested",
               "prepare-machine-started",
               "prepare-machine-prepare",
               "prepare-machine-session"
             ]
    end

    test "a session that ended with no exit is cancelled, with no duration" do
      html = list(preparation(%{session_end: session_end(%{exited_at: nil, exit_code: nil})}))

      assert html
             |> LazyHTML.query("#prepare-machine-session[data-state=cancelled]")
             |> Enum.count() == 1

      assert took(html, "prepare-machine-session") == ""
    end
  end

  describe "Session finished" do
    test "spans from the result to the exit, with Result and Model" do
      html = list(preparation())
      assert started(html, "prepare-machine-session-finished") == iso(380)
      assert took(html, "prepare-machine-session-finished") == "2 s"

      assert facts(html, "prepare-machine-session-finished") == [
               {"Result", "exit 0 · success · 14 turns · 3 m 49 s · $0.84"},
               {"Model", "model-large-1"}
             ]
    end

    test "a session with an exit and no result starts at the exit and has no duration" do
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

      assert started(html, "prepare-machine-session-finished") == iso(382)
      assert took(html, "prepare-machine-session-finished") == ""
      assert facts(html, "prepare-machine-session-finished") == [{"Result", "exit 137"}]

      assert html
             |> LazyHTML.query("#prepare-machine-session-finished[data-state=failed]")
             |> Enum.count() == 1
    end

    test "an exit code of -1 is no exit status, and has no words" do
      html = list(preparation(%{session_end: session_end(%{exit_code: -1})}))

      assert {"Result", "success · 14 turns · 3 m 49 s · $0.84"} in facts(
               html,
               "prepare-machine-session-finished"
             )
    end
  end

  describe "Outputs saved" do
    test "has the versions the run pushed, and its push steps" do
      html = list(preparation())
      assert started(html, "prepare-machine-outputs") == iso(383)
      assert took(html, "prepare-machine-outputs") == "2 s"
      assert facts(html, "prepare-machine-outputs") == [{"proposal", "Version 3"}]

      assert html
             |> LazyHTML.query("#prepare-machine-outputs #prepare-machine-step-3")
             |> Enum.count() == 1
    end

    test "starts at the first push's start and ends at the end of the last push" do
      pushes = [
        step(3, "push", "Push proposal", 383, 1),
        step(4, "push", "Push questions", 386, 2)
      ]

      html = list(preparation(%{after_session: pushes}))
      assert started(html, "prepare-machine-outputs") == iso(383)
      # From 383 s to the end of the second push at 388 s.
      assert took(html, "prepare-machine-outputs") == "5 s"
    end

    test "while a push runs, counts up from the first push's start, with no duration" do
      pushes = [
        step(3, "push", "Push proposal", 383, 1),
        step(4, "push", "Push questions", 386, 2, %{
          state: "running",
          exited_at: nil,
          duration_ms: nil
        })
      ]

      html =
        list(preparation(%{after_session: pushes, session_end: nil}), alive: true)

      clock = LazyHTML.query(html, "#prepare-machine-outputs-clock[data-tick=duration]")
      assert LazyHTML.attribute(clock, "data-since") == iso(383)
    end

    test "with versions and no push step, spans from the first version to the last" do
      versions = [
        %{type: "proposal", number: 3, at: at(384)},
        %{type: "questions", number: 1, at: at(390)}
      ]

      html = list(preparation(%{after_session: [], outputs: versions}))
      assert started(html, "prepare-machine-outputs") == iso(384)
      assert took(html, "prepare-machine-outputs") == "6 s"

      # One version starts and ends at one moment, so the row shows no duration.
      html = list(preparation(%{after_session: [], outputs: [hd(versions)]}))
      assert started(html, "prepare-machine-outputs") == iso(384)
      assert took(html, "prepare-machine-outputs") == ""
    end

    test "a failed push opens the row, which is failed" do
      failed = step(3, "push", "Push proposal", 383, 2, %{state: "failed", exit_code: 1})
      html = list(preparation(%{after_session: [failed], outputs: []}))

      assert html
             |> LazyHTML.query("#prepare-machine-outputs-failed[open][data-state=failed]")
             |> Enum.count() == 1
    end

    test "is placed by its time: a push before the session's end comes before it" do
      html =
        list(
          preparation(%{
            after_session: [step(3, "push", "Push proposal", 300, 2)],
            outputs: [%{type: "proposal", number: 3, at: at(301)}]
          })
        )

      assert rows(html) == [
               "prepare-machine-queued",
               "prepare-machine-requested",
               "prepare-machine-started",
               "prepare-machine-prepare",
               "prepare-machine-session",
               "prepare-machine-outputs",
               "prepare-machine-session-finished"
             ]
    end

    test "is not there when the run pushed nothing" do
      html = list(preparation(%{after_session: [], outputs: []}))
      refute "prepare-machine-outputs" in rows(html)
    end
  end

  describe "a run on a permanent machine" do
    test "keeps its list, whose last row is Machine stays registered, with no time" do
      html = list(preparation(%{machine: nil}), clean_up: :stays)

      assert List.last(rows(html)) == "prepare-machine-removed"
      row = LazyHTML.query(html, "#prepare-machine-removed")
      assert text(LazyHTML.query(row, ".q-prep-name")) == "Machine stays registered"
      refute text(row) =~ "Machine removed"
      assert row |> LazyHTML.query("time") |> Enum.count() == 0
      assert LazyHTML.attribute(row, "data-clean-up") == ["stays"]
    end
  end
end
