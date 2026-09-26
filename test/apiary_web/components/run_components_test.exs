defmodule ApiaryWeb.RunComponentsTest do
  use ExUnit.Case, async: true

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

  describe "run_state" do
    test "every state says its word, and only a live running badge ripples" do
      for {state, word} <- [
            {"pending", "Pending"},
            {"running", "Running"},
            {"succeeded", "Succeeded"},
            {"failed", "Failed"},
            {"timed_out", "Timed out"},
            {"lost", "Lost"},
            {"closed", "Closed"}
          ] do
        html = render_component(&RunComponents.run_state/1, state: state)
        assert String.starts_with?(text(html), word)
        assert html =~ "q-state-running" == (state == "running")
      end
    end

    test "the colours follow the decision table" do
      assert render_component(&RunComponents.run_state/1, state: "running") =~ "bg-info-soft"
      assert render_component(&RunComponents.run_state/1, state: "succeeded") =~ "bg-success-soft"
      assert render_component(&RunComponents.run_state/1, state: "failed") =~ "bg-error-soft"
      assert render_component(&RunComponents.run_state/1, state: "timed_out") =~ "bg-error-soft"
      assert render_component(&RunComponents.run_state/1, state: "lost") =~ "bg-primary-soft"
      refute render_component(&RunComponents.run_state/1, state: "pending") =~ "-soft"
      assert render_component(&RunComponents.run_state/1, state: "pending") =~ "q-state-pending"
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

      assert text(render_component(&RunComponents.run_state/1, state: "succeeded", exit_code: 0)) ==
               "Succeeded"
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

      # The runner said 120 s had elapsed; the server received that 14 s ago. The runner's
      # own started_at plays no part.
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

    test "relative and clock labels" do
      now = ~U[2026-09-20 14:04:00Z]
      assert RunComponents.relative_label(~U[2026-09-20 14:03:20Z], now) == "40 seconds ago"
      assert RunComponents.relative_label(~U[2026-09-20 14:02:00Z], now) == "2 minutes ago"
      assert RunComponents.relative_label(~U[2026-09-19 16:40:03Z], now) == "Yesterday, 16:40"
      assert RunComponents.relative_label(~U[2026-09-17 09:30:00Z], now) == "17 Sep, 09:30"
      assert RunComponents.relative_label(~U[2025-09-17 09:30:00Z], now) == "17 Sep 2025, 09:30"
      assert RunComponents.clock_label(~U[2026-09-20 14:02:11Z], now) == "Today, 14:02:11"
    end

    test "the browser's clocks are handed the server's words, one per count" do
      words = RunComponents.clock_words()
      assert Enum.at(words.secondsAgo, 1) == "1 second ago"
      assert Enum.at(words.secondsAgo, 40) == "40 seconds ago"
      assert length(words.minutesAgo) == 60 and length(words.hoursAgo) == 24
      assert words.yesterday == "Yesterday, %{time}"
      assert words.minutesSeconds == "%{minutes} m %{seconds} s"
      assert Enum.at(words.months, 8) == "Sep"
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
      assert html =~ "q-mark-no"
      assert text(html) =~ "Denied"
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
               "The wall refuses the machine's own address, in either mode."

      assert text(
               row(%{
                 last_decision: "denied",
                 last_rule: "api.example",
                 last_path_rule: "wall:ambiguous-path"
               })
             ) =~ "The path can be read two ways. The wall denies it in either mode."
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

      assert text(html) =~ "Rule api.example, path /v1/*, credential model-key"
      assert text(html) =~ "api.example:443 POST /v1/messages"
      assert html =~ "q-mark-ok"
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

    test "the hive variant marks a mixed destination's reason as the last attempt's" do
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
          "hive"
        )

      assert text(html) =~ "65 / 8"
      assert text(html) =~ "Rule registry.example · last attempt"
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

      for variant <- ~w(table hive) do
        html = row(invocation, variant)
        [dest] = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-dest") |> Enum.to_list()

        assert LazyHTML.query(dest, ".hero-wrench-screwdriver-micro") |> Enum.count() == 1

        assert text(LazyHTML.to_html(dest)) =~
                 ~r/^Tool files PUT \/media\/acme\/shop\/checkout.png files.tools.internal:443$/

        assert text(html) =~
                 "Handed to files by rule files.tools.internal, path /media/acme/shop/*"

        assert text(html) =~ "Answered 200"
        refute text(html) =~ "Connected"
        assert html =~ "q-mark-ok"
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

      for variant <- ~w(table hive) do
        html = row(refused, variant)
        [dest] = html |> LazyHTML.from_fragment() |> LazyHTML.query(".q-dest") |> Enum.to_list()

        # The host leads, as for any denial; no wrench, no q-dest-tool.
        assert text(LazyHTML.to_html(dest)) =~
                 ~r/^files.tools.internal:443 GET \/media\/acme\/other\/checkout.png$/

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

  describe "controls" do
    test "a toggle and a segment are buttons that patch, so Space works" do
      html =
        render_component(&RunComponents.filter_toggle/1,
          name: "denials",
          label: "Has denials",
          pressed: true,
          patch: "/hive/runs"
        )

      assert html =~ ~r/<button[^>]*type="button"[^>]*aria-pressed="true"/
      refute html =~ "role=\"button\""
      assert html =~ "/hive/runs"
    end

    test "the closed badge's tip is focusable and is text" do
      html =
        render_component(&RunComponents.run_state/1,
          state: "closed",
          closed_at: ~U[2026-09-14 10:00:00Z]
        )

      assert html =~ ~s(tabindex="0")

      assert text(html) =~
               "Closed. Closed by a member on 14 Sep 2026. The run never posted its exit."
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

    test "labels come with forge, repository and task first" do
      assert RunComponents.ordered_labels(%{"a" => "1", "task" => "t", "forge" => "f"}) ==
               [{"forge", "f"}, {"task", "t"}, {"a", "1"}]
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
end
