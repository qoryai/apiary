defmodule ApiaryWeb.RunComponentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ApiaryWeb.RunComponents

  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Forager's own end reasons, reserved in the contract's run.exited, and the three names
  # three of them had before; and the codes of its run.refused.
  @reserved ~w(timeout quiet credential_expired stopped interrupted no_session session_lost gateway_lost
               batch_refused credential_check_unreachable credential_check_invalid run_closed)
  @earlier ~w(run_ended_at_issuer issuer_unreachable issuer_answer_invalid)
  @refusals ~w(bad_request unsupported_contract_version invalid_request rate_limited unavailable
               key_invalid key_limit instance_limit secrets_not_allowed run_closed session_lost
               batch_refused credential_expired stopped run_configuration_superseded
               apiary_public_key_missing answer_unsigned unauthorized labels_changed
               server_needs_wall mount_contains_forager_files mount_mode_conflict
               mount_shared_with_run mount_through_link engine_unreachable
               run_configuration_invalid tool_unknown image_unknown variable_reserved
               placeholder_conflict run_credential_refused target_differs_from_credential
               differs_from_credential run_id_used not_found credential_check_unreachable
               credential_check_invalid)

  describe "run_state" do
    test "every state says its word, with its mark and its colour" do
      for {state, word, glyph, colour} <- [
            {"pending", "Pending", nil, nil},
            {"running", "Running", nil, "bg-info-soft"},
            {"completed", "Completed", "hero-check-micro", "bg-success-soft"},
            {"failed", "Failed", "hero-x-mark-micro", "bg-error-soft"},
            {"cancelled", "Cancelled", "hero-stop-micro", nil},
            {"lost", "Lost", "hero-signal-slash-micro", "bg-primary-soft"}
          ],
          name <- [state, String.to_atom(state)] do
        html = render_component(&RunComponents.run_state/1, state: name)
        assert text(html) == word, state
        assert RunComponents.state_label(name) == word

        if glyph,
          do: assert(html =~ ~s(class="#{glyph}), state),
          else: refute(html =~ "hero-", state)

        if colour,
          do: assert(html =~ colour, state),
          else: refute(html =~ "-soft", state)

        assert html =~ "q-state-running" == (state == "running")
        assert html =~ "q-state-pending" == (state == "pending")
      end
    end

    test "a cancelled run's mark is the stop, grey, not the denial's" do
      html = render_component(&RunComponents.run_state/1, state: "cancelled")
      assert html =~ "hero-stop-micro"
      refute html =~ "hero-no-symbol"
      refute html =~ "-soft"
    end

    test "a failed run shows its exit code, or its signal instead" do
      assert text(render_component(&RunComponents.run_state/1, state: "failed", exit_code: 1)) ==
               "Failed exit 1"

      assert text(
               render_component(&RunComponents.run_state/1,
                 state: "failed",
                 exit_code: -1,
                 signal: "SIGKILL"
               )
             ) == "Failed SIGKILL"

      assert text(render_component(&RunComponents.run_state/1, state: "failed", exit_code: -1)) ==
               "Failed"

      assert text(render_component(&RunComponents.run_state/1, state: "completed", exit_code: 0)) ==
               "Completed"
    end

    test "a row's mark: a completed run's word is for a screen reader, a cancelled run's is grey" do
      for state <- ~w(completed) do
        html = render_component(&RunComponents.run_mark/1, state: state)
        assert html =~ "q-st-#{state}"
        assert html =~ ~s(class="q-st-w sr-only")
        assert text(html) == "Completed"
      end

      for state <- ~w(cancelled) do
        html = render_component(&RunComponents.run_mark/1, state: state)
        assert html =~ "q-st-#{state}"
        refute html =~ "sr-only"
        assert text(html) == "Cancelled"
      end
    end

    test "an ended run's sentence says its state" do
      for {state, run, sentence} <- [
            {"completed", %{duration_ms: 720_000}, "Completed 12 m 00 s after it started"},
            {"completed", %{}, "Completed"},
            {"cancelled", %{duration_ms: 720_000}, "Cancelled after 12 m 00 s"},
            {"failed", %{exit_code: 1}, "Failed with exit 1"}
          ] do
        html = render_component(&RunComponents.alive/1, state: state, run: run)
        assert text(html) == sentence, "#{state}: #{text(html)}"
      end
    end

    test "reason_words says Forager's own reasons in words of their own, each in the catalogue" do
      pot = File.read!(Path.expand("../../../priv/gettext/default.pot", __DIR__))

      for {reason, words} <- [
            {"timeout", "time limit reached"},
            {"credential_expired", "permission to run expired"},
            {"stopped", "stopped, no outcome given"},
            {"interrupted", "interrupted"},
            {"session_lost", "stopped responding"},
            {"gateway_lost", "end not recorded"},
            {"batch_refused", "events refused"},
            {"credential_check_unreachable",
             "couldn't check whether the run may go on: no answer"},
            {"credential_check_invalid",
             "couldn't check whether the run may go on: unreadable answer"}
          ] do
        assert RunComponents.reason_words(%{reason: reason}) == words
        # Forager's words are a message to translate, not a starter's code shown as given.
        assert pot =~ ~s(\nmsgid "#{words}"\n), reason
      end

      assert RunComponents.reason_words(%{reason: "run_closed"}) == nil
      assert RunComponents.reason_words(%{reason: nil}) == nil
    end

    test "a refused batch reads events refused, whatever the state" do
      for state <- [nil, "failed", :failed, "lost"] do
        assert RunComponents.reason_words(%{reason: "batch_refused", state: state}) ==
                 "events refused"
      end
    end

    test "a run stopped where it was started reads interrupted, whatever the state" do
      for state <- [nil, "cancelled", :cancelled, "failed", "completed"] do
        assert RunComponents.reason_words(%{reason: "interrupted", state: state}) ==
                 "interrupted"
      end
    end

    test "stopped beside an outcome says only that the run was stopped" do
      for state <- ["completed", :completed, "failed", :failed] do
        assert RunComponents.reason_words(%{reason: "stopped", state: state}) == "stopped"
      end

      for state <- [nil, "cancelled", :cancelled] do
        assert RunComponents.reason_words(%{reason: "stopped", state: state}) ==
                 "stopped, no outcome given"
      end
    end

    test "an outcome sent with no state reads the starter gave no outcome" do
      run = %{state: "cancelled", reason: "stopped", outcome_state: "cancelled"}

      assert RunComponents.reason_words(Map.put(run, :outcome_reason, "stopped")) ==
               "the starter gave no outcome"

      # The starter's end with no outcome is Forager's stopped, or its earlier name.
      for reason <- ["stopped", "run_ended_at_issuer"],
          outcome <- [%{}, %{outcome_state: nil, outcome_reason: nil}] do
        assert RunComponents.reason_words(
                 Map.merge(%{state: "cancelled", reason: reason}, outcome)
               ) ==
                 "stopped, no outcome given"
      end

      # A starter's own cancelled reason is shown as given.
      assert RunComponents.reason_words(
               %{run | reason: "no_longer_needed"}
               |> Map.put(:outcome_reason, "no_longer_needed")
             ) ==
               "no longer needed"
    end

    test "a run released after a queue handed it over reads that its starter released it" do
      released = %Apiary.Runs.Run{
        state: "cancelled",
        reason: "released",
        released_at: ~U[2026-10-17 12:00:00Z]
      }

      assert RunComponents.reason_words(released) == "the starter released it"
      assert RunComponents.exit_note(released) == "the starter released it"

      # Its starter's outcome after it reads as any outcome does.
      assert RunComponents.reason_words(%{
               released
               | state: "failed",
                 reason: "crashed",
                 outcome_state: "failed",
                 outcome_reason: "crashed"
             }) == "crashed"
    end

    test "a run whose machine never started it reads its cause" do
      failed = %Apiary.Runs.Run{state: "failed", start_failed_at: ~U[2026-10-30 12:00:00Z]}

      released = %{
        failed
        | reason: "machine_not_made",
          start_failure: "machine_not_made",
          dispatch: %Apiary.Dispatches.Dispatch{release_reason: "No capacity in eu-1"}
      }

      assert RunComponents.reason_words(released) == "No machine was made: No capacity in eu-1."
      assert RunComponents.exit_note(released) == "No machine was made: No capacity in eu-1."

      # The reason's closing full stop gives way to the sentence's.
      assert RunComponents.reason_words(%{
               released
               | dispatch: %Apiary.Dispatches.Dispatch{release_reason: "No capacity."}
             }) == "No machine was made: No capacity."

      # Without its dispatch's reason, the run reads as one that did not start.
      assert RunComponents.reason_words(%{released | dispatch: nil}) ==
               "did not start: machine_not_made"

      assert RunComponents.reason_words(%{
               failed
               | reason: "lease_lapsed",
                 start_failure: "lease_lapsed"
             }) == "The pool did not start a machine within 10 minutes."

      assert RunComponents.reason_words(%{
               failed
               | reason: "machine_stopped",
                 start_failure: "machine_stopped"
             }) == "The machine stopped before it started the run."

      html =
        render_component(&RunComponents.end_reason/1,
          run: %{failed | reason: "lease_lapsed", start_failure: "lease_lapsed"}
        )

      assert html =~ "The pool did not start a machine within 10 minutes."
      refute html =~ "font-mono"

      # Lost with its run code never redeemed: it did not start within the code's time.
      unredeemed = %Apiary.Runs.Run{
        state: "lost",
        run_code_expires_at: ~U[2026-10-30 12:15:00Z],
        lost_at: ~U[2026-10-30 12:15:01Z]
      }

      assert RunComponents.reason_words(unredeemed) ==
               "The machine did not start the run within 15 minutes of the request."

      assert RunComponents.reason_words(%{unredeemed | run_code_public_key: <<1::256>>}) == nil

      assert RunComponents.reason_words(%{unredeemed | attached_at: ~U[2026-10-30 12:01:00Z]}) ==
               nil
    end

    test "a reason stored under its earlier name reads as the new one" do
      for {earlier, now} <- [
            {"issuer_unreachable", "credential_check_unreachable"},
            {"issuer_answer_invalid", "credential_check_invalid"}
          ],
          state <- [nil, "failed"] do
        assert RunComponents.reason_words(%{reason: earlier, state: state}) ==
                 RunComponents.reason_words(%{reason: now, state: state})
      end

      # The earlier name came with no outcome, whatever state its exit said.
      for state <- [nil, "failed", "cancelled"] do
        assert RunComponents.reason_words(%{reason: "run_ended_at_issuer", state: state}) ==
                 "stopped, no outcome given"
      end
    end

    test "a starter's code is shown as given, with spaces for underscores" do
      for {code, words} <- [
            {"no_longer_needed", "no longer needed"},
            {"checks_failed", "checks failed"},
            {"all_checks_passed", "all checks passed"},
            {"example_reason", "example reason"},
            {"done", "done"}
          ],
          state <- ["completed", "failed", "cancelled", :cancelled] do
        assert RunComponents.reason_words(%{reason: code, state: state}) == words
      end

      # A value that is no code is read as no reason.
      for value <- ["Checks failed", "checks-failed", "_x", "", String.duplicate("a", 65)] do
        assert RunComponents.reason_words(%{reason: value, state: "failed"}) == nil, value
      end
    end

    test "a run stored as refused, failed with no exit and the code as its reason, did not start" do
      refused = %Apiary.Runs.Run{state: "failed", exited_at: nil, reason: "image_unknown"}
      assert RunComponents.reason_words(refused) == "did not start: image_unknown"

      assert RunComponents.reason_words(%{refused | reason: "issuer_unreachable"}) ==
               "did not start: credential_check_unreachable"

      assert RunComponents.reason_words(%{refused | reason: nil}) == "did not start"

      # a failed run that exited reads its reason as an end
      exited = %{refused | exited_at: ~U[2026-01-01 00:00:00Z], reason: "no_longer_needed"}
      assert RunComponents.reason_words(exited) == "no longer needed"
    end

    test "a run refused at its start did not start, its code as given" do
      assert RunComponents.reason_words(%{refused: "image_unknown"}) ==
               "did not start: image_unknown"

      assert RunComponents.reason_words(%{refused: "example_server_code"}) ==
               "did not start: example_server_code"

      assert RunComponents.reason_words(%{refused: "issuer_unreachable"}) ==
               "did not start: credential_check_unreachable"

      assert RunComponents.reason_words(%{refused: "run_ended_at_issuer"}) ==
               "did not start: stopped"

      assert RunComponents.reason_words(%{refused: nil}) == "did not start"
    end

    property "no end reason's words name the issuer" do
      check all(
              code <- member_of(@reserved ++ @earlier ++ @refusals),
              state <-
                member_of(
                  [nil] ++
                    ~w(pending running completed failed cancelled lost) ++
                    [:completed, :failed, :cancelled]
                ),
              refused? <- boolean()
            ) do
        run =
          if refused?,
            do: %{refused: code},
            else: %{reason: code, state: state}

        words = RunComponents.reason_words(run)
        refute words && words =~ ~r/issuer/i, inspect({run, words})
      end
    end

    property "the run page's timeline says no issuer at a run's end or refusal" do
      t0 = ~U[2026-10-09 12:00:00Z]

      check all(
              code <- member_of(@reserved ++ @earlier ++ @refusals ++ ["example_reason"]),
              state <- member_of([nil, "succeeded", "failed", "cancelled", "other"]),
              exit_code <- member_of([nil, -1, 0, 1]),
              signal <- member_of([nil, "SIGTERM"]),
              refused? <- boolean()
            ) do
        {type, data} =
          if refused?,
            do: {"dev.qory.run.refused", %{"code" => code}},
            else:
              {"dev.qory.run.exited",
               %{
                 "state" => state,
                 "reason" => code,
                 "exit_code" => exit_code,
                 "signal" => signal,
                 "duration_ms" => 720_000
               }}

        event = %{sequence: 1, type: type, time: t0, data: data}
        light = %{sequence: 1, type: type, time: t0}
        index = Apiary.Runs.Record.Timeline.index([light])

        [item] =
          Apiary.Runs.Record.Timeline.build(index.items, %{
            1 => Apiary.Runs.Record.Timeline.slim(event)
          })

        html =
          render_component(&ApiaryWeb.RunPageComponents.timeline_item/1,
            id: "e-1",
            item: item,
            started_at: t0,
            seq_path: fn seq -> "/runs/r?seq=#{seq}" end
          )

        assert text(html) =~ if(refused?, do: "Run did not start", else: "Run ended")
        refute text(html) =~ ~r/issuer/i, inspect({type, data, text(html)})
      end
    end

    test "every reason of Forager's that reaches Qory Apiary has words" do
      for reason <- (@reserved -- ["run_closed"]) ++ @earlier do
        assert is_binary(RunComponents.reason_words(%{reason: reason})),
               reason
      end
    end

    @tag :contract
    test "every code of the contract's run.refused, and every reason it lists, has words with no issuer" do
      dir = Apiary.ContractFixtures.contract_dir()

      schema = fn file ->
        dir |> Path.join("events/#{file}.schema.json") |> File.read!() |> Jason.decode!()
      end

      refusals = get_in(schema.("run.refused"), ["then", "properties", "code", "enum"])
      assert refusals != []

      # A contract with the reasons as a list names them there; one with an open code names
      # Forager's own in its description, which @reserved holds.
      reasons = get_in(schema.("run.exited"), ["properties", "reason", "enum"]) || @reserved

      for code <- refusals do
        words = RunComponents.reason_words(%{refused: code})
        assert words =~ "did not start: " and not (words =~ "issuer"), code
      end

      for reason <- reasons -- ["run_closed", "batch_refused"] do
        words = RunComponents.reason_words(%{reason: reason})
        assert is_binary(words) and not (words =~ "issuer"), reason
      end
    end

    test "the preview says why a run ended, else its exit" do
      run = %{state: "failed", reason: nil, exit_code: 1, signal: nil}

      assert RunComponents.exit_note(run) == "exit 1"
      assert RunComponents.exit_note(%{run | reason: "checks_failed"}) == "checks failed"
      assert RunComponents.exit_note(%{run | exit_code: -1, signal: "SIGKILL"}) == "SIGKILL"
      assert RunComponents.exit_note(%{run | exit_code: -1}) == nil
      assert RunComponents.exit_note(%{run | state: "completed", exit_code: 0}) == "exit 0"

      assert RunComponents.exit_note(%{run | state: "cancelled", reason: "timeout"}) ==
               "time limit reached"

      assert RunComponents.exit_note(%{run | state: "cancelled", exit_code: 143}) == nil

      # Stopped where it was started: the words, whatever the program's exit; never its
      # exit, and never an exit 0 that reads as success.
      for {code, signal} <- [{0, nil}, {130, nil}, {130, "SIGINT"}, {-1, "SIGTERM"}] do
        interrupted = %{run | state: "cancelled", reason: "interrupted"}

        assert RunComponents.exit_note(%{interrupted | exit_code: code, signal: signal}) ==
                 "interrupted"
      end
    end

    test "a quiet running run turns amber, stops rippling and says for how long" do
      at = DateTime.add(DateTime.utc_now(), -47, :second)

      html =
        render_component(&RunComponents.run_state/1,
          state: "running",
          quiet_for: 47,
          quiet_since: at,
          interval: 30
        )

      assert html =~ "bg-primary-soft"
      refute html =~ "q-state-running"
      assert text(html) =~ ~r/^Running No heartbeat for 47 s\s*\. Heartbeats are due every 30 s\./
      assert html =~ ~s(data-tick="seconds")

      assert html =~
               "Heartbeats are due every 30 s. After 1 m 30 s of silence the run is marked lost."
    end

    test "quiet_for is the server's: over one interval, running only" do
      now = ~U[2026-09-20 14:00:00Z]

      run = %{
        state: "running",
        inserted_at: ~U[2026-09-20 13:00:00Z],
        last_heartbeat_at: ~U[2026-09-20 13:59:13Z],
        heartbeat_interval_seconds: 30
      }

      assert RunComponents.quiet_for(run, now) == 47

      assert RunComponents.quiet_for(%{run | last_heartbeat_at: ~U[2026-09-20 13:59:40Z]}, now) ==
               nil

      assert RunComponents.quiet_for(%{run | state: "lost"}, now) == nil
    end

    test "without a valid interval a run is held to 30 seconds, as the lost-run check holds it" do
      now = ~U[2026-09-20 14:00:00Z]

      run = %{
        state: "running",
        inserted_at: ~U[2026-09-20 13:00:00Z],
        last_heartbeat_at: ~U[2026-09-20 13:59:20Z],
        heartbeat_interval_seconds: nil
      }

      assert RunComponents.quiet_for(run, now) == 40

      assert RunComponents.quiet_for(%{run | last_heartbeat_at: ~U[2026-09-20 13:59:45Z]}, now) ==
               nil

      assert RunComponents.beat(%{heartbeat_interval_seconds: 0}) == 1
      assert RunComponents.beat(%{heartbeat_interval_seconds: 999_999}) == 3600

      # A run that registered is held to the interval its registration stated, before its
      # heartbeats'.
      assert RunComponents.beat(%{heartbeat_interval_seconds: nil}) == 30

      assert RunComponents.beat(%{
               heartbeat_interval_seconds: nil,
               registration_interval_seconds: 100
             }) ==
               100

      assert RunComponents.beat(%{
               heartbeat_interval_seconds: 30,
               registration_interval_seconds: 100
             }) ==
               100
    end

    test "a running run that has not beaten yet is quiet past one interval since it was first heard" do
      now = ~U[2026-09-20 14:00:00Z]

      run = %{
        state: "running",
        inserted_at: ~U[2026-09-20 13:59:00Z],
        last_heartbeat_at: nil,
        heartbeat_interval_seconds: nil
      }

      assert RunComponents.quiet_for(run, now) == 60
      assert RunComponents.quiet_for(%{run | inserted_at: ~U[2026-09-20 13:59:50Z]}, now) == nil
      assert RunComponents.heard_at(run) == ~U[2026-09-20 13:59:00Z]
    end
  end

  describe "duration, times and offsets" do
    test "formats" do
      assert RunComponents.format_duration_ms(41) == "41 ms"
      assert RunComponents.format_duration_ms(3_400, true) == "3.4 s"
      assert RunComponents.format_duration_ms(48_200) == "48 s"
      assert RunComponents.format_duration_ms(411_000) == "6 m 51 s"
      assert RunComponents.format_duration_ms(3_600_000) == "1 h 00 m"
      assert RunComponents.format_seconds(7_920) == "2 h 12 m"
    end

    test "a duration says n/a, at least, or ticks" do
      assert text(render_component(&RunComponents.duration/1, [])) == "n/a"

      assert text(render_component(&RunComponents.duration/1, at_least_seconds: 510)) =~
               ~r/^at least 8 m 30 s\. Elapsed at the last heartbeat\./

      # Forager said 120 s had elapsed; the server received that 14 s ago. Forager's own
      # started_at plays no part.
      html =
        render_component(&RunComponents.duration/1,
          elapsed_seconds: 120,
          elapsed_at: DateTime.add(DateTime.utc_now(), -14, :second),
          so_far: true
        )

      assert html =~ ~s(data-tick="duration")
      assert html =~ ~s(data-base="120")
      assert html =~ ~r/data-now="[^"]+Z"/
      assert text(html) =~ ~r/^2 m 1[45] s so far$/

      assert text(render_component(&RunComponents.duration/1, running_since: DateTime.utc_now())) ==
               "n/a"
    end

    test "the running clock counts from the last heartbeat's elapsed, or from first heard" do
      beat = ~U[2026-09-20 13:59:00Z]
      first = ~U[2026-09-20 13:50:00Z]

      assert RunComponents.elapsed(%{
               last_heartbeat_at: beat,
               elapsed_seconds: 510,
               inserted_at: first
             }) == {510, beat}

      assert RunComponents.elapsed(%{
               last_heartbeat_at: nil,
               elapsed_seconds: nil,
               inserted_at: first
             }) ==
               {0, first}
    end

    test "every ticking element carries the server's now" do
      at = DateTime.add(DateTime.utc_now(), -90, :second)

      for html <- [
            render_component(&RunComponents.relative_time/1, at: at),
            render_component(&RunComponents.relative_time/1, at: at, format: "clock"),
            render_component(&RunComponents.run_state/1,
              state: "running",
              quiet_for: 90,
              quiet_since: at
            ),
            render_component(&RunComponents.alive/1, state: "running", last_heartbeat_at: at)
          ] do
        assert html =~ ~r/data-tick="[a-z]+"/
        assert html =~ ~r/data-now="[^"]+Z"/
      end
    end

    test "every ticking element names the time zone the server rendered it in" do
      ApiaryWeb.Format.put_time_zone("America/Los_Angeles")
      at = DateTime.add(DateTime.utc_now(), -90, :second)

      for html <- [
            render_component(&RunComponents.relative_time/1, at: at),
            render_component(&RunComponents.relative_time/1, at: at, format: "clock"),
            render_component(&RunComponents.duration/1, elapsed_seconds: 30, elapsed_at: at),
            render_component(&RunComponents.run_state/1,
              state: "running",
              quiet_for: 90,
              quiet_since: at
            ),
            render_component(&RunComponents.alive/1, state: "running", last_heartbeat_at: at)
          ] do
        assert html =~ ~s(data-time-zone="America/Los_Angeles")
      end
    end

    test "every <time data-tick> the console renders names its time zone" do
      sources = Path.wildcard("lib/apiary_web/**/*.ex")
      ticking = ~r/<time\b[^>]*\bdata-tick=["{][^>]*>/s

      tags =
        for path <- sources, tag <- Regex.scan(ticking, File.read!(path)), do: {path, hd(tag)}

      assert length(tags) >= 7

      for {path, tag} <- tags do
        assert tag =~ "data-time-zone={Format.time_zone()}", "#{path}: #{tag}"
      end
    end

    test "a time names its zone in its title" do
      html =
        render_component(&RunComponents.relative_time/1,
          id: "t",
          at: ~U[2026-09-20 14:02:11Z],
          format: "clock"
        )

      assert html =~ ~s(title="20 Sept 2026, 14:02:11 UTC")
      assert html =~ ~s(datetime="2026-09-20T14:02:11Z")
    end

    test "the browser's clocks are handed the server's words, one per count" do
      words = RunComponents.clock_words()
      assert Enum.at(words.secondsAgo, 1) == "1 second ago"
      assert Enum.at(words.secondsAgo, 40) == "40 seconds ago"
      assert length(words.minutesAgo) == 60 and length(words.hoursAgo) == 25
      assert words.yesterday == "Yesterday, %{time}"
      assert words.minutesSeconds == "%{minutes} m %{seconds} s"
    end

    test "the clocks' hours cover the day summer time ends, which has 25 hours" do
      ApiaryWeb.Format.put_time_zone("Europe/Berlin")
      # 00:30 CEST to 23:45 CET on 25 October 2026: the same day, 24 hours and a quarter.
      at = ~U[2026-10-24 22:30:00Z]
      now = ~U[2026-10-25 22:45:00Z]

      assert ApiaryWeb.Format.relative(at, now) == "24 hours ago"
      assert Enum.at(RunComponents.clock_words().hoursAgo, 24) == "24 hours ago"
    end

    test "the log's script is handed its words, a count's as one and other" do
      words = ApiaryWeb.RunPageComponents.terminal_words()
      assert words.newLines == ["%{number} new line", "%{number} new lines"]
      assert words.found == "%{index} of %{total}"
    end

    test "offsets from the run's start" do
      from = ~U[2026-09-20 14:02:11.120Z]
      assert RunComponents.format_offset(~U[2026-09-20 14:02:19.250Z], from) == "+0:08.1"
      assert RunComponents.format_offset(~U[2026-09-20 15:04:19.250Z], from) == "+1:02:08"
      assert RunComponents.format_offset(~U[2026-09-20 14:02:10.000Z], from) == "before start"
    end
  end

  describe "connection_row reasons (C3)" do
    defp row(connection, variant \\ "table") do
      base = %{
        id: "c1",
        host: "files.cdn.example",
        port: 443,
        path: "",
        method: "CONNECT",
        attempts: 3,
        allowed: 0,
        denied: 3,
        last_outcome: "refused",
        last_mode: "enforce",
        first_seen_at: ~U[2026-09-20 14:02:20Z],
        last_seen_at: ~U[2026-09-20 14:02:21Z]
      }

      assigns = %{c: Map.merge(base, connection), variant: variant}

      rendered_to_string(~H"""
      <RunComponents.connection_row
        id="cx-1"
        connection={@c}
        variant={@variant}
        started_at={~U[2026-09-20 14:02:11Z]}
      />
      """)
    end

    test "denied with no rule, under enforce" do
      html = row(%{last_decision: "denied", last_rule: ""})
      assert text(html) =~ "No rule matches. Enforce mode denies it."
      assert html =~ "q-denied"
      # No mark: the denied number of the split, and its words, say it.
      refute html =~ "q-mark-no"
      assert text(html) =~ "0 allowed, 3 denied"
      assert text(html) =~ "Refused"
    end

    test "denied on a path of an allowed host" do
      html =
        row(%{
          last_decision: "denied",
          last_rule: "api.example",
          path: "/v2/models",
          last_path_rule: ""
        })

      assert text(html) =~ "Host allowed, no path rule matches. Enforce mode denies it."
    end

    test "denied by a deny entry: the rule, in either mode" do
      html = row(%{last_decision: "denied", last_rule: "tracker.example", last_mode: "observe"})
      assert text(html) =~ "Rule tracker.example"
      refute text(html) =~ "Host allowed"
      refute text(html) =~ "No rule matches"
    end

    test "the wall's own refusals, in either mode" do
      assert text(row(%{last_decision: "denied", last_rule: "wall:own-address"})) =~
               "The wall refuses link-local addresses and the machine's addresses, in either mode."

      assert text(
               row(%{
                 last_decision: "denied",
                 last_rule: "api.example",
                 last_path_rule: "wall:ambiguous-path"
               })
             ) =~ "The path can be read two ways. The wall denies it in either mode."
    end

    @host_form "Forager refuses a host that is neither a name nor an address in canonical form,"
    @own_address "The wall refuses link-local addresses and the machine's addresses,"

    defp wall_inline(host, rule \\ "wall:host-form") do
      assigns = %{
        event: %{
          host: host,
          port: 443,
          method: "CONNECT",
          decision: "denied",
          rule: rule,
          mode: "observe",
          outcome: "refused",
          at: ~U[2026-09-20 14:02:20.300Z]
        }
      }

      rendered_to_string(~H"""
      <RunComponents.connection_row id="e-hf" connection={@event} variant="inline" />
      """)
    end

    test "the wall's refusals of a host's form and of the machine's addresses, bold inline" do
      for {host, rule, bold} <- [
            {"Files.CDN.example.", "wall:host-form", @host_form},
            {"169.254.169.254", "wall:own-address", @own_address}
          ] do
        html = wall_inline(host, rule)
        why = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-why")

        assert text(LazyHTML.to_html(why)) == "Denied. #{bold} in either mode."
        assert why |> LazyHTML.query("b") |> Enum.map(&LazyHTML.text/1) == ["Denied.", bold]

        refute text(html) =~ "Rule #{rule}"
        refute text(html) =~ "No rule matches"
      end
    end

    test "the wall's refusals of a host's form and of the machine's addresses: the titles" do
      for {host, rule, bold} <- [
            {"Files.CDN.example.", "wall:host-form", @host_form},
            {"169.254.169.254", "wall:own-address", @own_address}
          ] do
        html =
          row(%{host: host, last_decision: "denied", last_rule: rule, last_mode: "enforce"})

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(".q-why-l")
               |> LazyHTML.attribute("title") == ["#{bold} in either mode."]

        assert text(html) =~ "#{bold} in either mode."
        refute text(html) =~ "Rule #{rule}"
      end
    end

    test "a host the wall refused for its form is shown marked and escaped as any host" do
      host = "<script>alert(1)</script>\u202Eexample.\u202C" <> String.duplicate("A", 300)

      marked =
        "<script>alert(1)</script>\uFFFDexample.\uFFFD" <> String.duplicate("A", 300)

      for html <- [
            wall_inline(host),
            row(%{host: host, last_decision: "denied", last_rule: "wall:host-form"})
          ] do
        refute html =~ "<script>"
        assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
        # Its bidirectional characters marked (`Apiary.ExternalText.marked/1`), its case
        # and length kept, and as text, as any host is; the reason's words stay the same.
        assert text(html) =~ marked
        refute text(html) =~ "\u202E"
        assert text(html) =~ "#{@host_form} in either mode."
      end
    end

    test "allowed by a rule, a path rule and a credential" do
      allowed = %{last_decision: "allowed", allowed: 3, denied: 0, last_outcome: "connected"}

      assert text(row(Map.merge(allowed, %{last_rule: "registry.example"}))) =~
               "Rule registry.example Connected"

      html =
        row(
          Map.merge(allowed, %{
            host: "api.example",
            method: "HTTPS",
            last_request_method: "POST",
            path: "/v1/messages",
            last_rule: "api.example",
            last_path_rule: "/v1/*",
            last_credential: "model-key"
          })
        )

      assert text(html) =~ "Rule api.example, path /v1/*, secret model-key"
      assert html =~ ~s(title="Rule api.example, path /v1/*, secret model-key")
      assert text(html) =~ "api.example:443 POST /v1/messages"
      refute html =~ "q-mark-ok"
      refute html =~ "q-denied"
    end

    test "allowed with no rule, under observe" do
      html =
        row(%{
          last_decision: "allowed",
          last_rule: "",
          last_mode: "observe",
          last_outcome: "connected"
        })

      assert text(html) =~ "No rule matches. Observe mode lets it through."
    end

    test "a connection whose event named no mode does not name one" do
      assert text(row(%{last_decision: "denied", last_rule: "", last_mode: nil})) =~
               "No rule matches. The policy denies it."
    end

    test "an allowed connection closed by a new policy, and a failed dial" do
      html =
        row(%{last_decision: "allowed", last_rule: "registry.example", last_outcome: "refused"})

      assert text(html) =~ "Rule registry.example Closed when a new policy denied the host."

      html =
        row(%{
          last_decision: "allowed",
          last_rule: "*.internal.example",
          last_outcome: "dial_failed"
        })

      assert text(html) =~ "Rule *.internal.example Dial failed"
      assert html =~ "q-outcome-dial"
    end

    test "the inline variant leads with the decision and reads one egress event" do
      event = %{
        host: "files.cdn.example",
        port: 443,
        method: "CONNECT",
        decision: "denied",
        rule: "",
        mode: "enforce",
        outcome: "refused",
        at: ~U[2026-09-20 14:02:20.300Z]
      }

      assigns = %{event: event}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row
          id="e-19"
          connection={@event}
          variant="inline"
          started_at={~U[2026-09-20 14:02:11Z]}
        />
        """)

      assert text(html) =~ "Denied. No rule matches. Enforce mode denies it."
      assert text(html) =~ "+0:09.3"
      assert html =~ "q-cx-denied"

      allowed = %{event | decision: "allowed", rule: "registry.example", outcome: "connected"}
      assigns = %{event: allowed}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-20" connection={@event} variant="inline" />
        """)

      assert text(html) =~ "Allowed by rule registry.example"
    end

    test "the workspace variant marks a mixed destination's reason as the last attempt's" do
      html =
        row(
          %{
            last_decision: "allowed",
            last_rule: "registry.example",
            last_outcome: "connected",
            allowed: 65,
            denied: 8,
            attempts: 73,
            runs: 6
          },
          "workspace"
        )

      # A thin split and its numbers, the words for a screen reader; no mark, no tint.
      assert text(html) =~ "65/8 65 allowed, 8 denied"
      assert html =~ ~s(title="65 allowed, 8 denied")
      refute html =~ "q-mark"
      assert text(html) =~ "Rule registry.example · last attempt"

      # The reason is one line, whole in its title, and folds under the destination.
      assert html =~ ~s(title="Rule registry.example · last attempt")
      assert html =~ ~s(class="q-cx-fold")
      assert html =~ ~s(aria-expanded="false")
      assert html =~ "width:89%"
    end

    test "a tool invocation reads as a call to the tool: its name, the request, then the host" do
      invocation = %{
        host: "files.tools.internal",
        method: "HTTPS",
        last_request_method: "PUT",
        path: "/media/acme/shop/checkout.png",
        last_decision: "allowed",
        last_rule: "files.tools.internal",
        last_path_rule: "/media/acme/shop/*",
        last_tool: "files",
        last_status: 200,
        last_outcome: "connected",
        allowed: 3,
        denied: 0,
        runs: 2
      }

      for variant <- ~w(table workspace) do
        html = row(invocation, variant)
        [dest] = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-dest") |> Enum.to_list()

        assert LazyHTML.query(dest, ".hero-wrench-screwdriver-micro") |> Enum.count() == 1

        assert text(LazyHTML.to_html(dest)) =~
                 ~r/^Tool files PUT \/media\/acme\/shop\/checkout.png files.tools.internal:443$/

        assert text(html) =~
                 "Handed to files by rule files.tools.internal, path /media/acme/shop/*"

        assert text(html) =~ "Answered 200"
        refute text(html) =~ "Connected"

        # Neither a run's row nor the workspace's has a decision's mark.
        refute html =~ "q-mark-ok"
      end

      # A tool that answered with an error is told apart; one with no path rule says none.
      html = row(%{invocation | last_status: 502, last_path_rule: nil})
      assert text(html) =~ "Handed to files by rule files.tools.internal Answered 502"
      assert html =~ "q-outcome-error"

      # No answer recorded: handed over, not connected.
      assert text(row(%{invocation | last_status: nil})) =~ "Handed over"

      # Under observe with no rule, the mode lets it through and the tool still has it,
      # with the path rule when one matched, and without one when none did.
      observe = Map.merge(invocation, %{last_rule: "", last_mode: "observe"})

      assert text(row(observe)) =~
               "No rule matches. Observe mode lets it through. Handed to files, path /media/acme/shop/*"

      assert text(row(%{observe | last_path_rule: ""})) =~
               ~r/No rule matches\. Observe mode lets it through\. Handed to files Answered 200/

      # The tool that is gone is a failed dial: the request was for the tool, never handed.
      html = row(%{invocation | last_outcome: "dial_failed", last_status: nil})

      assert text(html) =~
               "For files by rule files.tools.internal, path /media/acme/shop/* Dial failed"

      refute text(html) =~ "Handed"

      # Closed by a reload: for the tool, and closed.
      html = row(%{invocation | last_outcome: "refused", last_status: nil, last_path_rule: ""})

      assert text(html) =~
               "For files by rule files.tools.internal Closed when a new policy denied the host."

      # No rule at all, no path rule, no answer: still for the tool.
      assert text(
               row(
                 Map.merge(invocation, %{
                   last_rule: "",
                   last_path_rule: "",
                   last_mode: nil,
                   last_outcome: "dial_failed",
                   last_status: nil
                 })
               )
             ) =~ "No rule matches. It was let through. For files Dial failed"
    end

    test "a request a path rule refused is no tool invocation: it reads as any denial" do
      refused = %{
        host: "files.tools.internal",
        method: "HTTPS",
        last_request_method: "GET",
        path: "/media/acme/other/checkout.png",
        last_decision: "denied",
        last_rule: "files.tools.internal",
        last_path_rule: "",
        last_tool: "files",
        last_mode: "enforce",
        last_outcome: "refused",
        allowed: 0,
        denied: 1,
        runs: 1
      }

      for variant <- ~w(table workspace) do
        html = row(refused, variant)
        [dest] = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-dest") |> Enum.to_list()

        # The host leads, as for any denial; no wrench, no q-dest-tool. A run's row names
        # the request; the workspace's title is the host, the port and the path.
        assert text(LazyHTML.to_html(dest)) =~
                 if(variant == "table",
                   do: ~r/^files.tools.internal:443 GET \/media\/acme\/other\/checkout.png$/,
                   else: ~r/^files.tools.internal:443 \/media\/acme\/other\/checkout.png$/
                 )

        refute html =~ "q-dest-tool"
        refute html =~ "hero-wrench-screwdriver-micro"

        assert text(html) =~
                 "Host allowed, no path rule matches. Enforce mode denies it. Refused before reaching the tool files."

        refute text(html) =~ "Handed to"
        refute text(html) =~ "For files"
        assert text(html) =~ "Refused"
      end

      # The same request read from its event, inline on the timeline.
      event = %{
        sequence: 6,
        host: "files.tools.internal",
        port: 443,
        method: "HTTPS",
        request_method: "GET",
        path: "/media/acme/other/checkout.png",
        decision: "denied",
        rule: "files.tools.internal",
        path_rule: "",
        mode: "enforce",
        outcome: "refused",
        tool: "files",
        at: ~U[2026-09-20 14:02:20.300Z]
      }

      assigns = %{event: event}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-6" connection={@event} variant="inline" />
        """)

      refute html =~ "q-dest-tool"
      assert text(html) =~ ~r/^Denied files.tools.internal:443 GET/
      assert text(html) =~ "Refused before reaching the tool files."

      # The same request allowed is a tool invocation, and a call to the tool.
      assigns = %{
        event:
          Map.merge(event, %{
            decision: "allowed",
            path_rule: "/media/acme/*",
            outcome: "connected",
            status: 200
          })
      }

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-7" connection={@event} variant="inline" />
        """)

      assert html =~ "q-dest-tool"
      assert text(html) =~ "Handed to files by rule files.tools.internal, path /media/acme/*"
      refute text(html) =~ "Refused before"
    end

    test "a plain host's answer shows beside Connected, and one request names its id inline" do
      event = %{
        sequence: 5,
        host: "api.example.com",
        port: 443,
        method: "HTTPS",
        request_method: "POST",
        path: "/v1/messages",
        decision: "allowed",
        rule: "api.example.com",
        path_rule: "/v1/*",
        mode: "enforce",
        outcome: "connected",
        status: 429,
        request_id: "1f2e3d4c5b6a79880a9b8c7d6e5f4a3b",
        at: ~U[2026-09-20 14:02:20.300Z]
      }

      assigns = %{event: event}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-5" connection={@event} variant="inline" />
        """)

      assert [outcome] =
               html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-outcome") |> Enum.to_list()

      assert outcome |> LazyHTML.query(".q-status") |> LazyHTML.text() == "429"
      assert text(LazyHTML.to_html(outcome)) =~ ~r/^Connected\s?429$/

      assert html =~ "q-outcome-error"
      assert html =~ ~s(data-request-id="1f2e3d4c5b6a79880a9b8c7d6e5f4a3b")
      assert html =~ "request 1f2e3d4c5b6a79880a9b8c7d6e5f4a3b"

      assigns = %{event: Map.merge(event, %{tool: "files", host: "files.tools.internal"})}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-6" connection={@event} variant="inline" />
        """)

      assert text(html) =~ "Handed to files by rule api.example.com, path /v1/*"
      assert text(html) =~ "Answered 429"
    end

    test "event data is escaped" do
      html =
        row(%{last_decision: "allowed", last_rule: "<script>alert(1)</script>", host: "<b>x</b>"})

      refute html =~ "<script>"
      refute html =~ "<b>x</b>"

      html = row(%{last_decision: "allowed", last_rule: "r", last_tool: "<i>files</i>"})
      refute html =~ "<i>files</i>"
    end
  end

  describe "a row with an after line says its reason in the past tense" do
    @line %{
      action: :allow,
      level: :workspace,
      version: nil,
      by: nil,
      at: nil,
      state: :pending,
      reloaded_at: nil
    }

    defp act_row(connection, variant, line) do
      base = %{
        id: "c1",
        host: "files.cdn.example",
        port: 443,
        path: "",
        method: "CONNECT",
        attempts: 3,
        allowed: 0,
        denied: 3,
        runs: 1,
        last_decision: "denied",
        last_rule: "",
        last_outcome: "refused",
        last_mode: "enforce",
        first_seen_at: ~U[2026-09-20 14:02:20Z],
        last_seen_at: ~U[2026-09-20 14:02:21Z]
      }

      act = %{rule_option: {:rule_added, :allow}, after: line}
      assigns = %{c: Map.merge(base, connection), variant: variant, act: act}

      rendered_to_string(~H"""
      <RunComponents.connection_row id="cx-1" connection={@c} variant={@variant} act={@act} />
      """)
      |> LazyHTML.from_fragment()
    end

    # The Reason cell, the fold under the destination, the cell's title and its bold lead.
    defp why(doc) do
      cell = LazyHTML.query(doc, ".q-why-l")

      %{
        cell: text(LazyHTML.to_html(cell)),
        fold: text(LazyHTML.to_html(LazyHTML.query(doc, ".q-cx-fold"))),
        title: cell |> LazyHTML.attribute("title") |> List.first(),
        bold: cell |> LazyHTML.query("b") |> LazyHTML.text()
      }
    end

    test "with Rule added and with In force in this run, on both tables" do
      past = "No rule matched. Enforce mode denied it."

      for variant <- ~w(table workspace), state <- [:pending, :in_force] do
        doc = act_row(%{}, variant, %{@line | state: state})

        assert text(LazyHTML.to_html(LazyHTML.query(doc, "#cx-1-after .badge"))) ==
                 if(state == :in_force, do: "In force in this run", else: "Rule added")

        assert why(doc) == %{cell: past, fold: past, title: past, bold: "No rule matched."}
        refute text(LazyHTML.to_html(doc)) =~ "No rule matches"
      end
    end

    test "every sentence of a reason with no rule, and what follows it unchanged" do
      for variant <- ~w(table workspace) do
        assert why(act_row(%{last_mode: nil}, variant, @line)).title ==
                 "No rule matched. The policy denied it."

        no_path = %{last_rule: "api.example", path: "/v2/models", last_path_rule: ""}

        assert why(act_row(no_path, variant, @line)) == %{
                 cell: "Host allowed, no path rule matched. Enforce mode denied it.",
                 fold: "Host allowed, no path rule matched. Enforce mode denied it.",
                 title: "Host allowed, no path rule matched. Enforce mode denied it.",
                 bold: "Host allowed, no path rule matched."
               }

        assert why(act_row(%{last_mode: nil} |> Map.merge(no_path), variant, @line)).title ==
                 "Host allowed, no path rule matched. The policy denied it."

        observed = %{
          last_decision: "allowed",
          last_mode: "observe",
          last_outcome: "connected",
          allowed: 3,
          denied: 0
        }

        assert why(act_row(observed, variant, @line)) == %{
                 cell: "No rule matched. Observe mode let it through.",
                 fold: "No rule matched. Observe mode let it through.",
                 title: "No rule matched. Observe mode let it through.",
                 bold: "No rule matched."
               }

        assert why(act_row(%{observed | last_mode: nil}, variant, @line)).cell ==
                 "No rule matched. It was let through."

        # A tool's row keeps its tail after the lead.
        tool =
          Map.merge(observed, %{
            host: "files.tools.internal",
            method: "HTTPS",
            path: "/media/acme/shop/checkout.png",
            last_path_rule: "/media/acme/shop/*",
            last_tool: "files"
          })

        handed =
          "No rule matched. Observe mode let it through. Handed to files, path /media/acme/shop/*"

        assert why(act_row(tool, variant, @line)).title == handed
        assert why(act_row(tool, variant, @line)).cell == handed

        assert why(act_row(%{tool | last_mode: nil, last_outcome: "dial_failed"}, variant, @line)).title ==
                 "No rule matched. It was let through. For files, path /media/acme/shop/*"

        # A denied request to a tool's host still says it never reached the tool.
        assert why(act_row(Map.put(no_path, :last_tool, "files"), variant, @line)).title ==
                 "Host allowed, no path rule matched. Enforce mode denied it. Refused before reaching the tool files."
      end

      # The workspace's title of a mixed destination keeps the last attempt.
      mixed = act_row(%{allowed: 2, denied: 3, attempts: 5}, "workspace", @line)
      assert why(mixed).title == "No rule matched. Enforce mode denied it. · last attempt"
    end

    test "a row without an after line, and the timeline's row, keep the present tense" do
      for variant <- ~w(table workspace) do
        doc = act_row(%{}, variant, nil)
        refute LazyHTML.query(doc, "#cx-1-after") |> Enum.any?()
        present = "No rule matches. Enforce mode denies it."

        assert why(doc) == %{
                 cell: present,
                 fold: present,
                 title: present,
                 bold: "No rule matches."
               }
      end

      event = %{
        host: "files.cdn.example",
        port: 443,
        method: "CONNECT",
        decision: "denied",
        rule: "",
        mode: "enforce",
        outcome: "refused",
        at: ~U[2026-09-20 14:02:20.300Z]
      }

      assigns = %{event: event}

      html =
        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-5" connection={@event} variant="inline" />
        """)

      assert text(html) =~ "Denied. No rule matches. Enforce mode denies it."
      refute text(html) =~ "matched"
    end
  end

  describe "the Outcome column's tooltip" do
    test "says what a refusal is, in a run's table and in a workspace's" do
      for variant <- ~w(table workspace) do
        doc =
          render_component(&RunComponents.connections_table/1,
            id: "cx",
            label: "Connections",
            rows: [],
            variant: variant
          )
          |> LazyHTML.from_fragment()

        [tip] = doc |> LazyHTML.query("th abbr.term") |> LazyHTML.attribute("data-tip")

        assert tip =~ "Dial failed: allowed, but the host or the tool did not answer."

        assert String.ends_with?(
                 tip,
                 " Refused: the policy or the wall denied it, or a new policy closed it."
               )

        refute tip =~ "never dialled"
      end
    end
  end

  describe "controls" do
    test "a toggle and a segment are buttons that patch, so Space works" do
      html =
        render_component(&RunComponents.filter_toggle/1,
          name: "denials",
          label: "Has denials",
          pressed: true,
          patch: "/acme/main/runs"
        )

      assert html =~ ~r/<button[^>]*type="button"[^>]*aria-pressed="true"/
      refute html =~ "role=\"button\""
      assert html =~ "/acme/main/runs"
    end
  end

  describe "filter_options/1's tile" do
    @options [{"Lea", "Lea", 2}, {"deps-bot", "deps-bot", 1}]

    defp options_html(assigns) do
      rendered_to_string(~H"""
      <RunComponents.filter_options
        id="f"
        name="filed_by"
        label="Filed by"
        values={[]}
        options={@options}
        multiple
      >
        <:tile :let={{_label, value, _count}}>
          <span :if={value == "deps-bot"} class="tile">{String.first(value)}</span>
        </:tile>
      </RunComponents.filter_options>
      """)
    end

    test "draws the slot before each option's words, given the option" do
      html = options_html(%{options: @options})
      doc = LazyHTML.from_fragment(html)
      [lea, bot] = doc |> LazyHTML.query(".q-filter-option") |> Enum.to_list()

      assert lea |> LazyHTML.query(".tile") |> Enum.count() == 0
      assert bot |> LazyHTML.query(".tile") |> LazyHTML.text() == "d"
      assert text(LazyHTML.to_html(bot)) == "d deps-bot 1"
      # The tile comes after the box and before the words.
      assert LazyHTML.to_html(bot) =~
               ~r/<input[^>]*value="deps-bot"[^>]*\/?>\s*<span[^>]*class="tile">d<\/span>\s*<span[^>]*title="deps-bot"/
    end

    test "without the slot, an option is its box, its words and its count alone" do
      html =
        render_component(&RunComponents.filter_options/1,
          id: "f",
          name: "filed_by",
          label: "Filed by",
          values: [],
          options: @options,
          multiple: true
        )

      [_lea, bot] =
        html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-filter-option") |> Enum.to_list()

      assert bot |> LazyHTML.query("label > *") |> Enum.map(&LazyHTML.tag/1) ==
               [["input"], ["span"], ["span"]]

      refute html =~ "tile"
    end
  end

  describe "a target's name and a filter's options, as a page shows an external system's text" do
    # A bidirectional override and a zero-width space, which a target's labels may carry.
    @system "git\u202E.example\u200B"
    @path "acme/\u202Eshop\u200B"

    defp target_doc(attrs),
      do: render_component(&RunComponents.target_name/1, attrs) |> LazyHTML.from_fragment()

    test "a target's system and path are cleaned; the path as sent decides the system" do
      doc = target_doc(system: @system, path: @path, shared: MapSet.new([@path]))
      assert LazyHTML.text(doc) == "git.example/acme/shop"
      assert attr_of(doc, ".q-tname", "title") == ["git.example/acme/shop"]

      alone = target_doc(system: @system, path: @path, shared: MapSet.new(["acme/shop"]))
      assert LazyHTML.text(alone) == "acme/shop"

      blank = target_doc(system: "\u200B", path: "\u202E", shared: true)
      assert LazyHTML.text(blank) == "\uFFFD/\uFFFD"

      assert RunComponents.shown_target_label(@system, @path, MapSet.new([@path])) ==
               "git.example/acme/shop"

      assert RunComponents.shown_target_label(@system, @path, MapSet.new(["acme/shop"])) ==
               "acme/shop"

      assert RunComponents.shown_target_label(nil, "\u200B", true) == "\uFFFD"
    end

    test "an option's words are cleaned and isolated; what it picks is the value as sent" do
      doc =
        render_component(&RunComponents.filter_options/1,
          id: "f",
          name: "host",
          label: "Host",
          values: [@path],
          options: [{@path, @path, 2}, {"\u200B", "\u200B", 1}]
        )
        |> LazyHTML.from_fragment()

      assert texts(doc, ".q-filter-option > span > bdi") == ["acme/shop", "\uFFFD"]
      assert attr_of(doc, ".q-filter-option > span[title]", "title") == ["acme/shop", "\uFFFD"]
      assert attr_of(doc, ".q-filter-option input", "value") == [@path, "\u200B"]

      chip =
        render_component(&RunComponents.filter/1,
          name: "host",
          label: "Host",
          value: @path,
          options: [{@path, @path, 2}]
        )
        |> LazyHTML.from_fragment()

      assert texts(chip, ".q-chip-main > b") == ["acme/shop"]
    end
  end

  describe "filter_options/1's narrowing box" do
    defp narrowing(attrs) do
      assigns =
        Keyword.merge(
          [id: "f", name: "filed_by", label: "Filed by", values: [], multiple: true],
          attrs
        )

      render_component(&RunComponents.filter_options/1, assigns)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("form#f-narrow input#f-search")
      |> Enum.count()
    end

    test "without always_find, is drawn above eight options or for a search alone" do
      few = for n <- 1..2, do: {"Filer #{n}", "Filer #{n}", 1}
      many = for n <- 1..9, do: {"Filer #{n}", "Filer #{n}", 1}

      assert narrowing(options: few) == 0
      assert narrowing(options: Enum.take(many, 8)) == 0
      assert narrowing(options: many) == 1
      assert narrowing(options: few, query: "Fil") == 1
      assert narrowing(options: few, total: 9) == 1
      assert narrowing(options: few, always_find: false) == 0
    end

    test "always_find draws it whatever the number of options, none among them" do
      assert narrowing(options: [], always_find: true) == 1
      assert narrowing(options: [{"Lea", "Lea", 2}], always_find: true) == 1
    end
  end

  describe "chips" do
    test "a long label value is cut in the middle, the whole value in the title" do
      value = String.duplicate("a", 20) <> String.duplicate("z", 20)
      html = render_component(&RunComponents.label_chip/1, key: "branch", value: value)
      assert html =~ "…"
      assert html =~ ~s(title="#{value}")
      assert RunComponents.middle(value, 32) |> String.length() == 32
    end

    test "labels come with the target's first, by the workspace's domain, then by name" do
      labels = %{"zone" => "1", "task" => "t", "forge" => "f", "repository" => "r"}

      assert RunComponents.ordered_labels(labels, nil) ==
               [{"forge", "f"}, {"repository", "r"}, {"task", "t"}, {"zone", "1"}]

      # A task is an ordinary label, sorted with the rest.
      assert RunComponents.ordered_labels(%{"a" => "1", "task" => "t", "forge" => "f"}, nil) ==
               [{"forge", "f"}, {"a", "1"}, {"task", "t"}]
    end
  end

  describe "a run's title and what it is about" do
    @public_id "rn_7f3e9b205b1d4c7e"

    test "the title is the one the run gave, else Run and its short id" do
      titled = %{public_id: @public_id, about_title: "Fix the login redirect"}
      assert RunComponents.run_title(titled) == "Fix the login redirect"
      assert RunComponents.given_title(titled) == "Fix the login redirect"

      for untitled <- [
            %{public_id: @public_id, about_title: nil},
            %{public_id: @public_id, about_title: ""},
            # A task is an ordinary label, never the title.
            %{public_id: @public_id, about_title: nil, labels: %{"task" => "fix-login"}}
          ] do
        assert RunComponents.run_title(untitled) == "Run rn_7f3e9b20"
        assert RunComponents.given_title(untitled) == nil
      end
    end

    test "the about line: the kind, two subjects as text, then how many more" do
      subjects =
        for {type, ref} <- [{"pull request", "#418"}, {"ticket", "ENG-21"}, {"incident", "INC-5"}],
            do: %{"type" => type, "ref" => ref, "url" => "https://example.com/#{ref}"}

      run = %{about_kind: "Review", about_subjects: subjects}

      assert RunComponents.about_line(run) ==
               "Review · pull request #418 · ticket ENG-21 · +1 more"

      assert RunComponents.about_line(run, 1) == "Review · pull request #418 · +2 more"

      assert RunComponents.about_line(%{run | about_subjects: Enum.take(subjects, 2)}) ==
               "Review · pull request #418 · ticket ENG-21"

      assert RunComponents.about_line(%{about_kind: "Demo recording", about_subjects: []}) ==
               "Demo recording"

      assert RunComponents.about_line(%{about_kind: nil, about_subjects: [hd(subjects)]}) ==
               "pull request #418"

      assert RunComponents.about_line(%{about_kind: nil, about_subjects: []}) == nil
      assert RunComponents.about_line(%{about_kind: "", about_subjects: []}) == nil
    end

    # A bidirectional override, a zero-width space and a control character: what a run
    # sent, as a page shows it (`Apiary.ExternalText.line/1`).
    @sent "Fix\u202E the\u200B login\a"
    @shown "Fix the login\uFFFD"

    defp bdis(html),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query("bdi") |> Enum.map(&LazyHTML.text/1)

    test "the title as a page shows it, isolated in a row; one with nothing left is none" do
      run = %{public_id: @public_id, about_title: @sent}
      assert RunComponents.given_title(run) == @sent
      assert RunComponents.shown_run_title(run) == @shown
      assert RunComponents.run_title(run) == @shown
      assert bdis(render_component(&RunComponents.run_name/1, run: run)) == [@shown]

      blank = %{run | about_title: "\u202E\u200B"}
      assert RunComponents.given_title(blank) == "\u202E\u200B"
      assert RunComponents.shown_run_title(blank) == nil
      assert RunComponents.run_title(blank) == "Run rn_7f3e9b20"
      assert RunComponents.shown_run_title(%{run | about_title: " \u200B "}) == nil

      html = render_component(&RunComponents.run_name/1, run: blank)
      assert bdis(html) == []
      assert text(html) == "rn_7f3e9b20"
    end

    test "the about line, a subject's words, its tooltip and its markup as a page shows them" do
      subject = %{
        "type" => "pull\u200B request",
        "ref" => "#41\u202E8\a",
        "url" => "https://git.example.com/acme/shop/pull/418",
        "title" => @sent
      }

      run = %{about_kind: "Re\u202Eview\a", about_subjects: [subject]}

      assert RunComponents.about_line(run) == "Review\uFFFD · pull request #418\uFFFD"
      assert RunComponents.about_line(%{about_kind: "\u200B", about_subjects: []}) == nil
      assert RunComponents.subject_words(subject) == "pull request #418\uFFFD"
      assert RunComponents.subject_tip(subject) == @shown <> " · git.example.com"
      assert RunComponents.subject_tip(%{subject | "title" => "\u200B"}) == "git.example.com"
      assert RunComponents.subject_tip(%{subject | "title" => " \u200B "}) == "git.example.com"

      assert bdis(render_component(&RunComponents.subject_name/1, subject: subject)) ==
               ["pull request", "#418\uFFFD"]
    end

    test "a label chip: its key and value as a page shows them, the value in its title" do
      html =
        render_component(&RunComponents.label_chip/1, key: "zo\u200Bne\a", value: @sent)

      assert bdis(html) == ["zone\uFFFD", @shown]

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".q-label")
             |> LazyHTML.attribute("title") ==
               [@shown]
    end

    test "a signal as a page shows it; one with nothing left reads as the exit code" do
      badge = fn assigns -> text(render_component(&RunComponents.run_state/1, assigns)) end
      failed = [state: "failed", exit_code: 137]
      assert badge.(failed ++ [signal: "SIG\u202EKILL\a"]) == "Failed SIGKILL\uFFFD"
      assert badge.(failed ++ [signal: "\u202E\u200B"]) == "Failed exit 137"
      assert badge.(failed ++ [signal: " \u200B "]) == "Failed exit 137"

      run = %{state: "failed", reason: nil, exit_code: 137}
      signalled = Map.put(run, :signal, "SIG\u202EKILL\a")
      blank = Map.put(run, :signal, "\u202E\u200B")
      assert RunComponents.exit_note(signalled) == "SIGKILL\uFFFD"
      assert RunComponents.exit_note(blank) == "exit 137"
      assert RunComponents.shown_signal(blank) == nil

      differs = %{
        outcome_state: "succeeded",
        state: "completed",
        exit_state: "failed",
        exited_at: DateTime.utc_now(),
        exit_code: 137,
        signal: "\u202E\u200B"
      }

      assert RunComponents.outcome_sentence(differs) ==
               "Succeeded, as its starter said; the runtime exited 137"

      assert RunComponents.outcome_sentence(%{differs | signal: "SIG\u202EKILL\a"}) ==
               "Succeeded, as its starter said; the runtime ended with SIGKILL\uFFFD"
    end

    test "the pill hides at zero and counts in words" do
      html = render_component(&RunComponents.new_items/1, id: "pill", count: 0, target: "#main")
      refute html =~ "q-newpill-show"

      html = render_component(&RunComponents.new_items/1, id: "pill", count: 3, target: "#main")
      assert html =~ "q-newpill-show"
      assert text(html) == "3 new events"

      assert text(
               render_component(&RunComponents.new_items/1,
                 id: "pill",
                 count: 1,
                 noun: "line",
                 target: "#t"
               )
             ) == "1 new line"
    end
  end

  describe "rule_actions" do
    defp acts(act) do
      render_component(
        &RunComponents.rule_actions/1,
        Map.merge(
          %{id: "r", connection: %{host: "api.example.com"}, controls: "r-panel", values: %{}},
          act
        )
      )
      |> LazyHTML.from_fragment()
    end

    defp attr_of(doc, selector, name),
      do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

    # The two slots, in order: a control's id, or :gap for the empty one.
    defp slots(doc) do
      doc
      |> LazyHTML.query(".q-acts-pair > *")
      |> Enum.map(fn node ->
        case LazyHTML.attribute(node, "id") do
          [id] -> id
          [] -> :gap
        end
      end)
    end

    test "both icons where no rule decides the host, each with a hint and the host in its name" do
      doc = acts(%{rule_option: :can_allow, deny: true})

      assert slots(doc) == ["r-allow", "r-deny"]
      assert attr_of(doc, "button#r-allow", "aria-label") == ["Allow api.example.com"]
      assert attr_of(doc, "button#r-allow", "data-tip") == ["Allow api.example.com"]
      assert attr_of(doc, "button#r-deny", "aria-label") == ["Deny api.example.com"]
      assert attr_of(doc, "button#r-deny", "data-tip") == ["Deny api.example.com"]
      assert attr_of(doc, "button#r-allow.tooltip.q-act-i", "data-action") == ["allow"]
      assert attr_of(doc, "button#r-deny.tooltip.q-act-i", "data-action") == ["deny"]
      assert attr_of(doc, "button", "aria-controls") == ["r-panel", "r-panel"]
      assert attr_of(doc, "button", "aria-expanded") == ["false", "false"]
      refute LazyHTML.query(doc, "[disabled]") |> Enum.any?()
    end

    test "only the act that changes something, the other slot an empty gap" do
      # A deny rule decides it: Allow alone.
      assert slots(acts(%{rule_option: :can_allow, deny: false})) == ["r-allow", :gap]
      # Allowed: Deny alone, in the second slot.
      doc = acts(%{rule_option: :can_deny})
      assert slots(doc) == [:gap, "r-deny"]
      assert attr_of(doc, ".q-act-gap", "aria-hidden") == ["true"]
    end

    test "each icon says whether its own panel is open" do
      doc = acts(%{rule_option: :can_allow, deny: true, expanded: true, expanded_action: :deny})
      assert attr_of(doc, "#r-allow", "aria-expanded") == ["false"]
      assert attr_of(doc, "#r-deny", "aria-expanded") == ["true"]

      doc = acts(%{rule_option: :can_allow, deny: true, expanded: true, expanded_action: :allow})
      assert attr_of(doc, "#r-allow", "aria-expanded") == ["true"]
      assert attr_of(doc, "#r-deny", "aria-expanded") == ["false"]
    end

    test "the wall and the level above are a lock the keyboard reaches, its hint why" do
      doc = acts(%{rule_option: :wall})
      assert slots(doc) == ["r-lock", :gap]
      assert attr_of(doc, "span#r-lock.q-act-lock.tooltip", "tabindex") == ["0"]
      assert attr_of(doc, "#r-lock", "data-tip") == ["No rule changes this"]

      assert attr_of(doc, "span#r-lock[role=img]", "aria-label") == ["No rule changes this"]

      doc =
        acts(%{
          rule_option: :above_deny,
          entry_host: "api.example.com",
          above: %{name: "Main", action: :deny}
        })

      assert slots(doc) == ["r-lock", :gap]
      assert attr_of(doc, "span#r-lock", "tabindex") == ["0"]

      assert attr_of(doc, "#r-lock", "data-tip") == [
               "Main's policy denies api.example.com. No workspace or repository rule can allow it."
             ]

      refute LazyHTML.query(doc, "button") |> Enum.any?()
    end

    test "only the level above allows a host: Allow leads there, else a lock" do
      elsewhere = %{rule_option: :can_allow, deny: true, allow_elsewhere: %{name: "Main"}}

      doc = acts(Map.put(elsewhere, :allow_path, "/main/policy/rules/new?host=api.example.com"))
      assert slots(doc) == ["r-allow", "r-deny"]
      assert attr_of(doc, "#r-allow", "data-tip") == ["Allow api.example.com in Main's policy"]
      assert attr_of(doc, "#r-allow", "aria-label") == ["Allow api.example.com in Main's policy"]

      doc = acts(elsewhere)
      assert slots(doc) == ["r-lock", "r-deny"]
      assert attr_of(doc, "span#r-lock", "data-tip") == ["Only Main's policy allows a host here"]
    end

    test "a locked rule is a lock button whose hint names who locked it and when" do
      doc =
        acts(%{
          rule_option: :locked_deny,
          entry_host: "*.example.com",
          locked: %{by: "owner@acme.example", at: ~U[2026-10-07 09:00:00Z]}
        })

      assert slots(doc) == ["r-lock", :gap]
      [tip] = attr_of(doc, "button#r-lock.q-act-lock", "data-tip")

      assert tip =~
               "A locked workspace rule denies *.example.com. Locked by owner@acme.example on "

      assert attr_of(doc, "button#r-lock", "aria-label") == [tip]
      assert attr_of(doc, "button#r-lock", "aria-controls") == ["r-panel"]

      # Who locked it is said only where it is known.
      doc = acts(%{rule_option: :locked_allow, entry_host: "api.example.com"})

      assert attr_of(doc, "button#r-lock", "data-tip") == [
               "A locked workspace rule allows api.example.com."
             ]
    end

    test "the wall's lock says why by the wall's reason; any other reason, that no rule changes it" do
      for {connection, tip} <- [
            {%{rule: "wall:own-address"},
             "The wall refused this, not a rule. A rule naming this exact host opens the machine's addresses to it; link-local addresses never open."},
            {%{rule: "wall:host-form"},
             "The wall refused this, not a rule: no rule can name a host written this way."},
            {%{rule: "api.example.com", path_rule: "wall:ambiguous-path"},
             "The wall refused this, not a rule: the request's path reads two ways. A request with a plain path gets through."},
            # As a row of the workspace's page names them.
            {%{last_rule: "wall:own-address"},
             "The wall refused this, not a rule. A rule naming this exact host opens the machine's addresses to it; link-local addresses never open."},
            {%{last_rule: "", last_path_rule: "wall:ambiguous-path"},
             "The wall refused this, not a rule: the request's path reads two ways. A request with a plain path gets through."},
            {%{rule: "wall:another-reason"}, "No rule changes this"}
          ] do
        doc =
          acts(%{rule_option: :wall, connection: Map.put(connection, :host, "api.example.com")})

        assert slots(doc) == ["r-lock", :gap]
        assert attr_of(doc, "span#r-lock.q-act-lock.tooltip", "tabindex") == ["0"]
        assert attr_of(doc, "#r-lock", "data-tip") == [tip]
        assert attr_of(doc, "span#r-lock[role=img]", "aria-label") == [tip]
      end
    end

    test "a host no rule can name is a lock the keyboard reaches, its hint why; a rule just added, nothing" do
      doc = acts(%{rule_option: :unnameable})
      assert slots(doc) == ["r-lock", :gap]
      assert attr_of(doc, "span#r-lock.q-act-lock.tooltip", "tabindex") == ["0"]
      assert attr_of(doc, "#r-lock", "data-tip") == ["No rule can name this host."]

      assert attr_of(doc, "span#r-lock[role=img]", "aria-label") == [
               "No rule can name this host."
             ]

      refute LazyHTML.query(doc, "button") |> Enum.any?()

      assert slots(acts(%{rule_option: {:rule_added, :allow}})) == [:gap, :gap]
    end
  end

  describe "the host's copy icon" do
    defp copy_row(connection) do
      base = %{
        id: "c1",
        host: "sum.golang.example",
        port: 443,
        path: "/lookup",
        method: "CONNECT",
        attempts: 1,
        allowed: 1,
        denied: 0,
        last_decision: "allowed",
        last_rule: "",
        last_outcome: "connected",
        last_seen_at: ~U[2026-09-20 14:02:21Z]
      }

      assigns = %{c: Map.merge(base, connection)}

      rendered_to_string(~H"""
      <table>
        <tbody>
          <RunComponents.connection_row
            id="cx-1"
            connection={@c}
            variant="workspace"
            security={false}
          />
        </tbody>
      </table>
      """)
      |> LazyHTML.from_fragment()
    end

    test "on a tool invocation it is beside the destination, outside its cut box" do
      doc = copy_row(%{last_tool: "files", path: "/media/a.png"})

      assert doc
             |> LazyHTML.query(".q-cx-d .q-cx-tl > .q-dest-tool + button#cx-1-copy")
             |> Enum.any?()

      refute doc |> LazyHTML.query(".q-dest #cx-1-copy") |> Enum.any?()
    end

    test "beside the host it copies the host alone, and says Copied in the shell's announcer" do
      doc = copy_row(%{})
      [button] = doc |> LazyHTML.query(".q-cx-d .q-cx-h > button#cx-1-copy") |> Enum.to_list()

      assert LazyHTML.attribute(button, "phx-hook") == ["CopyToClipboard"]
      assert LazyHTML.attribute(button, "data-copy") == ["sum.golang.example"]
      assert LazyHTML.attribute(button, "aria-label") == ["Copy sum.golang.example"]
      assert LazyHTML.attribute(button, "data-tip") == ["Copy sum.golang.example"]
      assert LazyHTML.attribute(button, "data-copied-words") == ["Copied"]
      # No live region in the row: the shell's one announcer says it.
      refute doc |> LazyHTML.query("#cx-1-copy [aria-live]") |> Enum.any?()
      # Without security too: it is the record's host, not a rule.
      refute doc |> LazyHTML.query(".q-cx-acts") |> Enum.any?()
    end
  end

  describe "a connection's host is isolated, so a bidi character reorders nothing" do
    # A right-to-left override in Forager's string, and markup that must stay text; the
    # page drops the override (`Apiary.ExternalText.line/1`) and isolates what is left.
    @host "evil\u202Elpmaxe.<script>"
    @shown "evillpmaxe.<script>"
    @escaped "evillpmaxe.&lt;script&gt;"

    defp bidi_row(variant, connection \\ %{}) do
      base = %{
        id: "c1",
        host: @host,
        port: 443,
        path: "",
        method: "CONNECT",
        attempts: 1,
        allowed: 0,
        denied: 1,
        last_decision: "denied",
        last_rule: "",
        last_outcome: "refused",
        last_mode: "enforce",
        last_seen_at: ~U[2026-09-20 14:02:21Z]
      }

      assigns = %{c: Map.merge(base, connection), variant: variant}

      if variant == "inline" do
        rendered_to_string(~H"""
        <RunComponents.connection_row id="cx-1" connection={@c} variant="inline" />
        """)
      else
        rendered_to_string(~H"""
        <table>
          <tbody>
            <RunComponents.connection_row id="cx-1" connection={@c} variant={@variant} />
          </tbody>
        </table>
        """)
      end
    end

    defp isolated(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> Enum.map(&LazyHTML.text/1)
    end

    test "in a row of a run's and of the workspace's Network access" do
      for variant <- ~w(table workspace),
          connection <- [%{}, %{path: "/v1/<b>", request_method: "GET"}] do
        html = bidi_row(variant, connection)
        assert isolated(html, ".q-cx-h > bdi") == [@shown], variant
        assert html =~ "#{@escaped}</bdi><span class=\"q-cx-p\">:443</span>", variant
        refute html =~ "<script>", variant
      end
    end

    test "in the timeline's row, a tool invocation's too" do
      html = bidi_row("inline")
      assert isolated(html, ".q-dest > bdi") == [@shown]
      assert html =~ "#{@escaped}</bdi><span class=\"text-faint\">:443</span>"
      refute html =~ "<script>"

      html =
        bidi_row("inline", %{
          last_decision: "allowed",
          last_rule: "files.tools.internal",
          last_outcome: "connected",
          last_tool: "files",
          path: "/media/a.png",
          request_method: "PUT"
        })

      assert isolated(html, ".q-dest-tool .q-on > bdi") == [@shown]
      assert html =~ "#{@escaped}</bdi>:443</span>"
      refute html =~ "<script>"
    end

    test "a host cut long right after an unclosed override keeps it inside the isolate" do
      # 18 letters, the override as the 19th character: the page drops it before the cut,
      # which keeps 19 and the ellipsis.
      long = String.duplicate("a", 18) <> "\u202E" <> String.duplicate("b", 30) <> ".<script>"
      cut = RunComponents.middle(Apiary.ExternalText.line(long), 40)
      assert String.ends_with?(String.slice(long, 0, 19), "\u202E")
      assert cut =~ "ab…"

      panel = %{
        anchor: "a-allow",
        host: long,
        action: :allow,
        refusal: %{
          rule_option: :locked_deny,
          rule: "*.paste.example",
          locked_by: nil,
          locked_at: nil,
          owner: true,
          rule_path: "/p"
        }
      }

      html = render_component(&RunComponents.rule_panel/1, panel: panel)
      assert isolated(html, "#rule-panel-title .q-rp-host > bdi") == [cut]
      # The isolate closes before the rest of the sentence, and no override is left in it.
      assert html =~ ~r|<bdi>a{18}b…b*\.&lt;script&gt;</bdi></span>|u
      refute html =~ "\u202E"

      assert isolated(html, "#rule-panel-title")
             |> hd()
             |> String.trim()
             |> String.ends_with?("stays denied")

      refute html =~ "<script>"

      html = bidi_row("workspace", %{host: long})
      assert isolated(html, ".q-cx-h > bdi") == [Apiary.ExternalText.line(long)]
      assert html =~ "</bdi><span class=\"q-cx-p\">:443</span>"
    end

    test "in the title of each rule panel" do
      panels = [
        %{anchor: "a-allow", host: @host, action: :allow, elsewhere: %{name: "Main", path: "/m"}},
        %{
          anchor: "a-allow",
          host: @host,
          action: :allow,
          refusal: %{
            rule_option: :locked_deny,
            rule: "*.paste.example",
            locked_by: nil,
            locked_at: nil,
            owner: true,
            rule_path: "/p"
          }
        },
        %{
          anchor: "a-allow",
          action: :allow,
          host: @host,
          path: "",
          page: :workspace,
          level: :workspace,
          target: nil,
          targets: [],
          choice: nil,
          what: nil,
          workspace: "Shop",
          interval: 30,
          consequence: %{},
          error: nil
        }
      ]

      for panel <- panels do
        html = render_component(&RunComponents.rule_panel/1, panel: panel)

        assert isolated(html, "#rule-panel-title .q-rp-host > bdi") == [@shown],
               inspect(panel)

        assert html =~ "#{@escaped}</bdi>"
        refute html =~ "<script>"
      end
    end
  end

  describe "a connection's texts, as a page shows an external system's text" do
    # What Forager sent with a bidirectional override, a zero-width space or a control
    # character in it, and what is left of them on the page.
    defp cx(connection, variant) do
      base = %{
        host: "api.example",
        port: 443,
        path: "",
        method: "CONNECT",
        attempts: 1,
        allowed: 1,
        denied: 0,
        runs: 1,
        last_decision: "allowed",
        last_rule: "api.example",
        last_outcome: "connected",
        last_mode: "enforce",
        first_seen_at: ~U[2026-09-20 14:02:20Z],
        last_seen_at: ~U[2026-09-20 14:02:21Z]
      }

      assigns = %{c: Map.merge(base, connection), variant: variant}

      rendered_to_string(~H"""
      <RunComponents.connection_row id="cx-1" connection={@c} variant={@variant} />
      """)
      |> LazyHTML.from_fragment()
    end

    defp texts(doc, selector),
      do: doc |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)

    test "a host with a bidirectional control: cleaned to read, as sent to act on" do
      sent = "api\u202E.example\u200B"

      for variant <- ~w(table workspace) do
        doc = cx(%{host: sent, last_rule: sent}, variant)

        assert texts(doc, ".q-cx-h > bdi") == ["api.example"]
        assert attr_of(doc, ".q-cx-t", "title") == ["api.example:443"]
        assert attr_of(doc, "#cx-1-copy", "data-copy") == [sent]
        assert attr_of(doc, "#cx-1-copy", "aria-label") == ["Copy api.example"]
        assert text(LazyHTML.to_html(doc)) =~ "Rule api.example"
        refute text(LazyHTML.to_html(doc)) =~ "\u202E"
      end

      workspace = cx(%{host: sent}, "workspace")
      assert attr_of(workspace, "#cx-1-toggle", "phx-value-host") == [sent]
    end

    test "a path with a control character: cleaned to read, as sent to act on" do
      sent = "/v1/\aitems"

      denied = %{
        path: sent,
        request_method: "GET",
        last_decision: "denied",
        last_path_rule: "",
        allowed: 0,
        denied: 1
      }

      assert texts(cx(denied, "table"), ".q-cx-path") == ["GET /v1/\uFFFDitems"]

      doc = cx(denied, "workspace")
      assert texts(doc, ".q-cx-path") == ["/v1/\uFFFDitems"]
      assert attr_of(doc, ".q-cx-t", "title") == ["api.example:443 /v1/\uFFFDitems"]
      assert attr_of(doc, "#cx-1-toggle", "phx-value-path") == [sent]
      assert text(LazyHTML.to_html(doc)) =~ "Host allowed, no path rule matches."
    end

    test "a method, a secret, a request's id and an outcome: cleaned to read" do
      sent = &("\u202E" <> &1 <> "\u200B\a")

      connection = %{
        path: "/v1/items",
        method: sent.("CONNECT"),
        request_method: sent.("GET"),
        last_credential: sent.("model-key"),
        request_id: sent.("rq-7"),
        last_outcome: sent.("reset")
      }

      for variant <- ~w(inline table) do
        doc = cx(connection, variant)
        shown = doc |> LazyHTML.to_html() |> text()

        assert shown =~ "GET\uFFFD /v1/items", variant
        assert shown =~ "secret model-key\uFFFD", variant
        assert shown =~ "reset\uFFFD", variant
        refute shown =~ "\u202E", variant
      end

      doc = cx(connection, "inline")

      assert attr_of(doc, ".q-dest", "title") ==
               ["api.example:443 GET\uFFFD /v1/items, request rq-7\uFFFD"]

      assert attr_of(doc, ".q-dest", "data-request-id") == [sent.("rq-7")]
      assert texts(cx(%{connection | path: ""}, "inline"), ".q-rq") == ["CONNECT\uFFFD"]
    end

    test "a tool and a rule: cleaned; the case is what was sent, whatever is left" do
      event = %{
        host: "localhost",
        port: 8080,
        path: "/hook",
        method: "POST",
        request_method: "POST",
        decision: "allowed",
        rule: "local\u202Ehost\a",
        tool: "\u202Ehook-relay\a",
        mode: "enforce",
        outcome: "connected",
        at: ~U[2026-09-20 14:02:20Z]
      }

      inline = fn event ->
        assigns = %{event: event}

        rendered_to_string(~H"""
        <RunComponents.connection_row id="e-1" connection={@event} variant="inline" />
        """)
      end

      html = inline.(event)
      doc = LazyHTML.from_fragment(html)
      assert texts(doc, ".q-tool-name") == ["hook-relay\uFFFD"]
      assert text(html) =~ "Handed to hook-relay\uFFFD by rule localhost\uFFFD"

      # Nothing left to show of the tool or the rule: still a call to a tool, by a rule,
      # each marked (`Apiary.ExternalText.marked/1`).
      html = inline.(%{event | tool: "\u202E\u200B", rule: "\u200B"})
      assert texts(LazyHTML.from_fragment(html), ".q-tool-name") == ["\uFFFD\uFFFD"]
      assert text(html) =~ "Handed to \uFFFD\uFFFD by rule \uFFFD"
      refute text(html) =~ "No rule matches."
      refute html =~ "\u202E"
    end

    test "a denied path with nothing left to show: no path rule, never the host's" do
      for variant <- ~w(table workspace) do
        doc =
          cx(
            %{
              path: "\u202E\u200B",
              request_method: "GET",
              last_decision: "denied",
              last_rule: "api.example",
              last_path_rule: "",
              allowed: 0,
              denied: 1
            },
            variant
          )

        words = text(LazyHTML.to_html(doc))
        assert words =~ "Host allowed, no path rule matches.", variant
        refute words =~ "Rule api.example", variant
      end
    end

    test "a host the wall refused for its form: marked, inside a <bdi> where it shows" do
      host = "Files\u202E.CDN\u200B.example."

      refused = %{
        last_decision: "denied",
        last_rule: "wall:host-form",
        allowed: 0,
        denied: 1
      }

      for variant <- ~w(inline table workspace) do
        html = cx(Map.put(refused, :host, host), variant) |> LazyHTML.to_html()

        # What the row acts on and copies is the host as sent; nothing else of it is.
        shown = String.replace(html, ~r{ (data-copy|phx-value-host)="[^"]*"}, "")

        marked = "Files\uFFFD.CDN\uFFFD.example."
        assert texts(LazyHTML.from_fragment(html), "bdi") == [marked], variant

        refute shown =~ "\u202E", variant
        refute shown =~ "\u200B", variant
      end
    end

    test "a host, a path and a path rule with nothing left to show: marked, not none" do
      sent = %{
        host: "\u200B",
        path: "\u202E\u200B",
        request_method: "GET",
        last_decision: "allowed",
        last_rule: "api.example",
        last_path_rule: "\u2060"
      }

      doc = cx(sent, "table")
      assert texts(doc, ".q-cx-h > bdi") == ["\uFFFD"]
      assert texts(doc, ".q-cx-path") == ["GET \uFFFD\uFFFD"]
      assert text(LazyHTML.to_html(doc)) =~ "Rule api.example, path \uFFFD"
      refute LazyHTML.to_html(doc) =~ "\u202E"
    end

    test "a path the wall refused as one that reads two ways: marked" do
      refused = %{
        path: "/a/%2e%2e/b\u202E",
        request_method: "GET",
        last_decision: "denied",
        last_rule: "api.example",
        last_path_rule: "wall:ambiguous-path",
        allowed: 0,
        denied: 1
      }

      assert texts(cx(refused, "table"), ".q-cx-path") == ["GET /a/%2e%2e/b\uFFFD"]
    end

    test "a tool's name, as a connection leads with it: cleaned; one sent blank marked" do
      for {name, shown} <- [{"files\u202E\u200B", "files"}, {" ", "\uFFFD"}] do
        html = render_component(&RunComponents.tool_mark/1, name: name)
        assert texts(LazyHTML.from_fragment(html), ".q-tool-name") == [shown]
      end
    end

    test "a rule panel's host and path sent with nothing left to show: marked" do
      panel = %{
        anchor: "a-allow",
        action: :allow,
        host: "\u200B",
        path: "\u202E",
        page: :workspace,
        level: :workspace,
        target: nil,
        targets: [],
        choice: nil,
        what: %{workspace: %{kind: :path, paths: []}},
        workspace: "Shop",
        interval: 30,
        consequence: %{},
        error: nil
      }

      html = render_component(&RunComponents.rule_panel/1, panel: panel)
      doc = LazyHTML.from_fragment(html)
      assert texts(doc, "#rule-panel-title .q-rp-host > bdi") == ["\uFFFD"]
      assert texts(doc, "#rule-panel-what .q-rule") == ["\uFFFD"]
      # The host's title agrees with the host shown beside it.
      assert doc |> LazyHTML.query("#rule-panel-title .q-rp-host") |> LazyHTML.attribute("title") ==
               ["\uFFFD"]

      html =
        render_component(&RunComponents.rule_panel/1,
          panel: %{panel | host: "\u202Eapi.example\u200B", path: "/v1"}
        )

      doc = LazyHTML.from_fragment(html)
      assert texts(doc, "#rule-panel-title .q-rp-host > bdi") == ["api.example"]

      assert doc |> LazyHTML.query("#rule-panel-title .q-rp-host") |> LazyHTML.attribute("title") ==
               ["api.example"]
    end
  end
end
