defmodule ApiaryWeb.PreparationStepsTest do
  # Start the machine and Prepare the machine in the Run list
  # (`ApiaryWeb.PreparationComponents`): Start the machine is one row, with Machine
  # started and the lines of the step of the kind `machine`; Prepare the machine has the
  # run's steps before the first agent session in order, each with its label or its name,
  # and Prepare the session the wall and the join; a step's log lines with their numbers
  # and times; the machine log for an instance admin alone, numbered with no time; which
  # rows are open; each group's state and span.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ApiaryWeb.{Format, PreparationComponents}

  @dispatched ~U[2026-11-06 00:31:44.000000Z]
  @redeemed ~U[2026-11-06 00:32:25.000000Z]

  defp at(seconds), do: DateTime.add(@dispatched, round(seconds * 1000), :millisecond)

  # A step's or a session's place among the run's events, its sequence: the tenths of
  # seconds from `dispatched` to its start.
  defp sequence(seconds), do: round(seconds * 10)

  defp machine(started \\ %{}) do
    %{
      dispatch_id: "dp_0123456789abcdef",
      pool: %{id: "np_0123456789abcdef", name: "build-pool", place: :workspace, operator: nil},
      queued_at: nil,
      machine_type: nil,
      requested_at: DateTime.add(@dispatched, -4, :second),
      requested_ms: 3_000,
      started_as: nil,
      release_reason: nil,
      handed_over_at: @dispatched,
      ended_at: nil,
      end: nil,
      started:
        Map.merge(
          %{
            state: "succeeded",
            started_at: @dispatched,
            ended_at: @redeemed,
            duration_ms: 41_000
          },
          started
        )
    }
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
        started_sequence: sequence(started),
        exited_sequence: sequence(started + took),
        duration_ms: round(took * 1000),
        output: %{lines: [], truncated: false, lines_cut: false}
      },
      changes
    )
  end

  defp steps do
    [
      step(1, "fetch", "Fetch git.example.com/acme/storefront", 42, 4),
      step(2, "image", "Image registry.example.com/acme/storefront-dev", 46, 36),
      step(3, "compose", "Compose the harness", 82.5, 0.5),
      step(4, "setup", "Setup postCreateCommand: npm ci", 83, 48),
      step(5, "wall", "Start the wall", 131, 0.5),
      step(6, "join", "Join session 1", 132, 1)
    ]
  end

  # How the agent session ended: its exit at 2,400 s.
  defp session_end do
    %{
      result_at: nil,
      outcome: nil,
      turns: nil,
      duration_ms: nil,
      cost_usd: nil,
      exited_at: at(2_400),
      state: "succeeded",
      reason: nil,
      exit_code: 0,
      model: nil
    }
  end

  # A run whose agent session started 133 s after `dispatched`, unless `sessions` or
  # `session_started_at` is given. A run with no session's start has no session's end.
  defp preparation(changes \\ %{}) do
    started = Map.get(changes, :session_started_at, at(133))

    %{
      machine: machine(),
      steps: steps(),
      after_session: [],
      log_pruned_at: nil,
      session_started_at: started,
      session_end: if(started, do: session_end()),
      stopped: nil
    }
    |> Map.merge(changes)
    |> then(&Map.put_new(&1, :sessions, sessions(&1)))
  end

  defp sessions(%{session_started_at: nil}), do: []

  defp sessions(%{session_started_at: at, session_end: finished}) do
    seconds = DateTime.diff(at, @dispatched, :millisecond) / 1000
    [%{session: 1, sequence: sequence(seconds), started_at: at, end: finished}]
  end

  defp section(preparation, opts \\ []),
    do: preparation |> section_html(opts) |> LazyHTML.from_fragment()

  defp section_html(preparation, opts \\ []) do
    render_component(&PreparationComponents.run_list/1,
      preparation: preparation,
      alive: Keyword.get(opts, :alive, false),
      machine_log: Keyword.get(opts, :machine_log, :hidden),
      run_state: Keyword.get(opts, :run_state)
    )
  end

  defp names(html, selector) do
    html |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp text(html), do: html |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  # The rows directly in Prepare the machine, and in the first Prepare the session.
  @grouped "#prepare-machine-prepare > .q-xb > ol > li > details > summary .q-prep-name"
  @session_steps "#prepare-machine-session-prepare > .q-xb > ol > li > details > summary .q-prep-name"

  # Start the machine's lines.
  @start_lines "#prepare-machine-start #prepare-machine-start-machine-output-lines"
  # The rows directly in the section.
  @section "#prepare-machine > ol > li > details > summary .q-prep-name"

  test "Start the machine is one row; Prepare the machine has the run's steps in order" do
    html = section(preparation())

    assert names(html, @section) == [
             "Request a machine",
             "Start the machine",
             "Prepare the machine",
             "Agent session 1"
           ]

    assert html |> LazyHTML.query("#prepare-machine-start details") |> Enum.count() == 0

    assert names(html, @grouped) == [
             "Clone the repository",
             "Pull the images",
             "Compose the harness",
             "Set up the dev container"
           ]

    assert names(html, @session_steps) == ["Start the wall", "Start the agent"]

    ids =
      html
      |> LazyHTML.query("#prepare-machine-prepare > .q-xb > ol > li > details")
      |> LazyHTML.attribute("id")

    assert ids == for(n <- 1..4, do: "prepare-machine-step-#{n}")

    ids =
      html
      |> LazyHTML.query("#prepare-machine-session-prepare > .q-xb > ol > li > details")
      |> LazyHTML.attribute("id")

    assert ids == ["prepare-machine-step-5", "prepare-machine-step-6"]
  end

  test "a step of a kind the labels have is its label; any other kind keeps qory's name" do
    assert PreparationComponents.step_label(%{kind: "fetch"}) == "Clone the repository"
    assert PreparationComponents.step_label(%{kind: "compose"}) == "Compose the harness"
    assert PreparationComponents.step_label(%{kind: "image"}) == "Pull the images"
    assert PreparationComponents.step_label(%{kind: "build"}) == "Build the image"
    assert PreparationComponents.step_label(%{kind: "setup"}) == "Set up the dev container"
    assert PreparationComponents.step_label(%{kind: "join"}) == "Start the agent"
    assert PreparationComponents.step_label(%{kind: "wall"}) == "Start the wall"

    for kind <- ["push", "check", nil],
        do: assert(PreparationComponents.step_label(%{kind: kind}) == nil)

    check = step(7, "check", "Check the storefront", 90, 1)
    html = section(preparation(%{steps: steps() ++ [check]}))

    # A label is a text of the page; a name came from the run, isolated as sent text.
    assert html |> LazyHTML.query("#prepare-machine-step-1 summary bdi") |> Enum.count() == 0
    assert html |> LazyHTML.query("#prepare-machine-step-3 summary bdi") |> Enum.count() == 0
    assert names(html, "#prepare-machine-step-7 summary bdi") == ["Check the storefront"]
  end

  test "Start the machine spans from `dispatched` to the redemption" do
    html = section(preparation())
    start = LazyHTML.query(html, "#prepare-machine-start > summary")

    assert start |> LazyHTML.query(".q-tc1 time") |> LazyHTML.attribute("datetime") ==
             [DateTime.to_iso8601(@dispatched)]

    assert text(LazyHTML.query(start, ".q-tc2")) == "41 s"
  end

  test "Start the machine has Machine started at the redemption" do
    html = section(preparation())
    start = LazyHTML.query(html, "#prepare-machine-start > .q-xb > dl")

    assert text(LazyHTML.query(start, "dt")) == "Machine started"
    assert text(LazyHTML.query(start, "dd")) == Format.time(@redeemed, seconds: true)
  end

  test "Prepare the machine spans from its first step's start to the end of its last step" do
    html = section(preparation())
    group = LazyHTML.query(html, "#prepare-machine-prepare > summary")

    assert group |> LazyHTML.query(".q-tc1 time") |> LazyHTML.attribute("datetime") ==
             [DateTime.to_iso8601(at(42))]

    # The fetch starts 42 s after `dispatched`; the set-up ends at 131 s.
    assert text(LazyHTML.query(group, ".q-tc2")) == "1 m 29 s"

    assert html
           |> LazyHTML.query("#prepare-machine-prepare[data-state=succeeded]")
           |> Enum.count() ==
             1
  end

  test "a run no node pool claimed has Prepare the machine with its steps, no machine rows" do
    html = section(preparation(%{machine: nil}))

    assert names(html, @section) == ["Prepare the machine", "Agent session 1"]

    assert names(html, @grouped) == [
             "Clone the repository",
             "Pull the images",
             "Compose the harness",
             "Set up the dev container"
           ]

    assert html |> LazyHTML.query("#prepare-machine-start") |> Enum.count() == 0
    assert html |> LazyHTML.query("#prepare-machine-request") |> Enum.count() == 0
  end

  test "a step's log: each line's number and its time to the tenth of a second" do
    t = ~U[2026-11-06 00:33:07.678000Z]

    lines = [
      %{number: 1, at: t, text: "Reading devcontainer.json"},
      %{number: 2, at: DateTime.add(t, 36_100, :millisecond), text: "found 0 vulnerabilities"},
      %{number: 3, at: nil, text: "a line with no time"}
    ]

    output = %{lines: lines, truncated: false, lines_cut: false}
    steps = List.update_at(steps(), 3, &%{&1 | output: output})
    html = section(preparation(%{steps: steps}))
    log = LazyHTML.query(html, "#prepare-machine-step-4-output-lines.q-log.q-log-timed")

    assert names(log, ".q-log-n") == ["1", "2", "3"]
    assert names(log, ".q-log-t") == ["00:33:07.6", "00:33:43.7", ""]

    assert log |> LazyHTML.query(".q-log-t time") |> LazyHTML.attribute("datetime") ==
             [DateTime.to_iso8601(t), DateTime.to_iso8601(DateTime.add(t, 36_100, :millisecond))]

    assert names(log, ".q-log-x") ==
             ["Reading devcontainer.json", "found 0 vulnerabilities", "a line with no time"]

    assert Format.time(t, tenths: true) == "00:33:07.6"
  end

  describe "the machine log" do
    test "is in Start the machine for an instance admin, its lines numbered with no time" do
      log = "qory-machine-start: Docker started\r\n\nready\n"
      html = section(preparation(), machine_log: {:ok, log, false})

      lines =
        LazyHTML.query(html, "#prepare-machine-start #prepare-machine-machine-log-lines")

      assert text(LazyHTML.query(html, "#prepare-machine-machine-log")) =~
               "Machine log (instance admins)"

      assert names(lines, ".q-log-n") == ["1", "2", "3"]
      assert names(lines, ".q-log-x") == ["qory-machine-start: Docker started", "", "ready"]
      assert lines |> LazyHTML.query(".q-log-t") |> Enum.count() == 0
      refute lines |> LazyHTML.attribute("class") |> hd() =~ "q-log-timed"
    end

    test "cut to its end keeps each line's number in the whole log" do
      line = String.duplicate("x", 99)
      log = Enum.map_join(1..1_000, "", &"#{&1} #{line}\n")
      html = section(preparation(), machine_log: {:ok, log, false})

      numbers = names(html, "#prepare-machine-machine-log-lines .q-log-n")
      texts = names(html, "#prepare-machine-machine-log-lines .q-log-x")

      assert List.last(numbers) == "1000"
      assert length(numbers) < 1_000
      # The first line is the end of the line the cut fell in.
      for {number, text} <- tl(Enum.zip(numbers, texts)), do: assert(text == "#{number} #{line}")
    end

    test "is not there for anyone else: Start the machine has no log" do
      html = section(preparation())
      assert html |> LazyHTML.query("#prepare-machine-machine-log") |> Enum.count() == 0
      assert html |> LazyHTML.query("#prepare-machine-start .q-well") |> Enum.count() == 0
    end
  end

  describe "a step of the kind machine" do
    # A `machine` step as step 1, started 14.8 s after `dispatched`, with `parts` as lines.
    defp machine_step(parts, opts \\ []) do
      lines =
        parts
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, seconds, at}, n} ->
          %{
            number: n,
            at: if(opts[:same_time], do: at(14.8), else: at),
            text: "#{name}  #{seconds} s"
          }
        end)

      step(1, "machine", "Start machine", 14.8, 19.6, %{
        output: %{lines: lines, truncated: false, lines_cut: false}
      })
    end

    defp parts,
      do: [
        {"boot", 14.8, at(14.8)},
        {"read start data", 0.1, at(29.6)},
        {"start Docker", 3.2, at(31.0)}
      ]

    defp with_machine_step(step) do
      preparation(%{steps: [step | Enum.map(steps(), &%{&1 | number: &1.number + 1})]})
    end

    test "is no row: its lines are Start the machine's, after create machine and its seconds" do
      html = section(with_machine_step(machine_step(parts())))

      assert html |> LazyHTML.query("#prepare-machine-start details") |> Enum.count() == 0

      assert names(html, @grouped) == [
               "Clone the repository",
               "Pull the images",
               "Compose the harness",
               "Set up the dev container"
             ]

      assert names(html, @session_steps) == ["Start the wall", "Start the agent"]

      lines = LazyHTML.query(html, @start_lines)

      assert names(lines, ".q-log-n") == ["1", "2", "3", "4"]

      assert names(lines, ".q-log-x") == [
               "create machine  14.8 s",
               "boot  14.8 s",
               "read start data  0.1 s",
               "start Docker  3.2 s"
             ]

      assert lines |> LazyHTML.query(".q-log-t time") |> LazyHTML.attribute("datetime") ==
               Enum.map([@dispatched, at(14.8), at(29.6), at(31.0)], &DateTime.to_iso8601/1)

      # Start the machine's mark and time stay from `dispatched` to the redemption.
      assert text(LazyHTML.query(html, "#prepare-machine-start > summary .q-tc2")) == "41 s"
    end

    test "a member reads the lines; an instance admin reads them and the machine log" do
      member = section(with_machine_step(machine_step(parts())))

      assert member
             |> LazyHTML.query("#prepare-machine-start-machine-output-lines .q-log-ln")
             |> Enum.count() == 4

      assert member |> LazyHTML.query("#prepare-machine-machine-log") |> Enum.count() == 0

      admin =
        section(with_machine_step(machine_step(parts())),
          machine_log: {:ok, "Docker started\n", false}
        )

      assert admin
             |> LazyHTML.query("#prepare-machine-start-machine-output-lines .q-log-ln")
             |> Enum.count() == 4

      assert names(admin, "#prepare-machine-machine-log-lines .q-log-x") == ["Docker started"]
    end

    test "a run with none has Start the machine as before: no lines but the machine log" do
      html = section(preparation(), machine_log: {:ok, "Docker started\n", false})
      assert html |> LazyHTML.query("#prepare-machine-start-machine-output") |> Enum.count() == 0
      assert names(html, "#prepare-machine-start .q-log-x") == ["Docker started"]
      refute LazyHTML.text(html) =~ "create machine"
    end

    test "lines that share one time each keep it, numbered in order" do
      html = section(with_machine_step(machine_step(parts(), same_time: true)))
      lines = LazyHTML.query(html, "#prepare-machine-start-machine-output-lines")

      assert names(lines, ".q-log-n") == ["1", "2", "3", "4"]

      assert lines |> LazyHTML.query(".q-log-t time") |> LazyHTML.attribute("datetime") ==
               [
                 DateTime.to_iso8601(@dispatched)
                 | List.duplicate(DateTime.to_iso8601(at(14.8)), 3)
               ]
    end

    test "a failed or running machine step opens Start the machine; a failure has its cause" do
      failed = %{machine_step(parts()) | state: "failed", exit_code: 1}

      stopped = %{
        cause: :step_failed,
        step: 1,
        fixer: :workspace_admin,
        text: "",
        what: "Start the machine failed with exit code 1.",
        fix: "An admin of Storefront reads the cause in the step's output."
      }

      html =
        section(preparation(%{steps: [failed], stopped: stopped, session_started_at: nil}))

      assert open_ids(html) == ["prepare-machine-start"]

      assert html |> LazyHTML.query("#prepare-machine-start[data-state=failed]") |> Enum.count() ==
               1

      assert text(LazyHTML.query(html, "#prepare-machine-start #prepare-machine-cause")) ==
               "Start the machine failed with exit code 1."

      running = %{machine_step(parts()) | state: "running", exited_at: nil, duration_ms: nil}

      html =
        section(preparation(%{steps: [running], session_started_at: nil}), alive: true)

      assert open_ids(html) == ["prepare-machine-start"]
    end

    test "sent after the redemption, its lines have no create machine line" do
      # The step's events at the time `qory run` sent them, 0.3 s after the redemption.
      sent = [{"boot", 14.8, at(41.3)}, {"start Docker", 3.2, at(41.3)}]
      step = %{machine_step(sent) | started_at: at(41.3)}
      lines = LazyHTML.query(section(with_machine_step(step)), @start_lines)

      assert names(lines, ".q-log-n") == ["1", "2"]
      assert names(lines, ".q-log-x") == ["boot  14.8 s", "start Docker  3.2 s"]
    end

    test "with no line: create machine, then No output. or the pruned sentence" do
      empty = machine_step([])
      html = section(with_machine_step(empty))

      assert names(html, "#{@start_lines} .q-log-x") == ["create machine  14.8 s"]
      assert text(LazyHTML.query(html, "#prepare-machine-start-machine-output")) =~ "No output."

      html = section(%{with_machine_step(empty) | log_pruned_at: at(9_000)})
      start = text(LazyHTML.query(html, "#prepare-machine-start-machine-output"))
      assert start =~ "create machine 14.8 s"
      assert start =~ "This run's log output was pruned on"
      refute start =~ "No output."
    end

    test "a reader who may not read the run's log has no line, create machine neither" do
      html = section(with_machine_step(%{machine_step(parts()) | output: nil}))
      assert html |> LazyHTML.query("#prepare-machine-start-machine-output") |> Enum.count() == 0
      refute LazyHTML.text(html) =~ "create machine"
    end

    test "cut to its last 2,500 lines, the note counts the step's lines alone" do
      parts = for n <- 2_501..5_000, do: {"part #{n}", 0.1, at(14.8)}

      step =
        machine_step(parts)
        |> update_in([:output], &%{&1 | truncated: true, lines_cut: true})

      html = section(with_machine_step(step))

      assert html |> LazyHTML.query("#{@start_lines} .q-log-ln") |> Enum.count() == 2_501

      assert text(LazyHTML.query(html, "#prepare-machine-start-machine-output > p")) ==
               "The output is cut: these are its last 2,500 lines."
    end

    test "64 lines, the most qory sends, are all shown after create machine" do
      parts = for n <- 1..64, do: {"part #{n}", 0.1, at(14.8 + n / 10)}
      html = section(with_machine_step(machine_step(parts)))
      lines = LazyHTML.query(html, "#prepare-machine-start-machine-output-lines")

      assert names(lines, ".q-log-n") == Enum.map(1..65, &Integer.to_string/1)
      assert names(lines, ".q-log-x") |> List.last() == "part 64  0.1 s"
    end
  end

  describe "open rows" do
    defp open_ids(html),
      do: html |> LazyHTML.query("#prepare-machine details[open]") |> LazyHTML.attribute("id")

    test "a run that went well has every row closed" do
      assert open_ids(section(preparation())) == []
    end

    test "a run still starting: Start the machine runs, open and ticking" do
      preparation =
        preparation(%{
          machine: machine(%{state: "running", ended_at: nil, duration_ms: nil}),
          steps: [],
          session_started_at: nil
        })

      html = section(preparation, alive: true)

      assert open_ids(html) == ["prepare-machine-start"]

      summary = LazyHTML.query(html, "#prepare-machine-start > summary")
      assert text(summary) =~ "Running"

      assert summary |> LazyHTML.query("#prepare-machine-start-clock[data-tick]") |> Enum.count() ==
               1
    end

    test "a running step is open in an open group, the steps before it closed" do
      steps =
        steps()
        |> Enum.take(4)
        |> List.update_at(3, &%{&1 | state: "running", exited_at: nil, duration_ms: nil})

      html = section(preparation(%{steps: steps, session_started_at: nil}), alive: true)

      assert open_ids(html) == ["prepare-machine-prepare", "prepare-machine-step-4"]
      assert text(LazyHTML.query(html, "#prepare-machine-step-4 > summary")) =~ "Running"
      # The group has no duration while a row runs; its clock ticks.
      group = LazyHTML.query(html, "#prepare-machine-prepare > summary")
      assert group |> LazyHTML.query(".q-tc2 .q-d") |> Enum.count() == 1

      assert group |> LazyHTML.query(".q-tc2 .q-d #prepare-machine-prepare-clock") |> Enum.count() ==
               1
    end

    test "a live run between two steps: Prepare the machine is running and open, no clock" do
      steps = Enum.take(steps(), 2)
      html = section(preparation(%{steps: steps, session_started_at: nil}), alive: true)

      assert open_ids(html) == ["prepare-machine-prepare"]

      assert html
             |> LazyHTML.query("#prepare-machine-prepare[data-state=running]")
             |> Enum.count() == 1

      group = LazyHTML.query(html, "#prepare-machine-prepare > summary")
      assert text(group) =~ "Running"
      assert group |> LazyHTML.query(".q-d") |> Enum.count() == 0

      # Once the run has ended, it is closed.
      html = section(preparation(%{steps: steps, session_started_at: nil}))
      assert open_ids(html) == []
    end

    test "a failed step is open with its cause line, in a failed group" do
      steps =
        steps()
        |> Enum.take(4)
        |> List.update_at(3, &%{&1 | state: "failed", exit_code: 1})

      stopped = %{
        cause: :step_failed,
        step: 4,
        fixer: :workspace_admin,
        text: "",
        what: "Set up the dev container failed with exit code 1 (postCreateCommand: npm ci).",
        fix: "An admin of Storefront reads the cause in the step's output.",
        detail: "postCreateCommand: npm ci"
      }

      html = section(preparation(%{steps: steps, stopped: stopped, session_started_at: nil}))

      assert open_ids(html) == ["prepare-machine-prepare", "prepare-machine-step-4"]

      assert html |> LazyHTML.query("#prepare-machine-prepare[data-state=failed]") |> Enum.count() ==
               1

      cause = LazyHTML.query(html, "#prepare-machine-step-4 #prepare-machine-cause")

      assert text(cause) ==
               "Set up the dev container failed with exit code 1 (postCreateCommand: npm ci)."

      # The set-up command is in code font; the hook's name and the sentence are not.
      assert cause |> LazyHTML.query("code") |> Enum.map(&text/1) == ["npm ci"]
    end

    test "a detail that is no hook and its command is plain, in parentheses" do
      steps =
        steps()
        |> Enum.take(1)
        |> List.update_at(0, &%{&1 | state: "failed", exit_code: 128})

      stopped = %{
        cause: :step_failed,
        step: 1,
        fixer: :workspace_admin,
        text: "",
        what: "Clone the repository failed with exit code 128 (git.example.com/acme/storefront).",
        fix: "An admin of Storefront reads the cause in the step's output.",
        detail: "git.example.com/acme/storefront"
      }

      html = section(preparation(%{steps: steps, stopped: stopped, session_started_at: nil}))
      cause = LazyHTML.query(html, "#prepare-machine-step-1 #prepare-machine-cause")

      assert text(cause) ==
               "Clone the repository failed with exit code 128 (git.example.com/acme/storefront)."

      assert cause |> LazyHTML.query("code") |> Enum.count() == 0
    end

    test "a machine that did not start: Start the machine is open with what happened" do
      stopped = %{
        cause: :machine_not_made,
        step: nil,
        fixer: :workspace_admin,
        text: "",
        what: "No machine was made: No capacity.",
        fix: "An admin of Storefront reads why in the log of build-pool on its host."
      }

      preparation =
        preparation(%{
          machine: machine(%{state: "failed"}),
          steps: [],
          stopped: stopped,
          session_started_at: nil
        })

      html = section(preparation)

      assert open_ids(html) == ["prepare-machine-start"]

      assert text(LazyHTML.query(html, "#prepare-machine-start #prepare-machine-cause")) ==
               "No machine was made: No capacity."
    end
  end

  describe "a later session's steps" do
    # Session 1 started 48 s after `dispatched`; the join of session 2, 40 minutes later.
    defp later_join(changes \\ %{}), do: step(3, "join", "Join session 2", 2_446, 1, changes)

    defp first_steps,
      do: [
        step(1, "fetch", "Fetch git.example.com/acme/storefront", 42, 4),
        step(2, "join", "Join session 1", 46, 1)
      ]

    defp section_rows(html),
      do:
        html |> LazyHTML.query("#prepare-machine > ol > li > details") |> LazyHTML.attribute("id")

    defp step_ids(html, id),
      do:
        html
        |> LazyHTML.query("##{id} > .q-xb > ol > li > details")
        |> LazyHTML.attribute("id")

    test "a later join is in Agent session 2; Prepare the machine ends before the first" do
      html =
        section(
          preparation(%{steps: first_steps() ++ [later_join()], session_started_at: at(48)})
        )

      assert names(html, @grouped) == ["Clone the repository"]
      assert names(html, @session_steps) == ["Start the agent"]

      assert section_rows(html) == [
               "prepare-machine-request",
               "prepare-machine-start",
               "prepare-machine-prepare",
               "prepare-machine-session",
               "prepare-machine-session-2"
             ]

      assert step_ids(html, "prepare-machine-session-2-prepare") == ["prepare-machine-step-3"]

      group = LazyHTML.query(html, "#prepare-machine-prepare > summary")
      assert text(LazyHTML.query(group, ".q-tc2")) == "4 s"

      assert html
             |> LazyHTML.query("#prepare-machine-prepare[data-state=succeeded]")
             |> Enum.count() == 1
    end

    test "a step with only its exit, after the session's start, is in that session" do
      exit_only = later_join(%{name: nil, kind: nil, started_at: nil, started_sequence: nil})

      html =
        section(preparation(%{steps: first_steps() ++ [exit_only], session_started_at: at(48)}))

      assert List.last(section_rows(html)) == "prepare-machine-session"

      assert step_ids(html, "prepare-machine-session-prepare") == [
               "prepare-machine-step-2",
               "prepare-machine-step-3"
             ]

      assert names(html, @session_steps) == ["Start the agent", "Step 3"]
      group = LazyHTML.query(html, "#prepare-machine-prepare > summary")
      assert text(LazyHTML.query(group, ".q-tc2")) == "4 s"
    end

    test "while a later join runs, Prepare the machine stays closed, with its end, no clock" do
      running = later_join(%{state: "running", exited_at: nil, duration_ms: nil})

      html =
        section(preparation(%{steps: first_steps() ++ [running], session_started_at: at(48)}),
          alive: true
        )

      assert open_ids(html) == [
               "prepare-machine-session",
               "prepare-machine-session-agent",
               "prepare-machine-session-2",
               "prepare-machine-session-2-prepare",
               "prepare-machine-step-3"
             ]

      group = LazyHTML.query(html, "#prepare-machine-prepare > summary")
      assert text(LazyHTML.query(group, ".q-tc2")) == "4 s"
      assert html |> LazyHTML.query("#prepare-machine-prepare-clock") |> Enum.count() == 0

      assert html
             |> LazyHTML.query("#prepare-machine-prepare[data-state=succeeded]")
             |> Enum.count() == 1
    end
  end

  describe "a session that paused at the run's model keys' limit" do
    defp paused_section(session_end) do
      preparation(%{session_end: Map.merge(session_end(), session_end)}) |> section()
    end

    test "shows Paused on Run the agent and on its Agent session, with the paused ring" do
      for exit <- [
            %{state: "paused", reason: "model_key_limit"},
            # The shape of a gateway of the earlier contract.
            %{state: "cancelled", reason: "model_key_limit"}
          ] do
        html = paused_section(exit)

        for id <- ~w(prepare-machine-session-agent prepare-machine-session) do
          assert html |> LazyHTML.query("##{id}[data-state=paused]") |> Enum.count() == 1,
                 inspect({id, exit})

          summary = LazyHTML.query(html, "##{id} > summary")
          assert summary |> LazyHTML.query(".q-st-paused") |> Enum.count() == 1
          assert summary |> LazyHTML.query(".sr-only") |> text() =~ "Paused"
        end
      end
    end

    test "on a run that ended completed, as after it pushed its result, shows Succeeded" do
      for exit <- [
            %{state: "paused", reason: "model_key_limit"},
            %{state: "cancelled", reason: "model_key_limit"}
          ] do
        session_end = Map.merge(session_end(), exit)
        html = preparation(%{session_end: session_end}) |> section(run_state: "completed")

        for id <- ~w(prepare-machine-session-agent prepare-machine-session) do
          assert html |> LazyHTML.query("##{id}[data-state=succeeded]") |> Enum.count() == 1,
                 inspect({id, exit})

          summary = LazyHTML.query(html, "##{id} > summary")
          assert summary |> LazyHTML.query(".q-prep-ok") |> Enum.count() == 1
          assert summary |> LazyHTML.query(".q-st-paused") |> Enum.count() == 0
          assert summary |> LazyHTML.query(".sr-only") |> text() =~ "Succeeded"
        end

        # A run that paused and is continued keeps its paused session.
        html = preparation(%{session_end: session_end}) |> section(run_state: "paused")

        assert html
               |> LazyHTML.query("#prepare-machine-session-agent[data-state=paused]")
               |> Enum.count() == 1
      end
    end

    test "a paused session with another reason or none shows Failed, as its run" do
      for exit <- [%{state: "paused", reason: "stopped"}, %{state: "paused", reason: nil}] do
        html = paused_section(exit)

        for id <- ~w(prepare-machine-session-agent prepare-machine-session) do
          assert html |> LazyHTML.query("##{id}[data-state=failed]") |> Enum.count() == 1,
                 inspect({id, exit})

          summary = LazyHTML.query(html, "##{id} > summary")
          assert summary |> LazyHTML.query(".q-st-paused") |> Enum.count() == 0
          assert summary |> LazyHTML.query(".sr-only") |> text() =~ "Failed"
        end
      end
    end

    test "a cancelled session with another reason stays Cancelled" do
      html = paused_section(%{state: "cancelled", reason: "stopped"})

      assert html
             |> LazyHTML.query("#prepare-machine-session-agent[data-state=cancelled]")
             |> Enum.count() == 1
    end
  end

  describe "a step of 2,500 lines, the most a step keeps" do
    test "of one character each takes under 1 MB of markup, with the cut note" do
      lines = for n <- 37_501..40_000, do: %{number: n, at: at(50 + n / 1000), text: "."}
      output = %{lines: lines, truncated: true, lines_cut: true}

      html =
        section_html(
          preparation(%{steps: [step(1, "setup", "Setup", 50, 40, %{output: output})]})
        )

      assert byte_size(html) < 1_000_000
      doc = LazyHTML.from_fragment(html)

      assert doc
             |> LazyHTML.query("#prepare-machine-step-1-output-lines .q-log-ln")
             |> Enum.count() == 2_500

      assert text(LazyHTML.query(doc, "#prepare-machine-step-1-output > p")) ==
               "The output is cut: these are its last 2,500 lines."
    end

    test "of 64 KiB takes under 1 MB of markup" do
      lines =
        for n <- 1..2_500,
            do: %{number: n, at: at(50 + n / 1000), text: String.duplicate("x", 25)}

      output = %{lines: lines, truncated: false, lines_cut: false}

      html =
        section_html(
          preparation(%{steps: [step(1, "setup", "Setup", 50, 40, %{output: output})]})
        )

      assert byte_size(html) < 1_000_000
    end
  end
end
