defmodule Apiary.Contract.RecordedRunTest do
  @moduledoc """
  Replays `fixtures/run/<id>/events.jsonl` of the server contract, the record of
  one run, through the events endpoint and through `Apiary.Runs.Ingest`, and
  holds the receiver to its rule: whatever the order, the batching and the
  repetition of the deliveries, the same events are stored and the same run is
  projected from them.
  """
  use ApiaryWeb.ConnCase, async: true
  use ExUnitProperties

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Connection, Event, Ingest, LogChunk, Projector, Run}

  @moduletag :contract

  @runs (case Apiary.ContractFixtures.contract_dir() do
           nil ->
             []

           dir ->
             dir |> Path.join("fixtures/run/*/events.jsonl") |> Path.wildcard() |> Enum.sort()
         end)

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, key: published_key_fixture(scope)}
  end

  def lines(file), do: file |> File.read!() |> String.split("\n", trim: true)
  def subject(file), do: file |> Path.dirname() |> Path.basename()

  def run!(scope, subject) do
    Repo.one!(from r in Run, where: r.hive_id == ^scope.hive.id and r.run_id == ^subject)
  end

  # What is stored of a run, without what differs between two receptions of it:
  # row ids and the receiver's own clock.
  def stored(run) do
    events =
      Repo.all(from e in Event, where: e.run_id == ^run.id, order_by: e.sequence)
      |> Enum.map(&Map.take(&1, [:sequence, :event_id, :type, :time, :data]))

    %{events: events, run_event_count: run.event_count}
  end

  def projected(run) do
    {:ok, run} = Projector.project(run)

    %{
      run:
        run
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :last_event_at])
        |> Map.reject(fn {_field, value} -> match?(%Ecto.Association.NotLoaded{}, value) end),
      connections:
        Repo.all(
          from c in Connection, where: c.run_id == ^run.id, order_by: [c.host, c.port, c.path]
        )
        |> Enum.map(
          &(&1
            |> Map.from_struct()
            |> Map.drop([:__meta__, :id, :run_id, :run, :hive, :organisation]))
        ),
      log:
        Repo.all(from l in LogChunk, where: l.run_id == ^run.id, order_by: l.sequence)
        |> Enum.map(&{&1.sequence, &1.stream, &1.bytes})
    }
  end

  def forget(scope) do
    Repo.delete_all(from r in Run, where: r.hive_id == ^scope.hive.id)
  end

  def ingest!(key, lines) do
    {:ok, batch} = Batch.parse("[" <> Enum.join(lines, ",") <> "]")
    assert {:ok, %{status: 202}} = Ingest.ingest(key, batch)
  end

  for file <- @runs do
    @file_path file

    test "the record of #{file |> Path.dirname() |> Path.basename()}, posted as the runner cuts it, is the stored run",
         %{scope: scope} do
      lines = lines(@file_path)
      subject = subject(@file_path)

      # The ping is a batch of one, sent before anything else; then batches.
      [ping | rest] = lines

      for batch <- [[ping] | Enum.chunk_every(rest, 5)] do
        body = "[" <> Enum.join(batch, ",") <> "]"
        conn = signed_post(build_conn(), published_key_id(), published_secret(), body)
        assert conn.status == 202
      end

      run = run!(scope, subject)
      wire = Enum.map(lines, &Jason.decode!/1)

      assert run.event_count == length(lines)
      assert %{events: events} = stored(run)
      assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(lines))
      assert Enum.map(events, & &1.event_id) == Enum.map(wire, & &1["id"])
      assert Enum.map(events, & &1.type) == Enum.map(wire, & &1["type"])
      assert Enum.map(events, & &1.data) == Enum.map(wire, & &1["data"])

      # And what is projected from it says what the record says.
      %{run: projected, log: log} = projected(run)
      exited = Enum.find(wire, &(&1["type"] == "ai.qory.run.exited"))
      started = Enum.find(wire, &(&1["type"] == "ai.qory.run.started"))

      assert projected.state == "exited"
      assert projected.exit_code == exited["data"]["exit_code"]
      assert projected.host == started["data"]["host"]
      assert projected.projected_sequence == length(lines)

      output = @file_path |> Path.dirname() |> Path.join("output.log") |> File.read!()
      assert log |> Enum.map(&elem(&1, 2)) |> IO.iodata_to_binary() == output
    end

    property "any order, batching and repetition of #{file |> Path.dirname() |> Path.basename()} stores the same events and projects the same run",
             %{scope: scope, key: key} do
      lines = lines(@file_path)
      subject = subject(@file_path)

      ingest!(key, lines)
      run = run!(scope, subject)
      expected = stored(run)
      expected_projection = projected(run)
      forget(scope)

      check all(
              copies <- list_of(integer(1..3), length: length(lines)),
              total = Enum.sum(copies),
              order <- list_of(integer(), length: total),
              sizes <- list_of(integer(1..7), length: total),
              max_runs: 40
            ) do
        deliveries =
          lines
          |> Enum.zip(copies)
          |> Enum.flat_map(fn {line, count} -> List.duplicate(line, count) end)
          |> Enum.zip(order)
          |> Enum.sort_by(&elem(&1, 1))
          |> Enum.map(&elem(&1, 0))
          |> cut(sizes)

        for batch <- deliveries, do: ingest!(key, batch)

        run = run!(scope, subject)
        assert stored(run) == expected
        assert projected(run) == expected_projection
        forget(scope)
      end
    end
  end

  def cut([], _sizes), do: []

  def cut(lines, [size | sizes]) do
    {batch, rest} = Enum.split(lines, size)
    [batch | cut(rest, sizes)]
  end
end
