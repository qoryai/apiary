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
      type: "ai.qory.ping",
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
end
