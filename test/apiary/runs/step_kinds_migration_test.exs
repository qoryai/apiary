defmodule Apiary.Runs.StepKindsMigrationTest do
  # The migration that adds the kinds `build` and `push` to `run_steps`, run down and up
  # again inside the test's transaction, which rolls it all back. It changes the table
  # under every other test, so it is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.Step

  @kinds_version 20_261_102_150_000
  @kinds Apiary.Repo.Migrations.LetAStepBeABuildOrAPush
  @validate_version 20_261_102_150_100
  @validate Apiary.Repo.Migrations.ValidateAStepSKinds

  setup_all do
    for {module, file} <- [
          {@kinds, "#{@kinds_version}_let_a_step_be_a_build_or_a_push.exs"},
          {@validate, "#{@validate_version}_validate_a_step_s_kinds.exs"}
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

  defp up! do
    assert :ok = Ecto.Migrator.up(Repo, @kinds_version, @kinds, @options)
    assert :ok = Ecto.Migrator.up(Repo, @validate_version, @validate, @options)
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

  test "down leaves a build and a push step with no kind, and refuses the kinds again",
       %{run: run} do
    assert {:ok, _} = insert(run, 1, "fetch")
    assert {:ok, _} = insert(run, 2, "build")
    assert {:ok, _} = insert(run, 3, "push")

    down!()

    assert kinds(run) == ["fetch", nil, nil]
    assert validated?()

    for {kind, step} <- [{"build", 4}, {"push", 5}] do
      assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
               insert(run, step, kind)
    end
  end

  test "up lets a step be every kind of the list, and no other, and validates", %{run: run} do
    assert {:ok, _} = insert(run, 1, "fetch")

    down!()
    up!()

    assert validated?()

    for {kind, step} <- Enum.with_index(~w(compose image build setup join wall push), 2),
        do: assert({:ok, _} = insert(run, step, kind))

    assert kinds(run) == ~w(fetch compose image build setup join wall push)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "run_steps_kind_check"}}} =
             insert(run, 9, "deploy")
  end
end
