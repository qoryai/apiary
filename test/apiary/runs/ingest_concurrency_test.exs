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

  # What the runner's request says beside its body: the revision of the contract.
  @meta %{contract_version: 1}

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
      |> Task.async_stream(&Ingest.ingest(key, &1, @meta), max_concurrency: 8, timeout: 30_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{status: 202, inserted: 1}}, &1))

    assert [run] = Repo.all(from r in Run, where: r.workspace_id == ^scope.workspace.id)
    assert run.run_id == subject
    assert run.event_count == 8
    assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 8
  end

  test "a close that commits while a batch is on its way wins: the batch is answered 410" do
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
    {subject, [ping, started]} = first_events()
    {:ok, first} = [ping] |> Jason.encode!() |> Batch.parse()
    {:ok, second} = [started] |> Jason.encode!() |> Batch.parse()

    assert {:ok, %{status: 202, run: run}} = Ingest.ingest(key, first, @meta)
    test = self()

    # The close, as `Apiary.Runs.close_run/2` makes it, held open for a moment
    # before it commits: the receiver's first look does not see it.
    closing =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.update_all(from(r in Run, where: r.id == ^run.id),
            set: [state: "closed", closed_at: DateTime.utc_now()]
          )

          send(test, :closing)
          Process.sleep(300)
        end)
      end)

    assert_receive :closing, 5_000
    assert {:ok, %{status: 410}} = Ingest.ingest(key, second, @meta)
    Task.await(closing)

    assert Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count) == 1
    assert Repo.one!(from r in Run, where: r.id == ^run.id).run_id == subject
  end
end
