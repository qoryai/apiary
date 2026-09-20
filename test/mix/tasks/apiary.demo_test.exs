defmodule Mix.Tasks.Apiary.DemoTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Delivery, Event, LogChunk, Run}
  alias Mix.Tasks.Apiary.Demo

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: access_key} = access_key_fixture(scope)
    %{scope: scope, access_key: access_key}
  end

  defp file(name) do
    Enum.find(Demo.files(), &(&1 |> Path.dirname() |> Path.basename() == name)) ||
      flunk("no demo run #{name}")
  end

  defp events(run),
    do: Repo.all(from e in Event, where: e.run_id == ^run.id, order_by: e.sequence)

  defp connections(run) do
    Repo.all(from c in Connection, where: c.run_id == ^run.id, order_by: [c.host, c.port, c.path])
    |> Enum.map(&{&1.host, &1.port, &1.path, &1.attempts, &1.allowed, &1.denied, &1.last_outcome})
  end

  # A lane is the main conversation (nil) or one subagent: the `agent_id` of the
  # session's events, in the order the lanes first appear.
  defp lanes(events) do
    events
    |> Enum.filter(&String.starts_with?(&1.type, "ai.qory.session."))
    |> Enum.map(&{&1.data["agent_id"], &1.data["agent_type"]})
    |> Enum.uniq()
  end

  describe "replay/3" do
    test "session-with-subagents is stored and projected: a run that exited, its connections, its lanes",
         %{scope: scope, access_key: access_key} do
      now = ~U[2026-09-20 10:00:00.000000Z]

      assert {:ok, %Run{} = run} = Demo.replay(access_key, file("session-with-subagents"), now)

      # Through the receiver's own function: the run is the hive's, under the key, and
      # the deliveries are recorded, 101 events in batches of 20.
      assert run.id == Runs.get_run!(scope, run.id).id
      assert run.access_key_id == access_key.id
      assert run.event_count == 101
      assert run.projected_sequence == 101

      assert [20, 20, 20, 20, 20, 1] ==
               Repo.all(
                 from d in Delivery,
                   where: d.run_id == ^run.run_id,
                   order_by: [desc: d.inserted_count],
                   select: d.inserted_count
               )

      assert run.state == "exited"
      assert run.exit_code == 0
      assert run.runtime == "claude"
      assert run.wall == "docker"
      assert run.forge == "git.example.com"
      assert run.repository == "acme/shop"
      assert run.task == "checkout-redesign"
      assert run.runner_version == "0.10.0"
      assert run.contract_version == 1
      assert run.heartbeat_interval_seconds == 60
      assert run.elapsed_seconds == 180
      assert "sha256=" <> _ = run.run_configuration_digest
      assert run.reported_run_configuration_digest == run.run_configuration_digest

      # The run ends now and took its four minutes.
      assert run.exited_at == now
      assert DateTime.diff(now, run.started_at, :second) == 232

      assert connections(run) == [
               {"api.llm.example", 443, "", 6, 6, 0, "connected"},
               {"cdn.packages.example.com", 443, "", 1, 1, 0, "dial_failed"},
               {"git.example.com", 443, "/acme/shop.git/git-upload-pack", 1, 1, 0, "connected"},
               {"git.example.com", 443, "/acme/shop.git/info/refs", 1, 1, 0, "connected"},
               {"metrics.example", 80, "", 1, 0, 1, "refused"},
               {"packages.example.com", 443, "", 2, 2, 0, "connected"},
               {"registry.example", 443, "", 1, 0, 1, "refused"}
             ]

      assert Repo.aggregate(from(l in LogChunk, where: l.run_id == ^run.id), :count) == 39

      events = events(run)

      assert lanes(events) == [
               {nil, nil},
               {"agent-demo-a1", "Explore"},
               {"agent-demo-a2", "general-purpose"}
             ]

      # A denied connection follows the tool call that made it.
      for host <- ["registry.example", "metrics.example"] do
        index = Enum.find_index(events, &(&1.data["host"] == host))

        assert %{type: "ai.qory.session.tool_started", data: %{"tool" => "Bash"} = data} =
                 Enum.at(events, index - 1)

        assert data["input"]["command"] =~ host
      end
    end

    test "failed-run is a bare runtime that failed, in another repository of the same task",
         %{access_key: access_key} do
      assert {:ok, run} = Demo.replay(access_key, file("failed-run"))

      assert run.state == "failed"
      assert run.exit_code == 2

      assert {run.forge, run.repository, run.task} ==
               {"github.example", "acme/api", "checkout-redesign"}

      assert lanes(events(run)) == []

      assert connections(run) == [
               {"proxy.golang.example", 443, "", 2, 2, 0, "connected"},
               {"sum.golang.example", 443, "", 1, 0, 1, "refused"}
             ]
    end

    test "running has started and beats up to now, and has not exited", %{access_key: access_key} do
      now = DateTime.utc_now()

      assert {:ok, run} = Demo.replay(access_key, file("running"), now)

      assert run.state == "running"
      assert run.repository == "acme/shop"
      assert is_nil(run.exited_at)
      assert run.heartbeat_interval_seconds == 600

      assert %Event{type: "ai.qory.run.heartbeat", time: time} = List.last(events(run))
      assert DateTime.diff(now, time, :millisecond) in 0..1

      # Not lost for as long as a run whose heartbeats stop is not.
      assert Runs.Liveness.check(DateTime.add(now, 60, :second)) == []
      assert Repo.get!(Run, run.id).state == "running"
    end

    test "every replay is a new run with new events", %{access_key: access_key} do
      assert {:ok, first} = Demo.replay(access_key, file("failed-run"))
      assert {:ok, second} = Demo.replay(access_key, file("failed-run"))

      assert first.run_id != second.run_id
      assert second.event_count == first.event_count

      ids = fn run -> MapSet.new(events(run), & &1.event_id) end
      assert MapSet.disjoint?(ids.(first), ids.(second))
    end

    test "a file that is not a record is an error and stores nothing", %{
      scope: scope,
      access_key: access_key
    } do
      path =
        Path.join(System.tmp_dir!(), "apiary-demo-#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(path) end)

      File.write!(path, "")
      assert {:error, :empty} = Demo.replay(access_key, path)

      File.write!(path, ~s({"type":"ai.qory.ping","time":"2026-09-18T09:00:00.000Z"}\n))
      assert {:error, :not_a_batch} = Demo.replay(access_key, path)

      assert {:error, :enoent} = Demo.replay(access_key, path <> ".none")
      assert Runs.list_runs(scope) == []
    end
  end
end
