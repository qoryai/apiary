defmodule Apiary.Runs.SchemaTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.{Event, Run}

  defp run_fixture(scope, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Run{
          organisation_id: scope.organisation.id,
          hive_id: scope.hive.id,
          run_id: Ecto.UUID.generate()
        },
        attrs
      )
    )
  end

  test "a run starts pending and keeps its args and labels as sent" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope, %{args: ["--print", "hello"], labels: %{"task" => "T-1"}})

    assert %Run{state: "pending", args: ["--print", "hello"], labels: %{"task" => "T-1"}} =
             Repo.get!(Run, run.id)

    assert Repo.get!(Run, run_fixture(scope).id).args == []
  end

  test "the database refuses a state outside the list" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope)

    assert_raise Postgrex.Error, ~r/runs_state_check/, fn ->
      Repo.query!("UPDATE runs SET state = 'paused' WHERE id = $1", [Ecto.UUID.dump!(run.id)])
    end
  end

  test "the subject is unique within a hive, and free in another" do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    run = run_fixture(scope)

    assert %Run{} = run_fixture(other, %{run_id: run.run_id})

    assert_raise Ecto.ConstraintError, ~r/runs_hive_id_run_id_index/, fn ->
      run_fixture(scope, %{run_id: run.run_id})
    end
  end

  test "a row cannot name the hive of one organisation and the id of another" do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()

    assert_raise Ecto.ConstraintError, ~r/runs_hive_id_fkey/, fn ->
      Repo.insert!(%Run{
        organisation_id: other.organisation.id,
        hive_id: scope.hive.id,
        run_id: Ecto.UUID.generate()
      })
    end
  end

  test "an event is unique by sequence in its run and by id in its hive; it goes with the run" do
    %{scope: scope} = sign_up_fixture()
    run = run_fixture(scope)

    event = %Event{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      run_id: run.id,
      sequence: 1,
      event_id: Ecto.UUID.generate(),
      type: "dev.qory.ping",
      time: DateTime.utc_now(),
      received_at: DateTime.utc_now(),
      data: %{}
    }

    Repo.insert!(event)

    assert_raise Ecto.ConstraintError, ~r/events_run_id_sequence_index/, fn ->
      Repo.insert!(%{event | event_id: Ecto.UUID.generate()})
    end

    assert_raise Ecto.ConstraintError, ~r/events_hive_id_event_id_index/, fn ->
      Repo.insert!(%{event | sequence: 2})
    end

    Repo.delete!(run)
    assert Repo.aggregate(Event, :count) == 0
  end

  test "a child of a run cannot name another hive than its run's" do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    run = run_fixture(scope)

    assert_raise Ecto.ConstraintError, ~r/events_run_id_fkey/, fn ->
      Repo.insert!(%Event{
        organisation_id: other.organisation.id,
        hive_id: other.hive.id,
        run_id: run.id,
        sequence: 1,
        event_id: Ecto.UUID.generate(),
        type: "dev.qory.ping",
        time: DateTime.utc_now(),
        received_at: DateTime.utc_now()
      })
    end

    for table <- ~w(log_chunks connections) do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
          [table <> "_run_id_fkey"]
        )

      assert definition =~ "FOREIGN KEY (run_id, hive_id) REFERENCES runs(id, hive_id)"
    end
  end

  test "a run cannot name a target of another hive" do
    %{scope: scope} = sign_up_fixture()
    %{scope: other} = sign_up_fixture()
    now = DateTime.utc_now()

    target =
      Repo.insert!(%Apiary.Runs.Target{
        organisation_id: other.organisation.id,
        hive_id: other.hive.id,
        system: "git.example.com",
        path: "acme/shop",
        first_seen_at: now
      })

    assert_raise Ecto.ConstraintError, ~r/runs_target_id_fkey/, fn ->
      run_fixture(scope, %{target_id: target.id})
    end

    # In its own hive it may, and the run outlives the target.
    run = run_fixture(other, %{target_id: target.id})
    Repo.delete!(target)
    assert %Run{target_id: nil, hive_id: hive_id} = Repo.get!(Run, run.id)
    assert hive_id == other.hive.id
  end

  test "a delivery keeps its key: the key cannot be deleted from under it, the hive can go" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key} = Apiary.AccessKeysFixtures.access_key_fixture(scope)

    Repo.insert!(%Apiary.Runs.Delivery{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      access_key_id: key.id,
      delivery_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      received_at: DateTime.utc_now(),
      status: 202
    })

    assert_raise Postgrex.Error, ~r/deliveries_access_key_id_fkey/, fn ->
      Repo.query!("DELETE FROM access_keys WHERE id = $1", [Ecto.UUID.dump!(key.id)])
    end

    Repo.query!("DELETE FROM organisations WHERE id = $1", [
      Ecto.UUID.dump!(scope.organisation.id)
    ])

    assert Repo.aggregate(Apiary.Runs.Delivery, :count) == 0
  end

  test "the liveness scan has its index" do
    %{rows: [[definition]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = 'runs_alive_index'")

    assert definition =~ "(state, last_heartbeat_at)"
    assert definition =~ "WHERE"
  end
end
