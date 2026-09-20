defmodule Apiary.Runs.IngestConcurrencyTest do
  # Real transactions on real connections: the sandbox would run the two first
  # batches one after the other on one connection and prove nothing. What the
  # test commits goes with its organisation and its user when it ends.
  use ExUnit.Case, async: false

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Event, Ingest, Run}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  test "the first batches of one run, at once, make one run and lose no event" do
    %{scope: scope, user: user} = sign_up_fixture()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    %{access_key: key} = access_key_fixture(scope)
    subject = Ecto.UUID.generate()

    batches =
      for n <- 1..8 do
        {:ok, batch} =
          [wire_event(subject, n, "run.log", %{"stream" => "stdout", "bytes" => "aGk="})]
          |> Jason.encode!()
          |> Batch.parse()

        batch
      end

    results =
      batches
      |> Task.async_stream(&Ingest.ingest(key, &1), max_concurrency: 8, timeout: 30_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{status: 202, inserted: 1}}, &1))

    assert [run] = Repo.all(from r in Run, where: r.hive_id == ^scope.hive.id)
    assert run.run_id == subject
    assert run.event_count == 8
    assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 8
  end
end
