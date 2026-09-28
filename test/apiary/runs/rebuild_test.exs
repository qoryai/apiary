defmodule Apiary.Runs.RebuildTest do
  use Apiary.DataCase, async: true
  use ExUnitProperties

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Connection, Projector, Rebuild, Run}

  @selected [:host, :port, :path, :attempts, :allowed, :denied, :last_decision, :last_rule] ++
              [:last_outcome, :last_sequence, :last_mode, :last_path_rule, :last_credential] ++
              [:last_request_method, :last_tool, :last_status]

  setup do
    %{scope: scope_fixture()}
  end

  defp projection(run) do
    %{
      denied_count: Repo.get!(Run, run.id).denied_count,
      connections:
        Repo.all(
          from c in Connection,
            where: c.run_id == ^run.id,
            order_by: [c.host, c.port, c.path],
            select: map(c, ^@selected)
        )
    }
  end

  # A projection no event accounts for: the run's connections gone, its count reset.
  defp lose_projection(run) do
    Repo.delete_all(from(c in Connection, where: c.run_id == ^run.id))
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [denied_count: 0])
  end

  describe "run/1" do
    test "projects every run again from its events, and doing it twice changes nothing", %{
      scope: scope
    } do
      lost = run_fixture(scope)
      kept = run_fixture(scope)
      bare = run_fixture(scope)

      for run <- [lost, kept] do
        event_fixture(run, 1, "run.egress", egress_data(%{"decision" => "denied", "rule" => ""}))
        {:ok, _} = Projector.project(run)
      end

      expected = projection(lost)
      lose_projection(lost)
      refute projection(lost) == expected

      assert Rebuild.run() == %{rebuilt: 3, failed: 0}
      assert projection(lost) == expected
      assert projection(kept) == expected
      assert projection(bare) == %{denied_count: 0, connections: []}

      assert Rebuild.run(batch: 1) == %{rebuilt: 3, failed: 0}
      assert projection(lost) == expected
      assert projection(kept) == expected
    end

    test "walks the runs in windows of the batch", %{scope: scope} do
      runs =
        for _ <- 1..5 do
          run = run_fixture(scope)
          event_fixture(run, 1, "run.egress", egress_data())
          {:ok, _} = Projector.project(run)
          lose_projection(run)
          run
        end

      assert Rebuild.run(batch: 2) == %{rebuilt: 5, failed: 0}
      for run <- runs, do: assert([%{last_mode: "enforce"}] = projection(run).connections)
    end
  end

  # Fields as a runner that does not follow the schema may send them: not strings at all,
  # and strings longer than a column's cut, in characters of several bytes.
  defp field do
    one_of([
      constant(:absent),
      member_of(["enforce", "observe", "", "/v1/*", "model-key"]),
      member_of([1, true, nil, ["enforce"], %{"a" => "b"}, 1.5]),
      map(integer(340..345), &String.duplicate("日本語", &1)),
      map(integer(20..23), &String.duplicate("é", &1 * 3))
    ])
  end

  defp egress do
    gen all(
          host <- member_of(["a.example", "b.example"]),
          decision <- member_of(["allowed", "denied", 7]),
          mode <- field(),
          path_rule <- field(),
          credential <- field(),
          request_method <- field()
        ) do
      [
        {"mode", mode},
        {"path_rule", path_rule},
        {"credential", credential},
        {"request_method", request_method}
      ]
      |> Enum.reject(fn {_key, value} -> value == :absent end)
      |> Map.new()
      |> Map.merge(%{"host" => host, "decision" => decision})
      |> then(&Map.merge(egress_data(), &1))
    end
  end

  property "incremental projection and rebuild/1 agree, whatever the fields hold",
           %{scope: scope} do
    check all(
            events <- list_of(egress(), min_length: 1, max_length: 8),
            cut <- integer(0..8),
            max_runs: 25
          ) do
      run = run_fixture(scope)
      {first, second} = Enum.split(Enum.with_index(events, 1), cut)

      # Incrementally, in two passes, the later events first.
      for {data, sequence} <- second, do: event_fixture(run, sequence, "run.egress", data)
      {:ok, _} = Projector.project(run)
      for {data, sequence} <- first, do: event_fixture(run, sequence, "run.egress", data)
      {:ok, _} = Projector.project(run)
      incremental = projection(run)

      {:ok, _} = Projector.rebuild(run)
      assert projection(run) == incremental

      # Nothing longer than the fold's cut, and nothing cut inside a character.
      for connection <- incremental.connections,
          key <- [:last_mode, :last_path_rule, :last_credential, :last_request_method],
          value = connection[key] do
        assert String.valid?(value)
        assert byte_size(value) <= 1024
      end
    end
  end
end
