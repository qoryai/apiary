defmodule Apiary.WorkItems.NoDeclinedStateMigrationTest do
  # The migration that closes every declined work item, run down and up again inside the
  # test's transaction, which rolls it all back. It changes `work_items`,
  # `work_item_events` and `escalations` under every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.{Processes, WorkItems}
  alias Apiary.Stages.Escalation
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @version 20_261_103_090_000
  @migration Apiary.Repo.Migrations.CloseEveryDeclinedWorkItem
  @options [log: false, migration_lock: false]
  @at ~U[2026-11-01 09:30:00.000000Z]

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_close_every_declined_work_item.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_name = 'work_items' AND column_name IN ('declined_at', 'declined_by_id')
      ORDER BY column_name
      """)

    List.flatten(rows)
  end

  # `work_item` declined by `user_id` at @at, its `:closed` event made a `declined` one,
  # as a decline wrote them, in SQL: the schemas have no such state.
  defp declined!(work_item, user_id) do
    Repo.query!(
      "UPDATE work_items SET state = 'declined', declined_at = $2, declined_by_id = $3 " <>
        "WHERE id = $1",
      [Ecto.UUID.dump!(work_item.id), @at, Ecto.UUID.dump!(user_id)]
    )

    Repo.query!(
      "INSERT INTO work_item_events " <>
        "(id, organisation_id, workspace_id, work_item_id, kind, actor_kind, actor_id, at, " <>
        "data) VALUES ($1, $2, $3, $4, 'declined', 'person', $5, $6, $7)",
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.dump!(work_item.organisation_id),
        Ecto.UUID.dump!(work_item.workspace_id),
        Ecto.UUID.dump!(work_item.id),
        Ecto.UUID.dump!(user_id),
        @at,
        %{"stage" => "confirm"}
      ]
    )
  end

  defp event!(work_item, kind) do
    Repo.one!(from e in WorkItemEvent, where: e.work_item_id == ^work_item.id and e.kind == ^kind)
  end

  test "the state, the event and the resolution are refused at the head" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)

    assert columns() == []
    refute :declined in WorkItems.State.states()
    refute :decline in Escalation.resolutions()

    assert_raise Postgrex.Error, ~r/work_items_state_check/, fn ->
      Repo.query!("UPDATE work_items SET state = 'declined' WHERE id = $1", [
        Ecto.UUID.dump!(work_item.id)
      ])
    end
  end

  test "up closes a declined work item, as declined, and leaves the others and the audit" do
    %{scope: scope} = sign_up_fixture()
    user_id = scope.user.id
    declined = work_item_fixture(scope, external_ref: "acme/shop#1")
    live = work_item_fixture(scope, external_ref: "acme/shop#2")
    {:ok, undone} = WorkItems.undo(scope, work_item_fixture(scope, external_ref: "acme/shop#3"))

    audit =
      Repo.insert!(%Entry{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        action: "work_item.decline",
        actor_kind: :person,
        actor_id: user_id,
        subject_kind: "work_item",
        subject_id: declined.id,
        details: %{}
      })

    down!()
    assert columns() == ["declined_at", "declined_by_id"]
    declined!(declined, user_id)
    up!()
    assert columns() == []

    assert %WorkItem{state: :closed, closed_at: @at, closed_by_id: ^user_id} =
             Repo.get!(WorkItem, declined.id)

    assert %WorkItemEvent{actor_id: ^user_id, at: @at, data: %{"stage" => "confirm"}} =
             event!(declined, :closed)

    assert %WorkItem{state: :exploring, closed_at: nil} = Repo.get!(WorkItem, live.id)
    assert %WorkItem{state: :undone, closed_at: nil} = Repo.get!(WorkItem, undone.id)
    assert %Entry{action: "work_item.decline"} = Repo.get!(Entry, audit.id)
  end

  test "an undo of a take in again of a declined work item goes back to closed" do
    %{scope: scope} = sign_up_fixture()
    user_id = scope.user.id
    ticket = backlog_ticket_fixture(scope)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)
    {:ok, _closed} = WorkItems.close(scope, work_item)

    Repo.update_all(from(r in DispatchRun, where: r.work_item_id == ^work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )

    {:ok, again} = WorkItems.take_in_again(scope, ticket.public_id)

    down!()

    Repo.query!(
      "UPDATE work_item_events SET data = jsonb_set(data, '{before,state}', '\"declined\"') " <>
        "WHERE work_item_id = $1 AND kind = 'taken_in' AND data ? 'before'",
      [Ecto.UUID.dump!(again.id)]
    )

    up!()

    assert {:ok, %WorkItem{state: :closed, closed_by_id: ^user_id}} =
             WorkItems.undo(scope, Repo.get!(WorkItem, again.id))
  end

  test "an escalation resolved with decline reads close" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    version = Processes.current(scope.workspace)

    down!()

    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO escalations (id, organisation_id, workspace_id, work_item_id, stage_id, " <>
        "process_version_id, round, cause, resolution, resolved_at, inserted_at) " <>
        "VALUES ($1, $2, $3, $4, 'explore', $5, 1, 'escalate', 'decline', now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(work_item.id),
        Ecto.UUID.dump!(version.id)
      ]
    )

    up!()

    assert %Escalation{resolution: :close} = Repo.get!(Escalation, id)
  end
end
