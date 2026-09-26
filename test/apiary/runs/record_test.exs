defmodule Apiary.Runs.RecordTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Projector, Record, Run}
  alias Apiary.Runs.Record.Timeline
  alias Mix.Tasks.Apiary.Demo

  defp demo(scope, name, now \\ DateTime.utc_now()) do
    %{access_key: access_key} = access_key_fixture(scope)
    file = Enum.find(Demo.files(), &(&1 |> Path.dirname() |> Path.basename() == name))
    {:ok, run} = Demo.replay(access_key, file, now)
    run
  end

  defp projected(scope, events \\ record()) do
    run = run_fixture(scope)
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  setup do
    %{scope: scope_fixture()}
  end

  describe "fetch_run/2" do
    test "finds a run of the workspace by its subject", %{scope: scope} do
      run = run_fixture(scope)
      assert {:ok, %Run{id: id}} = Record.fetch_run(scope, run.run_id)
      assert id == run.id
    end

    test "a run of another workspace, an unknown subject and a malformed id are not found", %{
      scope: scope
    } do
      other = run_fixture(scope_fixture())

      assert Record.fetch_run(scope, other.run_id) == :error
      assert Record.fetch_run(scope, Ecto.UUID.generate()) == :error
      assert Record.fetch_run(scope, "0191f2a4") == :error
      assert Record.fetch_run(scope, <<0::128>>) == :error
      assert Record.fetch_run(scope, nil) == :error
    end
  end

  describe "with a run of another workspace handed in" do
    test "every read is empty", %{scope: scope} do
      theirs = scope_fixture()
      run = projected(theirs)

      assert Record.timeline(scope, run).items == []
      assert %{rows: [], total: 0} = Record.connections(scope, run)
      assert %{all: 0, attempts: 0} = Record.connection_counts(scope, run)
      assert Record.background(scope, run) == []
      assert Record.session_id(scope, run) == nil
      assert Record.policy(scope, run) == nil
      assert %{chunks: 0, bytes: 0, through: 0, streams: []} = Record.log_summary(scope, run)
      assert Record.log_through(scope, run, 0) == {0, true}
      assert Record.reload(scope, run) == nil

      refute Record.timeline(theirs, run).items == []
    end
  end

  describe "timeline/2 and items/5 on the demo session" do
    setup %{scope: scope} do
      %{run: demo(scope, "session-with-subagents")}
    end

    test "three lanes, bracketed by the subagents' start and finish", %{scope: scope, run: run} do
      index = Record.timeline(scope, run)

      assert [
               %{id: "main", rail: 0},
               %{
                 id: "agent-demo-a1",
                 type: "Explore",
                 rail: 1,
                 color: :a,
                 started_seq: 21,
                 finished_seq: 36
               },
               %{
                 id: "agent-demo-a2",
                 type: "general-purpose",
                 rail: 2,
                 color: :b,
                 started_seq: 22,
                 finished_seq: 49
               }
             ] = index.lanes

      assert index.rails == 3
      assert index.background == %{tasks: [], count: 0}
      assert index.through == 101
      assert index.hook_events > 0
    end

    test "a denied connection sits inside the one call that was open", %{scope: scope, run: run} do
      index = Record.timeline(scope, run)
      assert index.by_seq[59] == 58
      assert index.by_seq[85] == 84

      [npm] = Record.items(scope, run, Enum.filter(index.items, &(&1.seq == 58)))

      assert %{
               kind: :tool,
               tool: "Bash",
               status: :failed,
               denied_inside: true,
               summary: {:text, "npm install @acme/ui-steps --registry https://registry.example"},
               connections: [
                 %{host: "registry.example", decision: "denied", outcome: "refused", rule: nil}
               ]
             } = npm

      # While the two Task calls were open, a connection stands between items.
      assert %{kind: kind, open_calls: 2} = Enum.find(index.items, &(23 in &1.seqs))
      assert kind in [:connection, :connection_group]
    end

    test "every item builds, in sequence order, and none is a heartbeat or a log chunk", %{
      scope: scope,
      run: run
    } do
      index = Record.timeline(scope, run)
      items = Record.items(scope, run, index.items)

      assert length(items) == length(index.items)
      assert Enum.map(items, & &1.sequence) == Enum.sort(Enum.map(items, & &1.sequence))
      assert %{kind: :run_started} = hd(items)
      assert %{kind: :run_exited, exit_code: 0} = List.last(items)

      assert %{kind: :result, cost_usd: 0.8412, turns: 14} =
               Enum.find(items, &(&1.kind == :result))
    end
  end

  describe "connections/2" do
    test "denied destinations first, each with the fields of its last attempt", %{scope: scope} do
      run = demo(scope, "session-with-subagents")

      assert %{rows: connections, total: total, page: 1, pages: 1} =
               Record.connections(scope, run)

      assert total == length(connections)

      assert %{all: ^total, denied: 2, attempts: attempts} = Record.connection_counts(scope, run)
      assert attempts == connections |> Enum.map(& &1.attempts) |> Enum.sum()

      assert %{rows: denied, total: 2} = Record.connections(scope, run, decision: "denied")
      assert Enum.all?(denied, &(&1.denied > 0))

      assert [%{denied: d1}, %{denied: d2} | rest] = connections
      assert d1 > 0 and d2 > 0
      assert Enum.all?(rest, &(&1.denied == 0))

      git = Enum.find(connections, &(&1.path == "/acme/shop.git/git-upload-pack"))

      assert %{
               host: "git.example.com",
               method: "HTTPS",
               request_method: "POST",
               decision: "allowed",
               rule: "git.example.com",
               path_rule: "/acme/shop.git/*",
               credential: "forge-token",
               mode: "enforce",
               outcome: "connected"
             } = git

      assert %{outcome: "dial_failed", decision: "allowed"} =
               Enum.find(connections, &(&1.host == "cdn.packages.example.com"))
    end
  end

  describe "tool invocations" do
    test "a connection names the tool whose host its last attempt was for and what answered", %{
      scope: scope
    } do
      run = projected(scope, tool_record())

      assert %{rows: rows, total: 3} = Record.connections(scope, run)

      # Denied first: the request a path rule refused never reached the tool, and names
      # the tool whose host it was for.
      assert [
               %{
                 host: "files.tools.internal",
                 path: "/media/acme/other/checkout.png",
                 decision: "denied",
                 tool: "files",
                 status: nil
               }
               | _
             ] = rows

      assert %{tool: "files", status: 201, attempts: 2, request_method: "PUT"} =
               Enum.find(rows, &(&1.path == "/media/acme/shop/checkout.png"))

      assert %{tool: nil, status: nil} = Enum.find(rows, &(&1.host == "api.example.com"))
    end

    test "the policy in force lists the run's tools and the hosts they serve", %{scope: scope} do
      run = projected(scope, tool_record())

      assert %{
               tools: [%{"name" => "files", "hosts" => ["files.tools.internal"]}],
               terminated: ["files.tools.internal"],
               credentials: []
             } = Record.policy(scope, run)

      # Bounded like the credentials: twenty tools of ten hosts, names and hosts cut.
      many =
        for n <- 1..30,
            do: %{
              "name" => "t#{n}" <> String.duplicate("x", 200),
              "hosts" => for(m <- 1..20, do: "h#{m}.tools.internal")
            }

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied", tool_policy_data(%{"tools" => [7, %{"name" => 1} | many]})}
        ])

      assert %{tools: tools} = Record.policy(scope, run)
      assert length(tools) == 20
      assert %{"name" => name, "hosts" => hosts} = hd(tools)
      assert String.starts_with?(name, "t1x") and String.length(name) == 120
      assert length(hosts) == 10

      run = projected(scope)
      assert %{tools: []} = Record.policy(scope, run)
    end

    test "the policy in force reads each credential's and each tool's argument", %{
      scope: scope
    } do
      # "é" as one code point (two bytes), and as "e" and a combining accent: two code
      # points and one grapheme. The database counts code points, and so does the cut.
      e = "é"
      combining = "é"

      credentials =
        [
          %{
            "name" => "forge-token",
            "argument" => "acme/shop",
            "hosts" => ["forge.example"],
            "scheme" => "basic"
          },
          %{
            "name" => "forge-token",
            "argument" => "acme/shop",
            "hosts" => ["api.forge.example"],
            "scheme" => "bearer"
          },
          %{"name" => "model", "hosts" => ["api.model.example"], "scheme" => "header"},
          %{"name" => "whole", "argument" => String.duplicate("w", 4096), "hosts" => []},
          %{"name" => "long", "argument" => String.duplicate("l", 5000), "hosts" => []},
          %{"name" => "accent", "argument" => String.duplicate(e, 5000), "hosts" => []},
          %{
            "name" => "combining",
            "argument" => String.duplicate(combining, 3000),
            "hosts" => []
          },
          %{"name" => "empty", "argument" => "", "hosts" => []},
          %{"name" => "number", "argument" => 7, "hosts" => []}
        ]

      data =
        tool_policy_data(%{
          "credentials" => credentials,
          "tools" => [
            %{
              "name" => "files",
              "argument" => "acme/shop",
              "hosts" => ["files.tools.internal"]
            },
            %{"name" => "bare", "hosts" => []}
          ]
        })

      run =
        projected(scope, [{1, "run.started", started_data()}, {2, "run.policy_applied", data}])

      assert %{credentials: read, tools: tools} = policy = Record.policy(scope, run)

      # One entry per use, as the event lists them; the argument whole up to the contract's
      # 4096 code points, cut there visibly, and nil when the entry has no non-empty string.
      assert read == [
               %{
                 "name" => "forge-token",
                 "argument" => "acme/shop",
                 "hosts" => ["forge.example"]
               },
               %{
                 "name" => "forge-token",
                 "argument" => "acme/shop",
                 "hosts" => ["api.forge.example"]
               },
               %{"name" => "model", "argument" => nil, "hosts" => ["api.model.example"]},
               %{"name" => "whole", "argument" => String.duplicate("w", 4096), "hosts" => []},
               %{
                 "name" => "long",
                 "argument" => String.duplicate("l", 4096) <> "…",
                 "hosts" => []
               },
               %{
                 "name" => "accent",
                 "argument" => String.duplicate(e, 4096) <> "…",
                 "hosts" => []
               },
               %{
                 "name" => "combining",
                 "argument" => String.duplicate(combining, 2048) <> "…",
                 "hosts" => []
               },
               %{"name" => "empty", "argument" => nil, "hosts" => []},
               %{"name" => "number", "argument" => nil, "hosts" => []}
             ]

      assert tools == [
               %{
                 "name" => "files",
                 "argument" => "acme/shop",
                 "hosts" => ["files.tools.internal"]
               },
               %{"name" => "bare", "argument" => nil, "hosts" => []}
             ]

      # Counted as the page groups them: the two uses of forge-token are one; empty and
      # number have no argument, each an entry of its own name.
      assert policy.credentials_count == 8
      assert policy.tools_count == 2
    end

    test "the counts of credentials and tools cover the entries past the twentieth", %{
      scope: scope
    } do
      # Fifteen credentials of two uses each: the first twenty uses are ten credentials.
      uses =
        for n <- 1..15, host <- ["a", "b"] do
          %{"name" => "c#{n}", "argument" => "acme/r#{n}", "hosts" => ["#{host}#{n}.example"]}
        end

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied",
           tool_policy_data(%{
             "credentials" => uses ++ ["junk", %{"hosts" => []}],
             "tools" => for(n <- 1..25, do: %{"name" => "t#{n}", "hosts" => []})
           })}
        ])

      policy = Record.policy(scope, run)
      assert length(policy.credentials) == 20
      assert policy.credentials_count == 15
      assert length(policy.tools) == 20
      assert policy.tools_count == 25
    end

    test "the timeline reads tool invocations as calls, and groups a tool's allowed calls", %{
      scope: scope
    } do
      run = projected(scope, tool_record())
      index = Record.timeline(scope, run)
      items = Record.items(scope, run, index.items)

      assert Enum.map(items, & &1.kind) ==
               [:run_started, :policy_applied, :connection, :connection_group, :connection] ++
                 [:run_exited]

      assert %{tools: [%{name: "files", hosts: ["files.tools.internal"]}]} =
               Enum.find(items, &(&1.kind == :policy_applied))

      assert %{connection: %{tool: nil, host: "api.example.com"}} = Enum.at(items, 2)

      assert %{
               tool: "files",
               host: "files.tools.internal",
               connections_count: 2,
               connections: [
                 %{tool: "files", status: 200, request_id: "8d0c3f6a1b2e4d5f9a7c6b5e4d3c2b1a"},
                 %{tool: "files", status: 201, request_id: "0a1b2c3d4e5f60718293a4b5c6d7e8f9"}
               ]
             } = Enum.at(items, 3)

      assert %{
               connection: %{
                 tool: "files",
                 decision: "denied",
                 status: nil,
                 request_id: "1f2e3d4c5b6a79880a9b8c7d6e5f4a3b"
               }
             } = Enum.at(items, 4)
    end

    test "allowed calls of one tool do not group with a plain connection to the host", %{
      scope: scope
    } do
      # Not what a runner sends (a tool's host always goes to the tool), but a group must
      # never hide whose calls it holds.
      run =
        projected(scope, [
          {1, "run.egress", tool_invocation_data()},
          {2, "run.egress", tool_invocation_data() |> Map.delete("tool")},
          {3, "run.egress", tool_invocation_data(%{"tool" => "other"})}
        ])

      assert [%{kind: :connection}, %{kind: :connection}, %{kind: :connection}] =
               Record.timeline(scope, run).items
    end

    test "the query cuts what Timeline.slim/2 cuts, on a run with tools", %{scope: scope} do
      run =
        projected(scope, [
          {8, "run.policy_applied",
           tool_policy_data(%{
             "tools" => [
               %{"name" => String.duplicate("n", 200), "hosts" => ["a", 7, "b"]},
               %{"name" => "bare"},
               %{"name" => "short", "argument" => "acme/shop", "hosts" => ["s"]},
               %{"name" => "long", "argument" => String.duplicate("l", 4096), "hosts" => []},
               %{"name" => "accent", "argument" => String.duplicate("é", 300)},
               %{"name" => "combining", "argument" => String.duplicate("é", 200)},
               %{"name" => "number", "argument" => 7},
               "junk"
             ]
           })},
          {9, "run.egress", tool_invocation_data(%{"status" => "200", "request_id" => 5})}
          | tool_record()
        ])

      index = Record.timeline(scope, run)

      whole =
        Repo.all(
          from e in Apiary.Runs.Event,
            where: e.run_id == ^run.id,
            select: %{sequence: e.sequence, type: e.type, time: e.time, data: e.data}
        )
        |> Map.new(&{&1.sequence, Timeline.slim(&1)})

      items = Record.items(scope, run, index.items)
      assert items == Timeline.build(index.items, whole)

      # The timeline cuts an argument at 256 code points, "…" after; the Details tab does not.
      arguments =
        for %{kind: :policy_applied, seq: 8, tools: tools} <- items,
            tool <- tools,
            into: %{},
            do: {tool.name, tool.argument}

      assert arguments["short"] == "acme/shop"
      assert arguments["long"] == String.duplicate("l", 256) <> "…"
      assert arguments["accent"] == String.duplicate("é", 256) <> "…"
      assert arguments["combining"] == String.duplicate("é", 128) <> "…"
      assert arguments["number"] == nil and arguments["bare"] == nil
    end
  end

  describe "the log" do
    test "summary, through and pages", %{scope: scope} do
      run = projected(scope)

      assert %{chunks: 2, bytes: 12, through: 9, streams: ["stderr", "stdout"]} =
               Record.log_summary(scope, run)

      assert Record.log_through(scope, run, 0) == {9, true}
      assert Record.log_through(scope, run, 0, limit: 1) == {5, false}
      assert Record.log_through(scope, run, 5) == {9, true}
      assert Record.log_through(scope, run, 9) == {9, true}
      assert Record.log_through(scope, run, 0, stream: "stdout") == {5, true}
      assert Record.log_through(scope, run, 0, limit: :all) == {9, true}
      # Short of a sequence: the chunks below it, and whether they were all of them.
      assert Record.log_through(scope, run, 0, before: 9) == {5, true}
      assert Record.log_through(scope, run, 0, before: 5) == {0, true}
      assert Record.log_through(scope, run, 0, before: 9, limit: 1) == {5, false}

      collect = fn bytes, acc -> {:cont, [acc, bytes]} end

      assert scope |> Record.log_pages(run, 0, 9, [], collect) |> IO.iodata_to_binary() ==
               "building\n" <> <<255, 0, 10>>

      assert scope |> Record.log_pages(run, 5, 9, [], collect) |> IO.iodata_to_binary() ==
               <<255, 0, 10>>

      assert scope |> Record.log_pages(run, 0, 5, [], collect) |> IO.iodata_to_binary() ==
               "building\n"

      assert scope
             |> Record.log_pages(run, 0, 9, [], collect, stream: "stderr")
             |> IO.iodata_to_binary() ==
               <<255, 0, 10>>
    end

    test "a long log comes in pages and a reader can stop", %{scope: scope} do
      run = run_fixture(scope)

      events =
        for n <- 1..450,
            do: {n, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("#{n}\n")}}

      events_fixture(run, events)
      {:ok, run} = Projector.project(run)

      pages =
        Record.log_pages(scope, run, 0, 450, [], fn bytes, acc ->
          {:cont, [length(bytes) | acc]}
        end)

      assert Enum.reverse(pages) == [200, 200, 50]

      assert Record.log_pages(scope, run, 0, 450, 0, fn _bytes, acc -> {:halt, acc + 1} end) == 1
    end
  end

  describe "policy/2 and session_id/2" do
    test "the last policy applied and the session", %{scope: scope} do
      run = projected(scope)

      assert %{
               sequence: 11,
               source: "fetched",
               mode: "enforce",
               allow: ["api.example.com"],
               allow_count: 1,
               terminated: [],
               credentials: []
             } = Record.policy(scope, run)

      assert Record.session_id(scope, run) == "session-1"
      assert Record.policy(scope, run_fixture(scope)) == nil
    end
  end

  describe "the query cuts what Timeline.slim/2 cuts" do
    test "on every event of every demo run, the rows are the slim events", %{scope: scope} do
      for name <- ~w(session-with-subagents failed-run running) do
        run = demo(scope, name)
        index = Record.timeline(scope, run)

        whole =
          Repo.all(
            from e in Apiary.Runs.Event,
              where: e.run_id == ^run.id,
              select: %{sequence: e.sequence, type: e.type, time: e.time, data: e.data}
          )
          |> Map.new(&{&1.sequence, Timeline.slim(&1)})

        # jsonb_pretty and Jason indent differently: the wells of JSON are compared parsed.
        strip = fn items ->
          for item <- items do
            wells =
              for well <- Map.get(item, :wells, []) do
                if well.format == :json,
                  do: %{well | text: Jason.decode!(well.text), bytes: nil},
                  else: well
              end

            if is_map_key(item, :wells), do: %{item | wells: wells}, else: item
          end
        end

        rows = Record.items(scope, run, index.items)
        assert strip.(rows) == strip.(Timeline.build(index.items, whole)), name
      end
    end

    test "policy, credentials and lists are cut to a bounded number of bounded strings", %{
      scope: scope
    } do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "run.policy_applied",
           %{
             "mode" => "enforce",
             "source" => "config",
             "allow" => for(n <- 1..500, do: "h#{n}." <> String.duplicate("x", 1000)) ++ [7, %{}],
             "deny" => for(n <- 1..60, do: "d#{n}." <> String.duplicate("y", 300)) ++ [7],
             "terminated" => "not a list",
             "credentials" =>
               for(
                 n <- 1..100,
                 do: %{"name" => "c#{n}", "hosts" => for(m <- 1..100, do: "host#{m}.example")}
               ) ++
                 ["junk"]
           }}
        ])

      policy = Record.policy(scope, run)

      assert length(policy.allow) == 50
      assert policy.allow_count == 502
      assert Enum.all?(policy.allow, &(String.length(&1) <= 255))
      assert length(policy.deny) == 50
      assert policy.deny_count == 61
      assert Enum.all?(policy.deny, &(String.length(&1) <= 255))
      assert policy.terminated == [] and policy.terminated_count == 0
      assert length(policy.credentials) == 20
      assert policy.credentials_count == 100
      assert %{"name" => "c1", "hosts" => hosts} = hd(policy.credentials)
      assert length(hosts) == 10
    end

    test "data of the wrong shape reads as absent", %{scope: scope} do
      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.tool_started",
           %{"tool" => 7, "tool_use_id" => "t", "input" => "not a map"}},
          {3, "session.tool_finished",
           %{
             "tool_use_id" => "t",
             "response" => 12,
             "duration_ms" => "soon",
             "interrupted" => "yes"
           }},
          {4, "session.result",
           %{"turns" => 1.5, "cost_usd" => "free", "result" => %{}, "duration_ms" => 1.0e300}},
          {5, "run.egress", %{"host" => 5, "port" => "https", "decision" => []}}
        ])

      index = Record.timeline(scope, run)
      items = Record.items(scope, run, index.items)

      assert %{
               tool: "tool",
               summary: nil,
               duration_ms: nil,
               wells: [%{label: "response", format: :json, text: "12"}]
             } =
               Enum.find(items, &(&1.kind == :tool))

      assert %{turns: nil, cost_usd: nil, duration_ms: nil, text: nil} =
               Enum.find(items, &(&1.kind == :result))

      assert %{connection: %{host: "n/a", port: nil, decision: nil}} =
               Enum.find(items, &(&1.kind == :connection))
    end
  end

  describe "read budgets" do
    # What a read costs this server is set by the number of rows, never by what a runner
    # put in them. The window of 300 calls with 512 KiB payloads, which writes some
    # 460 MiB, is in `Apiary.Runs.RecordBudgetTest`, a module that runs alone.
    test "Show all reads one item, cut at 512 KB by the database", %{scope: scope} do
      huge = String.duplicate("a", 1024 * 1024) <> "THE-END"

      run =
        projected(scope, [
          {1, "run.started", started_data()},
          {2, "session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "x"}}},
          {3, "session.tool_finished",
           %{"tool" => "Bash", "tool_use_id" => "t", "response" => huge}}
        ])

      index = Record.timeline(scope, run)
      light = Enum.filter(index.items, &(&1.seq == 2))

      assert [%{wells: [_, %{text: text, bytes: bytes, cut: true}]}] =
               Record.items(scope, run, light)

      assert byte_size(text) == Timeline.well_limit()
      assert bytes == byte_size(huge)

      assert [%{full: true, wells: [_, %{text: text, cut: true}]}] =
               Record.items(scope, run, light, full: [2])

      assert byte_size(text) == Timeline.full_limit()
    end

    test "one call with 50,000 connections inside it reads at most 102 rows", %{scope: scope} do
      run = run_fixture(scope)
      now = DateTime.utc_now()

      rows =
        [
          {1, "dev.qory.session.tool_started",
           %{"tool" => "Bash", "tool_use_id" => "t", "input" => %{"command" => "fetch"}}}
        ] ++
          for(
            n <- 2..50_001,
            do: {n, "dev.qory.run.egress", egress_data(%{"host" => "h#{rem(n, 50)}.example"})}
          )

      rows
      |> Enum.map(fn {sequence, type, data} ->
        %{
          id: Ecto.UUID.bingenerate(),
          organisation_id: Ecto.UUID.dump!(run.organisation_id),
          workspace_id: Ecto.UUID.dump!(run.workspace_id),
          run_id: Ecto.UUID.dump!(run.id),
          sequence: sequence,
          event_id: Ecto.UUID.bingenerate(),
          type: type,
          time: now,
          data: data,
          received_at: now,
          projected_at: now
        }
      end)
      |> Enum.chunk_every(5_000)
      |> Enum.each(&Repo.insert_all("events", &1))

      index = Record.timeline(scope, run)
      assert [%{seq: 1, inner_count: 50_000} = item] = index.items

      {items, reads} = count_reads(fn -> Record.items(scope, run, [item]) end)

      IO.puts(
        "\n[budget] 1 call + 50,000 connections: #{reads.queries} queries, #{reads.rows} rows"
      )

      assert [%{connections: connections, connections_count: 50_000}] = items
      assert length(connections) == 100
      assert reads.rows <= 102, "read #{reads.rows} rows"
    end
  end

  # The queries this process makes while `fun` runs, and the rows they answer.
  defp count_reads(fun) do
    handler = {__MODULE__, make_ref()}
    parent = self()
    counter = :counters.new(2, [])

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent do
          :counters.add(counter, 1, 1)

          case metadata[:result] do
            {:ok, %{num_rows: rows}} when is_integer(rows) -> :counters.add(counter, 2, rows)
            _ -> :ok
          end
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, %{queries: :counters.get(counter, 1), rows: :counters.get(counter, 2)}}
    after
      :telemetry.detach(handler)
    end
  end
end
