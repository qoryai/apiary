defmodule Apiary.Runs.FoldTest do
  use ExUnit.Case, async: true

  alias Apiary.Runs.Fold

  @run %{
    state: "pending",
    forager_version: nil,
    contract_version: nil,
    opened_by: nil,
    runtime: nil,
    runtime_version: nil,
    command: nil,
    args: [],
    dir: nil,
    interactive: nil,
    host: nil,
    wall: nil,
    image: nil,
    labels: %{},
    about_kind: nil,
    about_title: nil,
    about_subjects: [],
    about_details: nil,
    target_system: nil,
    target_path: nil,
    started_at: nil,
    exited_at: nil,
    exit_code: nil,
    signal: nil,
    reason: nil,
    quiet_seconds: nil,
    duration_ms: nil,
    last_heartbeat_at: nil,
    elapsed_seconds: nil,
    heartbeat_interval_seconds: nil,
    policy_digest: nil,
    run_configuration_digest: nil,
    lost_at: nil,
    cost_usd: nil,
    terminal_cols: nil,
    terminal_rows: nil
  }

  @t0 ~U[2026-09-16 12:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # Received a hundred seconds after it was sent: the two clocks are told apart.
  defp event(sequence, type, data, seconds \\ nil) do
    seconds = seconds || sequence

    %{
      sequence: sequence,
      type: "dev.qory." <> type,
      data: data,
      time: at(seconds),
      received_at: at(seconds + 100)
    }
  end

  defp started(sequence, extra \\ %{}) do
    event(
      sequence,
      "run.started",
      Map.merge(
        %{
          "opened_by" => "session",
          "credential" => "none",
          "runtime" => "claude",
          "runtime_version" => "2.1.0",
          "command" => "claude",
          "args" => ["-p", "fix the build"],
          "dir" => "/work",
          "interactive" => false,
          "forager_version" => "v0.4.0",
          "host" => "dev-laptop",
          "wall" => "docker",
          "image" => "example/agent:1",
          "labels" => %{
            "forge" => "git.example.com",
            "repository" => "acme/shop",
            "task" => "issue-12"
          }
        },
        extra
      )
    )
  end

  defp pty(cols, rows),
    do: %{"interactive" => true, "terminal" => %{"cols" => cols, "rows" => rows}}

  defp resized(sequence, cols, rows),
    do: event(sequence, "run.resized", %{"cols" => cols, "rows" => rows})

  defp heartbeat(sequence, elapsed, interval \\ 30, seconds \\ nil),
    do:
      event(
        sequence,
        "run.heartbeat",
        %{"elapsed_seconds" => elapsed, "interval_seconds" => interval},
        seconds
      )

  defp exited(sequence, data),
    do: event(sequence, "run.exited", Map.merge(%{"exit_code" => 0, "duration_ms" => 1200}, data))

  defp egress(sequence, data, seconds \\ nil) do
    event(
      sequence,
      "run.egress",
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
        data
      ),
      seconds
    )
  end

  describe "dev.qory.ping" do
    test "records the versions and leaves the run pending" do
      data = %{"forager_version" => "v0.4.0", "contract_version" => 1, "events" => []}
      %{run: run} = Fold.fold(@run, [event(1, "ping", data)])

      assert run.forager_version == "v0.4.0"
      assert run.contract_version == 1
      assert run.state == "pending"
    end

    test "fields of the wrong type are read as absent" do
      data = %{"forager_version" => 4, "contract_version" => "1"}
      assert %{run: @run} = Fold.fold(@run, [event(1, "ping", data)])
    end

    test "the later of ping and run.started says Forager's version, in any order" do
      ping = event(1, "ping", %{"forager_version" => "v0.4.0", "contract_version" => 1})
      start = started(2, %{"forager_version" => "v0.4.1"})

      assert Fold.fold(@run, [ping, start]).run.forager_version == "v0.4.1"

      %{run: run, latest: latest} = Fold.fold(@run, [start])
      %{run: run} = Fold.fold(run, [ping], latest)
      assert run.forager_version == "v0.4.1"
      assert run.contract_version == 1
    end

    test "the ping with the highest sequence decides" do
      first = event(1, "ping", %{"forager_version" => "v1", "contract_version" => 1})
      second = event(9, "ping", %{"forager_version" => "v2", "contract_version" => 1})

      %{run: run, latest: latest} = Fold.fold(@run, [second])
      %{run: run} = Fold.fold(run, [first], latest)

      assert {run.forager_version, run.contract_version} == {"v2", 1}
    end
  end

  describe "dev.qory.run.started" do
    test "fills the header, the labels and what is read from them, and the run is running" do
      %{run: run} = Fold.fold(@run, [started(2)])

      assert run.state == "running"
      assert run.started_at == at(2)
      assert run.opened_by == "session"
      assert run.runtime == "claude"
      assert run.runtime_version == "2.1.0"
      assert run.command == "claude"
      assert run.args == ["-p", "fix the build"]
      assert run.dir == "/work"
      assert run.interactive == false
      assert run.forager_version == "v0.4.0"
      assert run.host == "dev-laptop"
      assert run.wall == "docker"
      assert run.image == "example/agent:1"
      assert run.target_system == "git.example.com"
      assert run.target_path == "acme/shop"
      assert run.labels["task"] == "issue-12"
    end

    test "a gateway's start says no session: no runtime, command, host or terminal" do
      start =
        event(2, "run.started", %{
          "opened_by" => "gateway",
          "credential" => "issuer",
          "forager_version" => "0.6.0",
          "labels" => %{
            "forge" => "git.example.com",
            "repository" => "example-org/example-repo",
            "run_key" => "rk-0001"
          },
          "about" => %{"details" => %{"requester" => "example-requester"}}
        })

      %{run: run} = Fold.fold(@run, [start])

      assert run.opened_by == "gateway"
      assert Apiary.Runs.Run.no_session?(run)
      assert run.state == "running"
      assert run.forager_version == "0.6.0"
      assert {run.runtime, run.command, run.args, run.dir, run.host} == {nil, nil, [], nil, nil}
      assert {run.terminal_cols, run.terminal_rows} == {nil, nil}
      assert run.labels["run_key"] == "rk-0001"
      assert run.target_path == "example-org/example-repo"
      assert run.about_details == %{"requester" => "example-requester"}
    end

    test "an opener the contract does not name is read as absent" do
      for opener <- ["robot", "", 1, nil] do
        %{run: run} = Fold.fold(@run, [started(2, %{"opened_by" => opener})])
        assert run.opened_by == nil
        refute Apiary.Runs.Run.no_session?(run)
      end
    end

    test "the workspace's domain names the target, by its own labels" do
      workspace = %Apiary.Organisations.Workspace{domain: "example"}
      labels = %{"platform" => "ads.example", "account" => "42", "forge" => "git.example.com"}

      %{run: run} =
        Fold.fold(Map.put(@run, :workspace, workspace), [started(2, %{"labels" => labels})])

      assert {run.target_system, run.target_path} == {"ads.example", "42"}
    end

    test "a run without labels has none" do
      %{run: run} = Fold.fold(@run, [started(2, %{"labels" => nil})])
      assert run.labels == %{}
      assert run.target_system == nil
    end

    test "arriving after the exit, it fills the header and leaves the state" do
      %{run: run} = Fold.fold(@run, [exited(9, %{"state" => "succeeded"})])
      %{run: run} = Fold.fold(run, [started(2)], %{"dev.qory.run.exited" => 9})

      assert run.state == "succeeded"
      assert run.runtime == "claude"
    end

    test "arriving for a lost run, the run is running and no longer lost" do
      %{run: run} = Fold.fold(%{@run | state: "lost", lost_at: at(100)}, [started(2)])
      assert {run.state, run.lost_at} == {"running", nil}
    end

    test "on a pseudo-terminal it says the terminal's size; on pipes there is none" do
      %{run: run} = Fold.fold(@run, [started(2, pty(120, 40))])
      assert {run.interactive, run.terminal_cols, run.terminal_rows} == {true, 120, 40}

      %{run: run} = Fold.fold(@run, [started(2)])
      assert {run.terminal_cols, run.terminal_rows} == {nil, nil}
    end

    test "a size that is not one is read as absent" do
      for terminal <- [
            %{"cols" => 0, "rows" => 40},
            %{"cols" => 120, "rows" => 65_536},
            %{"cols" => "120", "rows" => 40},
            %{"cols" => 120},
            "120x40"
          ] do
        %{run: run} = Fold.fold(@run, [started(2, %{"terminal" => terminal})])
        assert {run.terminal_cols, run.terminal_rows} == {nil, nil}
      end
    end
  end

  describe "about of dev.qory.run.started" do
    defp about(about), do: Fold.fold(@run, [started(2, %{"about" => about})]).run

    defp subject(type, ref, extra \\ %{}),
      do: Map.merge(%{"type" => type, "ref" => ref}, extra)

    # `n` bytes, of characters of two bytes and one more of one when `n` is odd.
    defp bytes(n), do: String.duplicate("é", div(n, 2)) <> String.duplicate("a", rem(n, 2))

    defp subject_refs(run), do: Enum.map(run.about_subjects, &{&1["type"], &1["ref"]})

    test "keeps the kind, the title, the subjects and the details as sent" do
      run =
        about(%{
          "kind" => "implementation",
          "title" => "Fix the login redirect",
          "subjects" => [
            subject("ticket", "ENG-17", %{
              "url" => "https://tracker.example.com/ENG-17",
              "title" => "Login redirects to the wrong page"
            }),
            subject("pull request", "#412")
          ],
          "details" => %{"ticket" => %{"priority" => "high"}, "attempt" => 2}
        })

      assert run.about_kind == "implementation"
      assert run.about_title == "Fix the login redirect"

      assert run.about_subjects == [
               %{
                 "type" => "ticket",
                 "ref" => "ENG-17",
                 "url" => "https://tracker.example.com/ENG-17",
                 "title" => "Login redirects to the wrong page"
               },
               %{"type" => "pull request", "ref" => "#412"}
             ]

      assert run.about_details == %{"ticket" => %{"priority" => "high"}, "attempt" => 2}
    end

    test "a start without about says nothing about the run" do
      %{run: run} = Fold.fold(@run, [started(2)])

      assert {run.about_kind, run.about_title, run.about_subjects, run.about_details} ==
               {nil, nil, [], nil}
    end

    test "an about that is not an object is ignored" do
      for about <- ["Fix the login redirect", ["implementation"], 3, true, nil] do
        run = about(about)

        assert {run.about_kind, run.about_title, run.about_subjects, run.about_details} ==
                 {nil, nil, [], nil}

        assert run.runtime == "claude"
      end
    end

    test "the kind is kept up to 64 bytes and dropped whole past them" do
      assert about(%{"kind" => bytes(64)}).about_kind == bytes(64)
      assert about(%{"kind" => "a"}).about_kind == "a"

      for kind <- [bytes(65), "", 64, ["implementation"]] do
        run = about(%{"kind" => kind, "title" => "Fix the login redirect"})
        assert {run.about_kind, run.about_title} == {nil, "Fix the login redirect"}
      end
    end

    test "the title is kept up to 256 bytes and dropped whole past them" do
      assert about(%{"title" => bytes(256)}).about_title == bytes(256)
      assert about(%{"title" => "a"}).about_title == "a"

      for title <- [bytes(257), "", 256, %{"text" => "Fix"}] do
        run = about(%{"title" => title, "kind" => "implementation"})
        assert {run.about_title, run.about_kind} == {nil, "implementation"}
      end
    end

    test "details are kept up to 8192 bytes encoded and dropped whole past them" do
      # `{"k":"` and `"}` are eight bytes around the value.
      fits = %{"k" => String.duplicate("a", 8184)}
      assert byte_size(Jason.encode!(fits)) == 8192
      assert about(%{"details" => fits}).about_details == fits

      over = %{"k" => String.duplicate("a", 8185)}
      run = about(%{"details" => over, "kind" => "implementation"})
      assert {run.about_details, run.about_kind} == {nil, "implementation"}

      # Counted in bytes, not characters.
      wide = %{"k" => String.duplicate("é", 4093)}
      assert byte_size(Jason.encode!(wide)) == 8194
      assert about(%{"details" => wide}).about_details == nil

      assert about(%{"details" => %{}}).about_details == %{}
    end

    test "details nested deeper than 4 levels are dropped whole, an array counting as a level" do
      for details <- [
            %{"a" => %{"b" => %{"c" => 1}}},
            %{"a" => %{"b" => %{"c" => %{"d" => 1}}}},
            %{"a" => [%{"b" => [1, 2]}]},
            %{"a" => [[["x"]]]},
            %{"a" => [[[]]]}
          ] do
        assert about(%{"details" => details}).about_details == details
      end

      for details <- [
            %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => 1}}}}},
            %{"a" => [%{"b" => [[1]]}]},
            %{"a" => [[[[]]]]},
            %{"shallow" => 1, "deep" => [[[%{}]]]}
          ] do
        run = about(%{"details" => details, "title" => "Fix the login redirect"})
        assert {run.about_details, run.about_title} == {nil, "Fix the login redirect"}
      end
    end

    test "details are measured as the event carries them, <, > and & six bytes each" do
      # `{"k":"` and `"}` are eight bytes around the value, and `<`, `>` and `&` are written
      # `\u003c`, `\u003e` and `\u0026` in the event: five bytes more each.
      fits = %{"k" => "<>&" <> String.duplicate("a", 8184 - 18)}
      assert about(%{"details" => fits}).about_details == fits

      over = %{"k" => "<>&" <> String.duplicate("a", 8184 - 17)}
      assert byte_size(Jason.encode!(over)) < 8192
      assert about(%{"details" => over}).about_details == nil
    end

    test "a details key is 1 to 64 bytes at every level, or the details are dropped whole" do
      key = String.duplicate("k", 64)

      for details <- [%{key => 1}, %{"a" => %{key => [%{key => true}]}}] do
        assert about(%{"details" => details}).about_details == details
      end

      for details <- [
            %{(key <> "k") => 1},
            %{"" => 1},
            %{"a" => %{(key <> "k") => 1}},
            %{"a" => [%{"" => 1}]}
          ] do
        run = about(%{"details" => details, "kind" => "implementation"})
        assert {run.about_details, run.about_kind} == {nil, "implementation"}
      end
    end

    test "a string with a control character drops what holds it" do
      for bad <- ["\u0000", "\a", "\n", "\u007F", "\u0085", "\u009F", "\u2028", "\u2029"] do
        run = about(%{"kind" => "imple#{bad}mentation", "title" => "Fix the#{bad} build"})
        assert {run.about_kind, run.about_title} == {nil, nil}

        run =
          about(%{
            "subjects" => [
              subject("ticket", "ENG-1#{bad}"),
              subject("ticket", "ENG-2", %{
                "url" => "https://example.com/ENG-2#{bad}",
                "title" => "Login#{bad}"
              })
            ]
          })

        assert run.about_subjects == [%{"type" => "ticket", "ref" => "ENG-2"}]

        for details <- [
              %{"a#{bad}" => 1},
              %{"a" => "b#{bad}"},
              %{"a" => [%{"b" => ["c#{bad}"]}]},
              %{"a" => %{"b#{bad}" => 1}}
            ] do
          assert about(%{"details" => details}).about_details == nil
        end
      end

      kept = %{"a" => "é and a no-break space,\u00A0are fine"}
      assert about(%{"details" => kept, "title" => "é \u00A0"}).about_details == kept
    end

    test "details that are not an object are dropped" do
      for details <- [[%{"a" => 1}], "priority: high", 1, nil] do
        assert about(%{"details" => details}).about_details == nil
      end
    end

    test "a subject without a valid type or ref is dropped on its own" do
      run =
        about(%{
          "subjects" => [
            subject("ticket", "ENG-17"),
            "ticket ENG-18",
            %{"type" => "ticket"},
            %{"ref" => "ENG-19"},
            subject("Ticket", "ENG-20"),
            subject("pull  request", "#1"),
            subject("pull request ", "#2"),
            subject("-ticket", "ENG-21"),
            subject("", "ENG-22"),
            subject(String.duplicate("a", 65), "ENG-23"),
            subject(String.duplicate("a", 64), "ENG-24"),
            subject("ticket", ""),
            subject("ticket", 25),
            subject("ticket", bytes(257)),
            subject("ticket", bytes(256)),
            subject(7, "ENG-26"),
            subject("work_item.v2", "a"),
            subject("pull request", "#412")
          ]
        })

      assert subject_refs(run) == [
               {"ticket", "ENG-17"},
               {String.duplicate("a", 64), "ENG-24"},
               {"ticket", bytes(256)},
               {"work_item.v2", "a"},
               {"pull request", "#412"}
             ]
    end

    test "subjects that are not a list are none" do
      for subjects <- [subject("ticket", "ENG-17"), "ENG-17", nil] do
        assert about(%{"subjects" => subjects}).about_subjects == []
      end
    end

    test "a subject's title is kept up to 256 bytes and dropped from that subject alone" do
      run =
        about(%{
          "subjects" => [
            subject("ticket", "ENG-1", %{"title" => bytes(256)}),
            subject("ticket", "ENG-2", %{"title" => bytes(257)}),
            subject("ticket", "ENG-3", %{"title" => ""}),
            subject("ticket", "ENG-4", %{"title" => 4}),
            subject("ticket", "ENG-5", %{"title" => "a"})
          ]
        })

      assert run.about_subjects == [
               %{"type" => "ticket", "ref" => "ENG-1", "title" => bytes(256)},
               %{"type" => "ticket", "ref" => "ENG-2"},
               %{"type" => "ticket", "ref" => "ENG-3"},
               %{"type" => "ticket", "ref" => "ENG-4"},
               %{"type" => "ticket", "ref" => "ENG-5", "title" => "a"}
             ]
    end

    test "a url is kept only when absolute http or https with a host and no user, up to 2048 bytes" do
      long = "https://example.com/" <> String.duplicate("a", 2028)
      assert byte_size(long) == 2048

      kept = [long, "http://example.com", "https://tracker.example.com/ENG-17?tab=1#top"]

      dropped = [
        long <> "a",
        "javascript:alert(1)",
        "ftp://x",
        "/ENG-17",
        "ENG-17",
        "tracker.example.com/ENG-17",
        "//tracker.example.com/ENG-17",
        "http:///ENG-17",
        "https://",
        "mailto:someone@example.com",
        "https://user@tracker.example.com/ENG-17",
        "https://user:secret@tracker.example.com/ENG-17",
        "https://example.com/a b",
        "",
        17
      ]

      for url <- kept do
        assert [%{"url" => ^url}] =
                 about(%{"subjects" => [subject("ticket", "1", %{"url" => url})]}).about_subjects
      end

      for url <- dropped do
        assert about(%{"subjects" => [subject("ticket", "1", %{"url" => url, "title" => "t"})]}).about_subjects ==
                 [%{"type" => "ticket", "ref" => "1", "title" => "t"}]
      end
    end

    test "a url with a user name, or a user name and password, is dropped; the subject stays" do
      for url <- [
            "https://user@tracker.example.com/ENG-17",
            "https://user:secret@tracker.example.com/ENG-17"
          ] do
        run = about(%{"subjects" => [subject("ticket", "ENG-17", %{"url" => url})]})
        assert run.about_subjects == [%{"type" => "ticket", "ref" => "ENG-17"}]
      end
    end

    test "subjects are de-duplicated by type and ref, the first winning, then cut to 16" do
      subjects =
        [
          subject("ticket", "ENG-0", %{"title" => "first"}),
          subject("ticket", "invalid", %{"type" => "Ticket"}),
          subject("ticket", "ENG-0", %{"title" => "second"}),
          subject("pull request", "ENG-0")
        ] ++ for(n <- 1..20, do: subject("ticket", "ENG-#{n}"))

      run = about(%{"subjects" => subjects})

      assert length(run.about_subjects) == 16
      assert hd(run.about_subjects) == %{"type" => "ticket", "ref" => "ENG-0", "title" => "first"}

      assert subject_refs(run) ==
               [{"ticket", "ENG-0"}, {"pull request", "ENG-0"}] ++
                 for(n <- 1..14, do: {"ticket", "ENG-#{n}"})
    end

    test "a later run.started replaces it, member by member; an earlier one does not" do
      first = %{
        "kind" => "implementation",
        "title" => "Fix the login redirect",
        "subjects" => [subject("ticket", "ENG-17")],
        "details" => %{"attempt" => 1}
      }

      second = %{
        "title" => "Fix the login redirect again",
        "subjects" => [subject("pull request", "#412")]
      }

      %{run: run, latest: latest} = Fold.fold(@run, [started(2, %{"about" => first})])
      %{run: run} = Fold.fold(run, [started(5, %{"about" => second})], latest)

      assert {run.about_kind, run.about_title, subject_refs(run), run.about_details} ==
               {nil, "Fix the login redirect again", [{"pull request", "#412"}], nil}

      %{run: run, latest: latest} = Fold.fold(@run, [started(5, %{"about" => second})])
      %{run: run} = Fold.fold(run, [started(2, %{"about" => first})], latest)
      assert run.about_title == "Fix the login redirect again"

      %{run: run} = Fold.fold(@run, [started(2, %{"about" => first}), started(5)])

      assert {run.about_kind, run.about_title, run.about_subjects, run.about_details} ==
               {nil, nil, [], nil}
    end
  end

  describe "dev.qory.run.resized" do
    test "moves the run to the new size, the later by sequence deciding in any order" do
      events = [started(2, pty(120, 40)), resized(6, 100, 30), resized(9, 80, 24)]

      for order <- [
            events,
            Enum.reverse(events),
            [Enum.at(events, 1) | [hd(events), List.last(events)]]
          ] do
        %{run: run} = Fold.fold(@run, order)
        assert {run.terminal_cols, run.terminal_rows} == {80, 24}
      end
    end

    test "across passes, the sequence already projected decides" do
      %{run: run} = Fold.fold(@run, [resized(9, 80, 24)])
      assert {run.terminal_cols, run.terminal_rows} == {80, 24}

      # The start and an earlier resize arrive after: neither takes the size back.
      %{run: run} =
        Fold.fold(run, [started(2, pty(120, 40)), resized(6, 100, 30)], %{"terminal" => 9})

      assert {run.terminal_cols, run.terminal_rows} == {80, 24}
      assert run.interactive == true
    end

    test "a resize that is not a size changes nothing, and does not take the rank" do
      %{run: run, latest: latest} =
        Fold.fold(@run, [
          started(2, pty(120, 40)),
          resized(6, 0, 30),
          event(7, "run.resized", %{})
        ])

      assert {run.terminal_cols, run.terminal_rows} == {120, 40}
      assert latest["terminal"] == 2
    end

    test "its ranks are the terminal's, shared with the start" do
      assert Fold.ranks("dev.qory.run.resized") == ["terminal"]
      assert "terminal" in Fold.ranks("dev.qory.run.started")
      assert Fold.rank_types("terminal") == ["dev.qory.run.started", "dev.qory.run.resized"]
    end
  end

  describe "dev.qory.run.policy_applied" do
    @digest String.duplicate("ab", 32)

    test "keeps both digests" do
      data = %{"digest" => @digest, "run_configuration" => "sha256=" <> @digest}
      %{run: run} = Fold.fold(@run, [event(3, "run.policy_applied", data)])

      assert run.policy_digest == @digest
      assert run.run_configuration_digest == "sha256=" <> @digest
    end

    test "the highest sequence decides, in whatever order they come" do
      early = event(3, "run.policy_applied", %{"digest" => "early"})
      late = event(8, "run.policy_applied", %{"digest" => "late"})

      assert Fold.fold(@run, [late, early]).run.policy_digest == "late"

      %{run: run, latest: latest} = Fold.fold(@run, [late])
      assert Fold.fold(run, [early], latest).run.policy_digest == "late"
    end
  end

  describe "dev.qory.run.heartbeat" do
    test "records the beat at the time this server received it" do
      %{run: run} = Fold.fold(%{@run | state: "running"}, [heartbeat(5, 30)])

      assert run.last_heartbeat_at == at(105)
      assert run.elapsed_seconds == 30
      assert run.heartbeat_interval_seconds == 30
      assert run.state == "running"
    end

    test "the highest sequence decides, whatever Forager's clock says" do
      # The later beat is dated before the earlier one: a clock that was set back.
      later = heartbeat(9, 60, 30, 3)
      earlier = heartbeat(5, 30, 15, 50)

      %{run: run, latest: latest} = Fold.fold(@run, [later])
      %{run: run} = Fold.fold(run, [earlier], latest)

      assert run.last_heartbeat_at == later.received_at
      assert run.elapsed_seconds == 60
      assert run.heartbeat_interval_seconds == 30
      assert Fold.fold(@run, [earlier, later]).run == run
    end

    test "a beat dated in the future does not mask the beats after it" do
      future = heartbeat(5, 30, 30, 86_400 * 365)
      next = heartbeat(6, 60)

      %{run: run} = Fold.fold(@run, [future, next])
      assert run.last_heartbeat_at == next.received_at
      assert run.elapsed_seconds == 60
    end

    test "an interval outside 1..3600 is read as absent" do
      for interval <- [0, -5, 3601, 2_000_000_000, "30"] do
        %{run: run} = Fold.fold(@run, [heartbeat(5, 30, interval)])
        assert run.heartbeat_interval_seconds == nil
        assert run.last_heartbeat_at == at(105)
      end

      assert Fold.fold(@run, [heartbeat(5, 30, 3600)]).run.heartbeat_interval_seconds == 3600
    end

    test "a lost run that beats again is running again" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(7, 120)], %{"dev.qory.run.heartbeat" => 4})

      assert run.state == "running"
      assert run.lost_at == nil
    end

    test "an earlier beat arriving late does not revive a lost run" do
      lost = %{@run | state: "lost", lost_at: at(100), last_heartbeat_at: at(10)}
      %{run: run} = Fold.fold(lost, [heartbeat(3, 5)], %{"dev.qory.run.heartbeat" => 4})

      assert run.state == "lost"
      assert run.lost_at == at(100)
      assert run.last_heartbeat_at == at(10)
    end

    test "a run that ended is not revived" do
      for state <- ~w(succeeded ended failed timed_out) do
        %{run: run} = Fold.fold(%{@run | state: state}, [heartbeat(5, 30)])
        assert run.state == state
      end
    end

    test "a beat counts by its own time within the run's clock offset, never after its arrival" do
      # The offset the run's beats set: received 100 s after their time.
      run = %{@run | state: "running"} |> Map.put(:clock_offset_ms, 100_000)

      # Received on time, a little faster than the others, or an hour late.
      fast = %{heartbeat(5, 30) | received_at: at(95)}
      late = %{heartbeat(6, 60) | received_at: at(3606)}

      assert %{last_heartbeat_at: heard, clock_offset_ms: 90_000} = Fold.fold(run, [fast]).run
      assert heard == at(95)

      assert %{last_heartbeat_at: heard, clock_offset_ms: 100_000} = Fold.fold(run, [late]).run
      assert heard == at(6 + 100 + 300)
    end

    test "the offset is the smallest over every beat, whatever its sequence or order" do
      beats = [
        %{heartbeat(5, 30) | received_at: at(120)},
        %{heartbeat(6, 60) | received_at: at(70)},
        %{heartbeat(7, 90) | received_at: at(500)}
      ]

      offsets =
        for order <- [beats, Enum.reverse(beats), [Enum.at(beats, 2), Enum.at(beats, 0)]] do
          Enum.reduce(order, {@run, %{}}, fn beat, {run, latest} ->
            %{run: run, latest: latest} = Fold.fold(run, [beat], latest)
            {run, latest}
          end)
          |> elem(0)
          |> Map.get(:clock_offset_ms)
        end

      assert offsets == [64_000, 64_000, 115_000]
    end

    test "a replayed beat never moves the offset, and revives no lost run" do
      lost =
        %{@run | state: "lost", lost_at: at(400), last_heartbeat_at: at(105)}
        |> Map.put(:clock_offset_ms, 100_000)

      # Recorded at 200 s, sent at 3600 s.
      replayed = %{heartbeat(9, 200, 30, 200) | received_at: at(3600)}
      %{run: run} = Fold.fold(lost, [replayed], %{"dev.qory.run.heartbeat" => 4})

      assert run.clock_offset_ms == 100_000
      assert run.last_heartbeat_at == at(600)
      assert run.state == "lost"
      assert run.lost_at == at(400)

      # Nor a run whose start has not arrived.
      pending = Map.put(@run, :clock_offset_ms, 100_000)
      assert Fold.fold(pending, [replayed]).run.state == "pending"
    end

    test "a lost run revives on a beat heard within three of its intervals of its arrival" do
      lost = %{@run | state: "lost", lost_at: at(10)} |> Map.put(:clock_offset_ms, 100_000)

      # Heard at 3 × 30 s before its arrival, then a moment earlier.
      within = %{heartbeat(7, 120, 30, 3000) | received_at: at(3490)}
      without = %{within | received_at: at(3491)}

      assert Fold.fold(lost, [within]).run.state == "running"
      assert Fold.fold(lost, [without]).run.state == "lost"
    end

    test "a run a gateway opened takes its ping's offset, whichever comes first; a session's does not" do
      ping =
        event(
          1,
          "ping",
          %{"forager_version" => "v0.6.0", "contract_version" => 1, "interval_seconds" => 30}
        )

      ping = %{ping | received_at: at(51)}
      gateway = started(2, %{"opened_by" => "gateway", "credential" => "issuer"})

      assert Fold.fold(@run, [ping, gateway]).run.clock_offset_ms == 50_000

      %{run: run} = Fold.fold(@run, [gateway], %{}, nil)
      assert Map.get(run, :clock_offset_ms) == nil
      assert Fold.fold(run, [ping], %{"dev.qory.run.started" => 2}).run.clock_offset_ms == 50_000

      # Across passes, the projector hands over the offset of the pings already projected.
      assert Fold.fold(@run, [gateway], %{"dev.qory.ping" => 1}, 50_000).run.clock_offset_ms ==
               50_000

      for credential <- ["none", "issuer"] do
        session = started(2, %{"credential" => credential})
        assert Map.get(Fold.fold(@run, [ping, session]).run, :clock_offset_ms) == nil
      end
    end
  end

  describe "dev.qory.run.log" do
    test "decodes the bytes, in sequence order" do
      events = [
        event(7, "run.log", %{"stream" => "stderr", "bytes" => Base.encode64("two\n")}),
        event(5, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64(<<0, 255>>)})
      ]

      assert %{log_chunks: chunks, skipped_log_chunks: 0} = Fold.fold(@run, events)

      assert chunks == [
               %{sequence: 5, stream: "stdout", bytes: <<0, 255>>},
               %{sequence: 7, stream: "stderr", bytes: "two\n"}
             ]
    end

    test "bytes that are not base64 are skipped and counted" do
      events = [
        event(5, "run.log", %{"stream" => "stdout", "bytes" => "not base64!"}),
        event(6, "run.log", %{"stream" => "stdout"}),
        event(7, "run.log", %{"stream" => "elsewhere", "bytes" => ""})
      ]

      assert %{log_chunks: [], skipped_log_chunks: 3} = Fold.fold(@run, events)
    end
  end

  describe "dev.qory.run.egress" do
    test "one delta per host, port and path, counting every attempt once" do
      events = [
        egress(6, %{}),
        egress(7, %{"decision" => "denied", "outcome" => "refused", "rule" => ""}),
        egress(8, %{
          "method" => "HTTPS",
          "path" => "/v1/messages",
          "request_method" => "POST"
        }),
        egress(9, %{"port" => 8443})
      ]

      %{connections: connections} = Fold.fold(@run, events)

      assert map_size(connections) == 3

      assert connections[{"api.example.com", 443, ""}] == %{
               method: "CONNECT",
               attempts: 2,
               allowed: 1,
               denied: 1,
               last_decision: "denied",
               last_rule: "",
               last_outcome: "refused",
               last_mode: "enforce",
               last_path_rule: nil,
               last_credential: nil,
               last_request_method: nil,
               last_tool: nil,
               last_status: nil,
               last_sequence: 7,
               first_seen_at: at(6),
               last_seen_at: at(7)
             }

      assert %{attempts: 1, method: "HTTPS", last_request_method: "POST"} =
               connections[{"api.example.com", 443, "/v1/messages"}]

      assert %{attempts: 1} = connections[{"api.example.com", 8443, ""}]
    end

    test "the highest sequence is the last, at equal times and against the clock" do
      events = [
        egress(6, %{"outcome" => "connected"}, 50),
        egress(7, %{"outcome" => "dial_failed"}, 50),
        egress(8, %{"outcome" => "refused", "decision" => "denied"}, 10)
      ]

      for order <- [events, Enum.reverse(events)] do
        %{connections: connections} = Fold.fold(@run, order)

        assert %{
                 last_sequence: 8,
                 last_outcome: "refused",
                 last_decision: "denied",
                 attempts: 3,
                 first_seen_at: first,
                 last_seen_at: last
               } = connections[{"api.example.com", 443, ""}]

        assert {first, last} == {at(10), at(50)}
      end
    end

    test "a port outside 0..65535 is not a connection, and long names are cut" do
      path = "/" <> String.duplicate("é", 4000)

      %{connections: connections} =
        Fold.fold(@run, [
          egress(6, %{"port" => 65_536}),
          egress(7, %{"port" => -1}),
          egress(8, %{"port" => 9_999_999_999_999_999_999}),
          egress(9, %{"path" => path, "host" => String.duplicate("h", 300)})
        ])

      assert [{{host, 443, cut}, %{attempts: 1}}] = Map.to_list(connections)
      assert byte_size(host) == 255
      assert byte_size(cut) <= 1024
      assert String.valid?(cut)
    end

    test "a tool invocation is a connection that names its tool and what the tool answered" do
      invocation = %{
        "host" => "files.tools.internal",
        "method" => "HTTPS",
        "request_method" => "PUT",
        "path" => "/media/acme/shop/checkout.png",
        "path_rule" => "/media/acme/shop/*",
        "tool" => "files",
        "request_id" => "8d0c3f6a1b2e4d5f9a7c6b5e4d3c2b1a",
        "status" => 200,
        "rule" => "files.tools.internal"
      }

      %{connections: connections} =
        Fold.fold(@run, [
          egress(6, invocation),
          egress(7, %{"host" => "api.example.com", "method" => "HTTPS", "status" => 503})
        ])

      assert %{
               attempts: 1,
               allowed: 1,
               method: "HTTPS",
               last_request_method: "PUT",
               last_path_rule: "/media/acme/shop/*",
               last_tool: "files",
               last_status: 200,
               last_outcome: "connected"
             } = connections[{"files.tools.internal", 443, "/media/acme/shop/checkout.png"}]

      # A plain host that answered: a status and no tool.
      assert %{last_tool: nil, last_status: 503} = connections[{"api.example.com", 443, ""}]
    end

    test "the last attempt's tool and status win; a refused one clears the status" do
      base = %{"host" => "files.tools.internal", "method" => "HTTPS", "path" => "/a"}

      events = [
        egress(6, Map.merge(base, %{"tool" => "files", "status" => 201})),
        egress(
          7,
          Map.merge(base, %{
            "tool" => "files",
            "decision" => "denied",
            "outcome" => "refused",
            "path_rule" => ""
          })
        )
      ]

      for order <- [events, Enum.reverse(events)] do
        %{connections: %{{"files.tools.internal", 443, "/a"} => connection}} =
          Fold.fold(@run, order)

        assert %{last_sequence: 7, last_tool: "files", last_status: nil, denied: 1, allowed: 1} =
                 connection
      end
    end

    test "a later attempt that names no tool clears the tool, within one pass" do
      base = %{"host" => "files.tools.internal", "method" => "HTTPS", "path" => "/a"}

      events = [
        egress(6, Map.merge(base, %{"tool" => "files", "status" => 200})),
        egress(7, base)
      ]

      for order <- [events, Enum.reverse(events)] do
        %{connections: %{{"files.tools.internal", 443, "/a"} => connection}} =
          Fold.fold(@run, order)

        assert %{last_sequence: 7, last_tool: nil, last_status: nil, attempts: 2} = connection
      end
    end

    test "a tool or a status of the wrong shape reads as absent" do
      for {tool, status} <- [{"", 99}, {7, 600}, {nil, "200"}, {["files"], 200.0}] do
        %{connections: connections} =
          Fold.fold(@run, [egress(6, %{"tool" => tool, "status" => status})])

        assert %{last_tool: nil, last_status: nil} = connections[{"api.example.com", 443, ""}]
      end

      %{connections: connections} =
        Fold.fold(@run, [egress(6, %{"tool" => String.duplicate("t", 300)})])

      assert byte_size(connections[{"api.example.com", 443, ""}].last_tool) == 255
    end

    test "an event without a host or a port is not a connection" do
      assert %{connections: connections} =
               Fold.fold(@run, [egress(6, %{"host" => nil}), egress(7, %{"port" => "443"})])

      assert connections == %{}
    end
  end

  describe "dev.qory.run.exited" do
    test "maps the contract's states onto the run's" do
      for {data, state} <- [
            {%{"state" => "succeeded"}, "succeeded"},
            {%{"state" => "failed", "exit_code" => 2}, "failed"},
            {%{"state" => "failed", "reason" => "timeout"}, "timed_out"},
            {%{"state" => "failed", "reason" => "gateway_lost", "exit_code" => -1}, "failed"},
            {%{"state" => "evaporated", "reason" => "unheard of"}, "failed"}
          ] do
        %{run: run} = Fold.fold(%{@run | state: "running"}, [exited(18, data)])

        assert run.state == state
        assert run.exited_at == at(18)
        assert run.reason == data["reason"]
        assert run.exit_code == Map.get(data, "exit_code", 0)
        assert run.duration_ms == 1200
      end
    end

    test "integers outside their columns are read as absent" do
      huge = 9_999_999_999_999_999_999

      for data <- [
            %{"exit_code" => huge, "duration_ms" => huge},
            %{"exit_code" => 2_147_483_648, "duration_ms" => -1},
            %{"exit_code" => 1.5, "duration_ms" => "long"}
          ] do
        %{run: run} = Fold.fold(@run, [exited(18, Map.put(data, "state", "failed"))])
        assert {run.state, run.exit_code, run.duration_ms} == {"failed", nil, nil}
      end

      ping = event(1, "ping", %{"contract_version" => huge, "forager_version" => "v"})
      assert Fold.fold(@run, [ping]).run.contract_version == nil

      assert Fold.fold(@run, [heartbeat(5, huge)]).run.elapsed_seconds == nil
    end

    test "keeps the signal" do
      data = %{"state" => "failed", "exit_code" => -1, "signal" => "SIGKILL"}
      assert Fold.fold(@run, [exited(18, data)]).run.signal == "SIGKILL"
    end

    test "wins over lost, and the run is no longer lost" do
      lost = %{@run | state: "lost", lost_at: at(100)}
      %{run: run} = Fold.fold(lost, [exited(18, %{"state" => "succeeded"})])

      assert run.state == "succeeded"
      assert run.lost_at == nil
    end

    test "an exit without a state, a gateway's, reads its reason" do
      for {reason, state} <- [
            {"quiet", "ended"},
            {"credential_expired", "ended"},
            {"run_ended_at_issuer", "ended"},
            {"timeout", "timed_out"},
            {"run_closed", "failed"},
            {"gateway_lost", "failed"},
            {"session_lost", "failed"},
            {"unheard of", "failed"},
            {nil, "failed"}
          ] do
        data =
          %{"reason" => reason, "duration_ms" => 1_804_900}
          |> Map.merge(if reason == "quiet", do: %{"quiet_seconds" => 1800}, else: %{})
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        %{run: run} = Fold.fold(%{@run | state: "running"}, [event(18, "run.exited", data)])

        assert run.state == state, inspect(reason)
        assert run.reason == reason
        assert run.exit_code == nil
        assert run.exited_at == at(18)
        assert run.duration_ms == 1_804_900
      end
    end

    test "with a state, the state decides, whatever the reason" do
      for {data, state} <- [
            {%{"state" => "failed", "exit_code" => -1, "reason" => "quiet"}, "failed"},
            {%{"state" => "failed", "exit_code" => -1, "reason" => "credential_expired"},
             "failed"},
            {%{"state" => "failed", "exit_code" => -1, "reason" => "run_ended_at_issuer"},
             "failed"},
            {%{"state" => "failed", "exit_code" => -1, "reason" => "run_closed"}, "failed"},
            {%{"state" => "failed", "exit_code" => -1, "reason" => "session_lost"}, "failed"},
            {%{"state" => "succeeded", "reason" => "credential_expired"}, "succeeded"},
            {%{"state" => "failed", "exit_code" => -1, "reason" => "timeout"}, "timed_out"}
          ] do
        %{run: run} = Fold.fold(%{@run | state: "running"}, [exited(18, data)])
        assert run.state == state, inspect(data)
      end
    end

    test "keeps the quiet period of a quiet exit, and reads one out of range as absent" do
      quiet = fn seconds ->
        data = %{"reason" => "quiet", "quiet_seconds" => seconds, "duration_ms" => 5}
        Fold.fold(%{@run | state: "running"}, [event(18, "run.exited", data)]).run
      end

      assert quiet.(1800).quiet_seconds == 1800
      assert quiet.(1).quiet_seconds == 1

      for seconds <- [0, -1, 2_147_483_648, "1800", 1.5] do
        assert quiet.(seconds).quiet_seconds == nil
        assert quiet.(seconds).state == "ended"
      end

      assert Fold.fold(@run, [exited(18, %{"state" => "succeeded"})]).run.quiet_seconds == nil
    end

    test "an ended run is final: a later start or heartbeat does not undo it" do
      data = %{"reason" => "quiet", "quiet_seconds" => 1800, "duration_ms" => 5}
      %{run: run} = Fold.fold(%{@run | state: "running"}, [event(18, "run.exited", data)])
      assert run.state == "ended"

      %{run: run} = Fold.fold(run, [started(2)], %{"dev.qory.run.exited" => 18})
      assert run.state == "ended"

      %{run: run} = Fold.fold(run, [heartbeat(20, 600)], %{"dev.qory.run.exited" => 18})
      assert run.state == "ended"
    end
  end

  describe "dev.qory.session.result" do
    test "adds the cost the session reported to the run's, once per result" do
      events = [
        event(4, "session.result", %{"outcome" => "success", "cost_usd" => 0.8412}),
        event(9, "session.result", %{"outcome" => "error_max_turns", "cost_usd" => 1})
      ]

      %{run: run} = Fold.fold(@run, events)
      assert Decimal.equal?(run.cost_usd, Decimal.new("1.8412"))

      # One pass or two, the sum is the same: an event is folded once.
      %{run: run, latest: latest} = Fold.fold(@run, Enum.take(events, 1))
      %{run: run} = Fold.fold(run, Enum.drop(events, 1), latest)
      assert Decimal.equal?(run.cost_usd, Decimal.new("1.8412"))
    end

    test "a result without a cost, or with one that is not a number, leaves the run unrecorded" do
      for data <- [
            %{"outcome" => "success"},
            %{"cost_usd" => "free"},
            %{"cost_usd" => nil},
            %{"cost_usd" => -0.5},
            %{"cost_usd" => 1.0e12}
          ] do
        assert %{run: %{cost_usd: nil}} = Fold.fold(@run, [event(4, "session.result", data)])
      end

      # A zero is a cost that was reported: zero, not unrecorded.
      assert %{run: %{cost_usd: zero}} =
               Fold.fold(@run, [event(4, "session.result", %{"cost_usd" => 0})])

      assert Decimal.equal?(zero, 0)
    end
  end

  test "session events and unknown types fold nothing" do
    events = [
      event(4, "session.started", %{"session_id" => "s"}),
      event(5, "something.new", %{"anything" => 1}),
      %{sequence: 6, type: "com.example.other", data: %{}, time: at(6)}
    ]

    assert %Fold{run: @run, connections: %{}, log_chunks: []} = Fold.fold(@run, events)
  end

  test "any order and any split into passes gives the same run" do
    events = [
      event(1, "ping", %{"forager_version" => "v0.4.0", "contract_version" => 1}),
      started(2),
      event(3, "run.policy_applied", %{"digest" => "first"}),
      # Every heartbeat at the same instant on both clocks: only the sequence can decide.
      heartbeat(4, 30, 30, 30),
      event(5, "run.policy_applied", %{"digest" => "second"}),
      heartbeat(6, 60, 15, 30),
      heartbeat(7, 90, 45, 30),
      event(8, "ping", %{"forager_version" => "v0.4.2", "contract_version" => 1}),
      exited(9, %{"state" => "failed", "reason" => "timeout"})
    ]

    expected = Fold.fold(@run, events).run

    for seed <- 1..50 do
      :rand.seed(:exsss, {seed, seed, seed})

      {run, _latest} =
        events
        |> Enum.shuffle()
        |> Enum.chunk_every(Enum.random(1..3))
        |> Enum.reduce({@run, %{}}, fn pass, {run, latest} ->
          %{run: run, latest: latest} = Fold.fold(run, pass, latest)
          {run, latest}
        end)

      assert run == expected
    end
  end
end
