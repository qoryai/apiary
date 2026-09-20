defmodule Apiary.Runs.IngestTest do
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.{Batch, Delivery, Event, Ingest, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key} = access_key_fixture(scope)
    %{scope: scope, key: key}
  end

  defp batch!(events) do
    {:ok, batch} = events |> Jason.encode!() |> Batch.parse()
    batch
  end

  test "counts what was new, what was held and what collided", %{key: key} do
    {subject, [ping, started]} = first_events()

    assert {:ok, %{status: 202, inserted: 1, duplicates: 0, conflicts: 0, repeated: false}} =
             Ingest.ingest(key, batch!([ping]))

    usurper = wire_event(subject, 1, "run.exited", %{"state" => "failed"})

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{status: 202, inserted: 1, duplicates: 1, conflicts: 1, run: run}} =
               Ingest.ingest(key, batch!([ping, usurper, started]))

      assert run.event_count == 2
    end)
  end

  test "an event twice in one batch is stored once", %{key: key} do
    {_subject, [ping, _]} = first_events()

    assert {:ok, %{inserted: 1, duplicates: 1, conflicts: 0}} =
             Ingest.ingest(key, batch!([ping, ping]))
  end

  test "a repeated delivery id is answered again and touches nothing", %{key: key} do
    {_subject, [ping, started]} = first_events()
    meta = %{delivery_id: Ecto.UUID.generate()}

    assert {:ok, %{status: 202, inserted: 1, repeated: false}} =
             Ingest.ingest(key, batch!([ping]), meta)

    # Even with another body: the delivery was answered, and that answer stands.
    assert {:ok, %{status: 202, inserted: 0, repeated: true}} =
             Ingest.ingest(key, batch!([started]), meta)

    assert Repo.aggregate(Event, :count) == 1
    assert [%Delivery{event_count: 1, inserted_count: 1}] = Repo.all(Delivery)
  end

  test "the same delivery id under another key is another delivery", %{scope: scope, key: key} do
    %{access_key: other} = access_key_fixture(scope)
    {_subject, [ping, started]} = first_events()
    meta = %{delivery_id: Ecto.UUID.generate()}

    assert {:ok, %{inserted: 1}} = Ingest.ingest(key, batch!([ping]), meta)
    assert {:ok, %{inserted: 1, repeated: false}} = Ingest.ingest(other, batch!([started]), meta)
  end

  test "the run keeps the key that first delivered it", %{scope: scope, key: key} do
    %{access_key: other} = access_key_fixture(scope)
    {_subject, [ping, started]} = first_events()

    assert {:ok, %{run: %Run{id: id}}} = Ingest.ingest(key, batch!([ping]))
    assert {:ok, %{run: %Run{id: ^id} = run}} = Ingest.ingest(other, batch!([started]))
    assert run.access_key_id == key.id
  end
end
