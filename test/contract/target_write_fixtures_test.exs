defmodule Apiary.Contract.TargetWriteFixturesTest do
  # The Forager contract's fixtures of `dev.qory.run.target_write`, vendored at the commit
  # in `.forager-contract-ref`: each write of the batch passes the vendored schema, and the
  # batch, projected, reads as the writes it sends; each invalid event fails the
  # schema, and folded by the fold's rules (`Apiary.Runs.Fold`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1, events_fixture: 2]

  alias Apiary.ForagerSchemas
  alias Apiary.Runs.{Projector, TargetWrite}

  @moduletag :contract

  @root Path.expand("../..", __DIR__)
  @fixtures "test/fixtures/forager-contract/"
  @schema "events/run.target_write.schema.json"
  @type_name "dev.qory.run.target_write"

  defp fixture(path) do
    assert (@fixtures <> path) in Apiary.ContractFixtures.vendored(), path
    [@root, @fixtures, path] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  # The events, as the fixtures of events (`events_fixture/2`) take them.
  defp stored(events) do
    for %{"type" => "dev.qory." <> type, "sequence" => sequence, "data" => data} <- events,
        do: {String.to_integer(sequence), type, data}
  end

  defp projected(events) do
    run = run_fixture(scope_fixture())
    events_fixture(run, stored(events))
    {:ok, run} = Projector.project(run)
    run
  end

  test "each write of the batch passes the schema, and reads as the writes it sends" do
    events = fixture("batch/target-write.json")
    writes = for %{"type" => @type_name} = event <- events, do: event
    assert length(writes) == 4

    for %{"data" => data} <- writes, do: assert(ForagerSchemas.validate(@schema, data) == :ok)

    run = projected(events)
    rows = TargetWrite.of_run(run)
    assert Enum.map(rows, & &1.state) == ~w(started changed started cut)

    assert [
             %{system: "git.example", path: "example-org/app", written: :changed},
             %{system: "git.example", path: "example-org/lib", written: :maybe}
           ] = TargetWrite.writes(rows, true)
  end

  test "each invalid event fails the schema, and folded by the fold's rules" do
    for {file, folded} <- [
          {"event-target-write-empty-system.json", []},
          {"event-target-write-without-path.json", []},
          {"event-target-write-unknown-state.json", []},
          # The fold reads the members it knows: the extra one is not read.
          {"event-target-write-ref-member.json",
           [{"refused", "0123456789abcdef0123456789abc0a1"}]},
          # A request id outside its pattern is absent.
          {"event-target-write-request-id-upper-case.json", [{"changed", nil}]}
        ] do
      %{"data" => data} = event = fixture("invalid/" <> file)
      assert {:error, _} = ForagerSchemas.validate(@schema, data), file

      run = projected([event])

      assert for(row <- TargetWrite.of_run(run), do: {row.state, row.request_id}) == folded,
             file
    end
  end
end
