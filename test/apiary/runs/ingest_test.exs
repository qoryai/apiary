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

  test "what the database refuses is {:error, :unavailable}, logged by its module only",
       %{key: key} do
    {_subject, [ping, _]} = first_events()
    batch = batch!([ping])
    # Past the parser on purpose: a NUL, which no text column holds.
    [event] = batch.events
    poisoned = %{batch | events: [%{event | type: "dev.qory.secret-looking\0payload"}]}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Ingest.ingest(key, poisoned) == {:error, :unavailable}
      end)

    assert log =~ "could not be stored: Postgrex.Error"
    refute log =~ "secret-looking"
    assert Repo.aggregate(Run, :count) == 0
    assert Repo.aggregate(Delivery, :count) == 0

    # And the connection is fine afterwards.
    assert {:ok, %{status: 202, inserted: 1}} = Ingest.ingest(key, batch)
  end

  test "events are inserted in sequence order, whatever the order of the batch", %{key: key} do
    subject = Ecto.UUID.generate()
    log = %{"stream" => "stdout", "bytes" => "aGk="}
    events = for n <- [3, 1, 2], do: wire_event(subject, n, "run.log", log)
    # As the parameters carry them: a UUID as text or as its sixteen bytes.
    ids =
      for event <- events, id <- [event["id"], Ecto.UUID.dump!(event["id"])], into: %{} do
        {id, String.to_integer(event["sequence"])}
      end

    test = self()
    handler = "ingest-order-#{System.unique_integer([:positive])}"

    # The insert is kept out of the log, not out of telemetry: its parameters say
    # in what order the rows went in.
    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        # Every test's queries pass here: only this test's insert is its own.
        if metadata.query =~ ~s(INSERT INTO "events") and
             Enum.any?(metadata.params, &is_map_key(ids, &1)),
           do: send(test, {:inserted, metadata.params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{inserted: 3}} = Ingest.ingest(key, batch!(events))
    assert_received {:inserted, params}

    order = for param <- params, sequence = ids[param], do: sequence
    assert order == [1, 2, 3]
  end
end
