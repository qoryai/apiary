defmodule Apiary.Runs.RecordTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Projector, Record, Run}
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
    test "finds a run of the hive by its subject", %{scope: scope} do
      run = run_fixture(scope)
      assert {:ok, %Run{id: id}} = Record.fetch_run(scope, run.run_id)
      assert id == run.id
    end

    test "a run of another hive, an unknown subject and a malformed id are not found", %{
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

  describe "with a run of another hive handed in" do
    test "every read is empty", %{scope: scope} do
      theirs = scope_fixture()
      run = projected(theirs)

      assert Record.timeline(scope, run).items == []
      assert Record.connections(scope, run) == []
      assert Record.policy(scope, run) == nil
      assert %{chunks: 0, bytes: 0, through: 0, streams: []} = Record.log_summary(scope, run)
      assert Record.log_through(scope, run, 0) == 0
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
      assert index.hook_events > 0
    end

    test "a denied connection sits inside the one call that was open", %{scope: scope, run: run} do
      index = Record.timeline(scope, run)
      assert index.by_seq[59] == 58
      assert index.by_seq[85] == 84

      [npm] = Record.items(scope, run, index, Enum.filter(index.items, &(&1.seq == 58)))

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
      items = Record.items(scope, run, index, index.items)

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
      connections = Record.connections(scope, run)

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

  describe "the log" do
    test "summary, through and pages", %{scope: scope} do
      run = projected(scope)

      assert %{chunks: 2, bytes: 12, through: 9, streams: ["stderr", "stdout"]} =
               Record.log_summary(scope, run)

      assert Record.log_through(scope, run, 0) == 9
      assert Record.log_through(scope, run, 0, limit: 1) == 5
      assert Record.log_through(scope, run, 5) == 9
      assert Record.log_through(scope, run, 9) == 9
      assert Record.log_through(scope, run, 0, stream: "stdout") == 5
      assert Record.log_through(scope, run, 0, limit: :all) == 9

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

      assert %{sequence: 11, data: %{"source" => "fetched", "mode" => "enforce"}} =
               Record.policy(scope, run)

      assert Record.session_id(scope, run) == "session-1"
      assert Record.policy(scope, run_fixture(scope)) == nil
    end
  end
end
