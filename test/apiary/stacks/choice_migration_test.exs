defmodule Apiary.Stacks.ChoiceMigrationTest do
  # The migration that keeps a harness choice on a target's row and on the organisation's
  # row, run down and up again inside the test's transaction, which rolls it all back: up
  # clears the choice `target_file` and deletes a row left with nothing; down clears a
  # choice on a target's or the organisation's row. It changes `stacks` under every other
  # test, so this is not async. The rows are written in raw SQL, as the schema no longer
  # takes `target_file`.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Target

  @migration {20_261_028_213_000,
              Apiary.Repo.Migrations.KeepAHarnessChoiceForATargetAndTheOrganisation,
              "keep_a_harness_choice_for_a_target_and_the_organisation"}

  @document "extends: {git: \"https://code.example.com/acme/harness\", ref: v1}\n"

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down! do
    {version, migration, _name} = @migration
    Ecto.Migrator.down(Repo, version, migration, @options)
  end

  defp up! do
    {version, migration, _name} = @migration
    Ecto.Migrator.up(Repo, version, migration, @options)
  end

  setup do
    %{scope: scope} = sign_up_fixture()

    target =
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "code.example.com",
        path: "acme/app",
        first_seen_at: DateTime.utc_now()
      })

    %{scope: scope, target: target}
  end

  # A row of the organisation of `scope` at `place`, with `harness`, `workflow` and
  # `choice`; its id.
  defp insert!(ctx, place, harness, workflow, choice) do
    id = Ecto.UUID.generate()

    {workspace_id, target_id} =
      case place do
        :organisation -> {nil, nil}
        :workspace -> {ctx.scope.workspace.id, nil}
        :target -> {ctx.scope.workspace.id, ctx.target.id}
      end

    Repo.query!(
      "INSERT INTO stacks (id, organisation_id, workspace_id, target_id, workflow, harness, " <>
        "choice, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.scope.organisation.id),
        workspace_id && Ecto.UUID.dump!(workspace_id),
        target_id && Ecto.UUID.dump!(target_id),
        workflow,
        harness,
        choice
      ]
    )

    id
  end

  # The choice of the row `id`, `:deleted` for a row that is gone.
  defp choice(id) do
    case Repo.query!("SELECT choice FROM stacks WHERE id = $1", [Ecto.UUID.dump!(id)]) do
      %{rows: [[choice]]} -> choice
      %{rows: []} -> :deleted
    end
  end

  test "the check takes qory or repository with a document on a row with no workflow, at each place",
       ctx do
    for place <- [:organisation, :workspace, :target], choice <- ["qory", "repository"] do
      id = insert!(ctx, place, @document, nil, choice)
      assert choice(id) == choice
      Repo.query!("DELETE FROM stacks WHERE id = $1", [Ecto.UUID.dump!(id)])
    end

    for {harness, workflow, choice} <- [
          {nil, nil, "qory"},
          {@document, "explore", "repository"},
          {@document, nil, "target_file"}
        ] do
      assert_raise Postgrex.Error, ~r/stacks_choice_check/, fn ->
        Repo.transact(fn ->
          {:ok, insert!(ctx, :workspace, harness, workflow, choice)}
        end)
      end
    end
  end

  test "up clears target_file and deletes a row left with nothing; down clears a target's and the organisation's choice",
       ctx do
    shared = insert!(ctx, :organisation, @document, nil, "qory")
    by_target = insert!(ctx, :target, @document, nil, "repository")
    workspace = insert!(ctx, :workspace, @document, nil, "repository")

    assert :ok = down!()
    assert choice(shared) == nil
    assert choice(by_target) == nil
    assert choice(workspace) == "repository"

    Repo.query!("DELETE FROM stacks WHERE id = $1", [Ecto.UUID.dump!(workspace)])
    with_document = insert!(ctx, :workspace, @document, nil, "target_file")

    assert :ok = up!()
    assert choice(with_document) == nil
    assert choice(shared) == nil

    Repo.query!("DELETE FROM stacks WHERE id = $1", [Ecto.UUID.dump!(with_document)])
    assert :ok = down!()
    alone = insert!(ctx, :workspace, nil, nil, "target_file")

    assert :ok = up!()
    assert choice(alone) == :deleted
  end
end
