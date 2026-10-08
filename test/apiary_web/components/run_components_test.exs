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

    test "the closed badge's tip is focusable and is text" do
      html =
        render_component(&RunComponents.run_state/1,
          state: "closed",
          closed_at: ~U[2026-09-14 10:00:00Z]
        )

      assert html =~ ~s(tabindex="0")

      assert text(html) =~
               "Closed. Closed by a member on 14 Sept 2026. The run never posted its exit."
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
    @run_id "7f3e9b20-5b1d-4c7e-9a10-2f6d0c4b7e11"

    test "the title is the one the run gave, else Run and its short id" do
      titled = %{run_id: @run_id, about_title: "Fix the login redirect"}
      assert RunComponents.run_title(titled) == "Fix the login redirect"
      assert RunComponents.given_title(titled) == "Fix the login redirect"

      for untitled <- [
            %{run_id: @run_id, about_title: nil},
            %{run_id: @run_id, about_title: ""},
            # A task is an ordinary label, never the title.
            %{run_id: @run_id, about_title: nil, labels: %{"task" => "fix-login"}}
          ] do
        assert RunComponents.run_title(untitled) == "Run 7f3e9b20"
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

      doc = acts(Map.put(elsewhere, :allow_path, "/main/policy?allow=api.example.com"))
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

    test "a host no rule can name says so to a screen reader alone; a rule just added, nothing" do
      doc = acts(%{rule_option: :unnameable})
      assert slots(doc) == [:gap, :gap]
      assert doc |> LazyHTML.query(".sr-only") |> LazyHTML.text() == "No rule can name this host"

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
end
