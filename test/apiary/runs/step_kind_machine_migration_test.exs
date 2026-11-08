defmodule Apiary.Runs.StepKindMachineMigrationTest do
  # The migration that adds the kind `machine` to `run_steps`, run down and up again
  # inside the test's transaction, which rolls it all back. It changes the table under
  # every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.Step

  @kinds_version 20_261_106_151_500
  @kinds Apiary.Repo.Migrations.LetAStepBeAMachine
  @validate_version 20_261_106_151_600
  @validate Apiary.Repo.Migrations.ValidateAStepSKindsWithAMachine

  setup_all do
    for {module, file} <- [
          {@kinds, "#{@kinds_version}_let_a_step_be_a_machine.exs"},
          {@validate, "#{@validate_version}_validate_a_step_s_kinds_with_a_machine.exs"}
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
    assert :ok = Ecto.Migrator.down(Repo, @validate_version, @validate, @options)
    assert :ok = Ecto.Migrator.down(Repo, @kinds_version, @kinds, @options)
  end

  defp insert(run, step, kind) do
    Repo.query(
      "INSERT INTO run_steps (id, organisation_id, workspace_id, run_id, step, kind, state) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, 'running')",
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(run.organisation_id),
        Ecto.UUID.dump!(run.workspace_id),
        Ecto.UUID.dump!(run.id),
        step,
        kind
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

  test "down leaves a machine step with no kind, and the check fails the kind again", %{run: run} do
    assert {:ok, _} = insert(run, 1, "machine")
    assert {:ok, _} = insert(run, 2, "push")

    down!()

    assert kinds(run) == [nil, "push"]
    assert validated?()

    assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
             insert(run, 3, "machine")
  end

  test "up lets a step be every kind of the list, and no other, and validates", %{run: run} do
    down!()

    # The first migration adds the check without a scan; the second validates it.
    assert :ok = Ecto.Migrator.up(Repo, @kinds_version, @kinds, @options)
    refute validated?()
    assert :ok = Ecto.Migrator.up(Repo, @validate_version, @validate, @options)
    assert validated?()

    for {kind, step} <- Enum.with_index(Step.kinds(), 1),
        do: assert({:ok, _} = insert(run, step, kind))

    assert kinds(run) == ~w(fetch compose image build setup join wall push machine)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
             insert(run, 10, "deploy")
  end
end
