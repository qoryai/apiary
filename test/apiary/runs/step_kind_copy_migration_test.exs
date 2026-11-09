defmodule Apiary.Runs.StepKindCopyMigrationTest do
  # The migration that adds the kind `copy` to `run_steps`, and the one that sets the kind
  # to `copy` on older copy steps, run down and up again inside the test's transaction, which
  # rolls it all back. They change the table under every other test, so they are not
  # async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.Step

  @kinds_version 20_261_108_090_000
  @kinds Apiary.Repo.Migrations.LetAStepBeACopy
  @validate_version 20_261_108_090_100
  @validate Apiary.Repo.Migrations.ValidateAStepSKindsWithACopy
  @backfill_version 20_261_108_090_200
  @backfill Apiary.Repo.Migrations.GiveOlderCopyStepsTheirKind

  setup_all do
    for {module, file} <- [
          {@kinds, "#{@kinds_version}_let_a_step_be_a_copy.exs"},
          {@validate, "#{@validate_version}_validate_a_step_s_kinds_with_a_copy.exs"},
          {@backfill, "#{@backfill_version}_give_older_copy_steps_their_kind.exs"}
        ] do
      unless Code.ensure_loaded?(module) do
        Application.app_dir(:apiary, "priv/repo/migrations")
        |> Path.join(file)
        |> Code.require_file()
      end
    end

    :ok
  end

  setup do
    %{run: run_fixture(scope_fixture())}
  end

  @options [log: false, migration_lock: false]

  defp down! do
    assert :ok = Ecto.Migrator.down(Repo, @backfill_version, @backfill, @options)
    assert :ok = Ecto.Migrator.down(Repo, @validate_version, @validate, @options)
    assert :ok = Ecto.Migrator.down(Repo, @kinds_version, @kinds, @options)
  end

  defp insert(run, step, kind, name \\ nil) do
    Repo.query(
      "INSERT INTO run_steps (id, organisation_id, workspace_id, run_id, step, kind, name, state) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, 'running')",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(run.organisation_id),
        Ecto.UUID.dump!(run.workspace_id),
        Ecto.UUID.dump!(run.id),
        step,
        kind,
        name
      ]
    )
  end

  defp kinds(run),
    do: Repo.all(from s in Step, where: s.run_id == ^run.id, order_by: s.step, select: s.kind)

  defp validated? do
    %{rows: [[validated]]} =
      Repo.query!("SELECT convalidated FROM pg_constraint WHERE conname = 'run_steps_kind_check'")

    validated
  end

  test "down leaves a copy step with no kind, and the check fails the kind again", %{run: run} do
    assert {:ok, _} = insert(run, 1, "copy")
    assert {:ok, _} = insert(run, 2, "machine")

    down!()

    assert kinds(run) == [nil, "machine"]
    assert validated?()

    assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
             insert(run, 3, "copy")
  end

  test "up lets a step be every kind of the list, and no other, and validates", %{run: run} do
    down!()

    # The first migration adds the check without a scan; the second validates it.
    assert :ok = Ecto.Migrator.up(Repo, @kinds_version, @kinds, @options)
    refute validated?()
    assert :ok = Ecto.Migrator.up(Repo, @validate_version, @validate, @options)
    assert validated?()

    kinds = ~w(fetch compose image build setup join wall push machine copy)

    for {kind, step} <- Enum.with_index(kinds, 1),
        do: assert({:ok, _} = insert(run, step, kind))

    assert kinds(run) == kinds

    assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
             insert(run, 11, "deploy")
  end

  test "up sets the kind to copy on qory's copy step with no kind, and on no other step", %{
    run: run
  } do
    assert :ok = Ecto.Migrator.down(Repo, @backfill_version, @backfill, @options)

    # qory's name of the copy step (`cmd/hoststep.go`, `textCopyStep`).
    copy = "copy work out"

    assert {:ok, _} = insert(run, 1, nil, copy)
    assert {:ok, _} = insert(run, 2, nil, "prepare")
    assert {:ok, _} = insert(run, 3, "push", copy)
    assert {:ok, _} = insert(run, 4, nil, nil)

    assert :ok = Ecto.Migrator.up(Repo, @backfill_version, @backfill, @options)
    assert kinds(run) == ["copy", nil, "push", nil]

    # Down keeps the kind; the down of the kinds' migration removes it.
    assert :ok = Ecto.Migrator.down(Repo, @backfill_version, @backfill, @options)
    assert kinds(run) == ["copy", nil, "push", nil]
    assert :ok = Ecto.Migrator.down(Repo, @validate_version, @validate, @options)
    assert :ok = Ecto.Migrator.down(Repo, @kinds_version, @kinds, @options)
    assert kinds(run) == [nil, nil, "push", nil]
  end
end
