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
    |> Enum.filter(&String.starts_with?(&1.type, "dev.qory.session."))
    |> Enum.map(&{&1.data["agent_id"], &1.data["agent_type"]})
    |> Enum.uniq()
  end

  describe "replay/3" do
    test "session-with-subagents is stored and projected: a run that succeeded, its connections, its lanes",
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

      assert run.state == "succeeded"
      assert run.exit_code == 0
      assert run.runtime == "claude"
      assert run.wall == "docker"
      assert run.target_system == "git.example.com"
      assert run.target_path == "acme/shop"
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

        assert %{type: "dev.qory.session.tool_started", data: %{"tool" => "Bash"} = data} =
                 Enum.at(events, index - 1)

        assert data["input"]["command"] =~ host
      end
    end

    test "failed-run is a bare runtime that failed, in another target of the same task",
         %{access_key: access_key} do
      assert {:ok, run} = Demo.replay(access_key, file("failed-run"))

      assert run.state == "failed"
      assert run.exit_code == 2

      assert {run.target_system, run.target_path, run.task} ==
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
      assert run.target_path == "acme/shop"
      assert is_nil(run.exited_at)
      assert run.heartbeat_interval_seconds == 600

      assert %Event{type: "dev.qory.run.heartbeat", time: time} = List.last(events(run))
      assert DateTime.diff(now, time, :millisecond) in 0..1

      # Not lost for as long as a run whose heartbeats stop is not.
      assert Runs.Liveness.check(DateTime.add(now, 60, :second)) == []
      assert Repo.get!(Run, run.id).state == "running"
    end

    test "timed-out was stopped at its limit, in the other system's acme/shop", %{
      access_key: access_key
    } do
      assert {:ok, run} = Demo.replay(access_key, file("timed-out"))

      assert run.state == "timed_out"
      assert {run.reason, run.exit_code, run.duration_ms} == {"timeout", -1, 3_600_000}
      assert {run.target_system, run.target_path} == {"github.example", "acme/shop"}
      assert run.denied_count == 0
    end

    test "ping-only is a run the hive knows by its subject and nothing else", %{
      access_key: access_key
    } do
      assert {:ok, run} = Demo.replay(access_key, file("ping-only"))

      assert run.state == "pending"
      assert {run.started_at, run.runtime, run.target_id} == {nil, nil, nil}
      assert run.runner_version == "0.10.0"
    end

    test "unassigned has no labels and no wall, and was only observed", %{
      access_key: access_key
    } do
      assert {:ok, run} = Demo.replay(access_key, file("unassigned"))

      assert run.state == "succeeded"
      assert {run.target_system, run.target_path, run.task, run.wall} == {nil, nil, nil, nil}

      assert [%{last_rule: "", last_mode: "observe", last_decision: "allowed"}, _telemetry] =
               Repo.all(from c in Connection, where: c.run_id == ^run.id, order_by: c.host)
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

      File.write!(path, ~s({"type":"dev.qory.ping","time":"2026-09-18T09:00:00.000Z"}\n))
      assert {:error, :not_a_batch} = Demo.replay(access_key, path)

      assert {:error, :enoent} = Demo.replay(access_key, path <> ".none")
      assert Runs.list_runs(scope) == []
    end
  end

  describe "policy/1" do
    test "gives a hive without rules a policy with overrides, a lock, versions and a history",
         %{scope: scope, access_key: access_key} do
      assert {:ok, _run} = Demo.replay(access_key, file("session-with-subagents"))
      refute Apiary.Policy.managed?(scope)
      assert {:ok, 15} = Demo.policy(access_key)
      assert Apiary.Policy.managed?(scope)

      assert Apiary.Policy.get_mode(scope) == "enforce"

      [%{target: shop}] =
        Enum.filter(Apiary.Policy.list_targets(scope), &(&1.rule_count > 0))

      effective = Apiary.Policy.effective(scope, shop)

      assert effective.allow == [
               "api.example",
               "api.llm.example",
               "git.example.com",
               "packages.example.com",
               "*.packages.example.com"
             ]

      assert Map.keys(effective.paths) == ["git.example.com"]

      assert effective.credentials == [
               %{name: "model"},
               %{name: "product", argument: "acme/shop"}
             ]

      assert %{in_force: false, overridden_by: %{locked: true}} =
               Enum.find(
                 effective.entries,
                 &(&1.host == "telemetry.llm.example" and &1.source == :target)
               )

      assert %{total: 10} = Apiary.Policy.list_changes(scope, nil)
      assert %{total: 5} = Apiary.Policy.list_changes(scope, shop)

      assert %{mode: "observe", own: "observe", hive: "enforce"} =
               Apiary.Policy.get_mode(scope, shop)

      assert {:ok, %{version: version}} = Apiary.Policy.current_configuration(scope, nil)
      assert version > 5

      # A second invocation leaves the policy as it is.
      assert :kept = Demo.policy(access_key)
      assert %{total: 15} = Apiary.Policy.list_changes(scope, :all)
    end

    test "without the demo's target the baseline alone is written", %{
      scope: scope,
      access_key: access_key
    } do
      assert {:ok, 10} = Demo.policy(access_key)
      assert Apiary.Policy.effective(scope, nil).allow != []
    end
  end
end
