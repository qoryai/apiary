defmodule Apiary.Runs.RebuildTest do
  use Apiary.DataCase, async: true
  use ExUnitProperties

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Connection, Projector, Rebuild, Run}

  Code.require_file(
    "priv/repo/migrations/20260922000100_add_denied_count_and_last_mode.exs",
    File.cwd!()
  )

  alias Apiary.Repo.Migrations.AddDeniedCountAndLastMode, as: Migration

  @added [:last_mode, :last_path_rule, :last_credential, :last_request_method]
  @selected [:host, :port, :path, :attempts, :allowed, :denied, :last_decision, :last_rule] ++
              [:last_outcome, :last_sequence | @added]

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

  # The rows as a release before the migration left them: the columns it adds are empty.
  defp as_before_the_migration(run) do
    Repo.update_all(from(c in Connection, where: c.run_id == ^run.id),
      set: Enum.map(@added, &{&1, nil})
    )

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [denied_count: 0])
  end

  # What an upgrade does: the migration's statement, then the task.
  defp backfill do
    Repo.query!(Migration.denied_count_sql())
    Rebuild.run()
  end

  describe "run/1" do
    test "rebuilds the runs projected before the columns existed, and only those", %{
      scope: scope
    } do
      stale = run_fixture(scope)
      fresh = run_fixture(scope)
      bare = run_fixture(scope)

      for run <- [stale, fresh] do
        event_fixture(run, 1, "run.egress", egress_data(%{"decision" => "denied", "rule" => ""}))
        {:ok, _} = Projector.project(run)
      end

      expected = projection(stale)
      as_before_the_migration(stale)
      refute projection(stale) == expected

      assert backfill() == %{rebuilt: 1, failed: 0}
      assert projection(stale) == expected
      assert projection(bare) == %{denied_count: 0, connections: []}

      # Idempotent: nothing is left to do, and doing everything again changes nothing.
      assert Rebuild.run() == %{rebuilt: 0, failed: 0}
      assert Rebuild.run(all: true, batch: 1) == %{rebuilt: 3, failed: 0}
      assert projection(stale) == expected
      assert projection(fresh) == expected
    end

    test "selects a run whose result was folded before the cost was, and only that", %{
      scope: scope
    } do
      costed = run_fixture(scope)
      event_fixture(costed, 1, "session.result", %{"outcome" => "success", "cost_usd" => 0.25})
      {:ok, _} = Projector.project(costed)
      assert Decimal.equal?(Repo.get!(Run, costed.id).cost_usd, Decimal.new("0.25"))

      # As a release before the column left it: the result folded, no cost on the row.
      Repo.update_all(from(r in Run, where: r.id == ^costed.id), set: [cost_usd: nil])

      # A result that carried no cost gives the rebuild nothing to do but the work.
      free = run_fixture(scope)
      event_fixture(free, 1, "session.result", %{"outcome" => "success"})
      {:ok, _} = Projector.project(free)

      assert Rebuild.run() == %{rebuilt: 2, failed: 0}
      assert Decimal.equal?(Repo.get!(Run, costed.id).cost_usd, Decimal.new("0.25"))
      assert Repo.get!(Run, free.id).cost_usd == nil
    end

    test "selects a run whose start reports a size folded before the size was, and only that",
         %{scope: scope} do
      sized = run_fixture(scope)
      terminal = %{"interactive" => true, "terminal" => %{"cols" => 120, "rows" => 40}}
      event_fixture(sized, 1, "run.started", started_data(terminal))
      event_fixture(sized, 2, "run.resized", %{"cols" => 100, "rows" => 30})
      {:ok, _} = Projector.project(sized)
      assert %{terminal_cols: 100, terminal_rows: 30} = Repo.get!(Run, sized.id)

      # As a release before the columns left it: the start folded, no size on the row.
      Repo.update_all(from(r in Run, where: r.id == ^sized.id),
        set: [terminal_cols: nil, terminal_rows: nil]
      )

      # A start on pipes reports no size and gives the rebuild nothing to do.
      pipes = run_fixture(scope)
      event_fixture(pipes, 1, "run.started", started_data())
      {:ok, _} = Projector.project(pipes)

      assert Rebuild.run() == %{rebuilt: 1, failed: 0}
      assert %{terminal_cols: 100, terminal_rows: 30} = Repo.get!(Run, sized.id)
      assert %{terminal_cols: nil} = Repo.get!(Run, pipes.id)
      assert Rebuild.run() == %{rebuilt: 0, failed: 0}
    end

    test "selects a run whose tool invocations were folded before the tool and status were",
         %{scope: scope} do
      # Runs of a runner of revision 2, the only one that sends either key.
      tooled = run_fixture(scope, contract_version: 2)
      events_fixture(tooled, tool_record())
      {:ok, _} = Projector.project(tooled)

      expected =
        Repo.all(
          from c in Connection,
            where: c.run_id == ^tooled.id,
            order_by: [c.host, c.path],
            select: {c.host, c.path, c.last_tool, c.last_status}
        )

      assert {"files.tools.internal", "/media/acme/shop/checkout.png", "files", 201} in expected

      # As a release before the columns left them.
      Repo.update_all(from(c in Connection, where: c.run_id == ^tooled.id),
        set: [last_tool: nil, last_status: nil]
      )

      # A plain host that answered, before the status was kept.
      answered = run_fixture(scope, contract_version: 2)

      event_fixture(
        answered,
        1,
        "run.egress",
        egress_data(%{"method" => "HTTPS", "status" => 200})
      )

      {:ok, _} = Projector.project(answered)

      Repo.update_all(from(c in Connection, where: c.run_id == ^answered.id),
        set: [last_status: nil]
      )

      # A connection whose events name neither gives the rebuild nothing to do, and neither
      # does one whose tool is not a name.
      plain = run_fixture(scope, contract_version: 2)
      event_fixture(plain, 1, "run.egress", egress_data())
      event_fixture(plain, 2, "run.egress", egress_data(%{"host" => "b.example", "tool" => ""}))
      {:ok, _} = Projector.project(plain)

      # A runner that announced an earlier revision is not read for them, whatever its
      # events say: the check stays off the runs that cannot need it.
      earlier = run_fixture(scope, contract_version: 1)

      event_fixture(
        earlier,
        1,
        "run.egress",
        egress_data(%{"method" => "HTTPS", "status" => 200})
      )

      {:ok, _} = Projector.project(earlier)

      Repo.update_all(from(c in Connection, where: c.run_id == ^earlier.id),
        set: [last_status: nil]
      )

      assert Rebuild.run() == %{rebuilt: 2, failed: 0}

      assert Repo.all(
               from c in Connection,
                 where: c.run_id == ^tooled.id,
                 order_by: [c.host, c.path],
                 select: {c.host, c.path, c.last_tool, c.last_status}
             ) == expected

      assert [%{last_status: 200}] =
               Repo.all(from c in Connection, where: c.run_id == ^answered.id)

      assert Rebuild.run() == %{rebuilt: 0, failed: 0}
    end

    test "walks in windows, and finds the runs that need it past a window that has none", %{
      scope: scope
    } do
      for _ <- 1..3 do
        run = run_fixture(scope)
        event_fixture(run, 1, "run.egress", egress_data())
        {:ok, _} = Projector.project(run)
      end

      runs =
        for _ <- 1..5 do
          run = run_fixture(scope)
          event_fixture(run, 1, "run.egress", egress_data())
          {:ok, _} = Projector.project(run)
          as_before_the_migration(run)
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

  property "incremental projection, rebuild/1 and the backfill agree, whatever the fields hold",
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

      as_before_the_migration(run)
      backfill()
      assert projection(run) == incremental

      # Nothing longer than the fold's cut, and nothing cut inside a character.
      for connection <- incremental.connections, key <- @added, value = connection[key] do
        assert String.valid?(value)
        assert byte_size(value) <= 1024
      end
    end
  end
end
