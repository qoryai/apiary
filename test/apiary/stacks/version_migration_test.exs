defmodule Apiary.Stacks.VersionMigrationTest do
  # The migration that keeps the version of a harness choice, run down and up again inside
  # the test's transaction, which rolls it all back: up makes each saved choice of the
  # Qory harness at fe3b3ab `latest`, and leaves every other row with no version. It
  # changes `stacks` under every other test, so this is not async. The rows are written in
  # raw SQL, as the schema has the columns the migration adds.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Target

  @migration {20_261_029_180_000, Apiary.Repo.Migrations.KeepTheVersionOfAHarnessChoice,
              "keep_the_version_of_a_harness_choice"}

  # The document the save wrote for the Qory harness, at the one commit it wrote.
  @qory "extends:\n  git: \"https://github.com/qoryai/harness\"\n" <>
          "  ref: \"fe3b3ab4a02cd7c57d9efa16bbaf498d5f5de305\"\n  stack: \"core\"\n"

  # The Qory harness at another commit, which no save wrote.
  @other "extends:\n  git: \"https://github.com/qoryai/harness\"\n" <>
           "  ref: \"#{String.duplicate("0a", 20)}\"\n  stack: \"core\"\n"

  @repository "extends:\n  git: \"https://code.example.com/acme/harness\"\n" <>
                "  ref: \"#{String.duplicate("c3", 20)}\"\n"

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

  # A row with `harness` and `choice` at `place`, written while the columns are gone.
  defp insert!(ctx, place, harness, choice) do
    id = Ecto.UUID.generate()

    {workspace_id, target_id} =
      case place do
        :organisation -> {nil, nil}
        :workspace -> {Ecto.UUID.dump!(ctx.scope.workspace.id), nil}
        :target -> {Ecto.UUID.dump!(ctx.scope.workspace.id), Ecto.UUID.dump!(ctx.target.id)}
      end

    Repo.query!(
      "INSERT INTO stacks (id, organisation_id, workspace_id, target_id, harness, choice, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.scope.organisation.id),
        workspace_id,
        target_id,
        harness,
        choice
      ]
    )

    id
  end

  defp version(id) do
    %{rows: [row]} =
      Repo.query!("SELECT version_kind, version_name, harness FROM stacks WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    row
  end

  test "up makes each Qory harness choice at fe3b3ab latest, and leaves every other row as it was",
       ctx do
    assert :ok = down!()

    shared = insert!(ctx, :organisation, @qory, "qory")
    by_target = insert!(ctx, :target, @qory, "qory")
    other = insert!(ctx, :workspace, @other, "qory")
    %{scope: second} = sign_up_fixture()
    repository = insert!(%{ctx | scope: second}, :workspace, @repository, "repository")

    assert :ok = up!()

    assert version(shared) == ["latest", nil, @qory]
    assert version(by_target) == ["latest", nil, @qory]
    assert version(other) == [nil, nil, @other]
    assert version(repository) == [nil, nil, @repository]
  end

  test "the check takes each kind under its choice, with its name, and workspace at a target alone",
       ctx do
    # The check this file's migration writes, not the one the database has: a test
    # database migrated by an earlier text of the migration keeps that text's check, as
    # `mix ecto.migrate` runs no migration a second time.
    assert :ok = down!()
    assert :ok = up!()

    set = fn id, kind, name ->
      Repo.transact(fn ->
        {:ok,
         Repo.query!(
           "UPDATE stacks SET version_kind = $2, version_name = $3 WHERE id = $1",
           [Ecto.UUID.dump!(id), kind, name]
         )}
      end)
    end

    qory = insert!(ctx, :workspace, @qory, "qory")
    repository = insert!(ctx, :target, @repository, "repository")

    for {id, kind, name} <- [
          {qory, "latest", nil},
          {qory, "named", "v1"},
          {repository, "branch", "main"},
          {repository, "tag", "v1"},
          {repository, "commit", String.duplicate("c3", 20)},
          {repository, "workspace", nil},
          {repository, nil, nil}
        ] do
      assert {:ok, _result} = set.(id, kind, name)
    end

    for {id, kind, name} <- [
          {qory, "branch", "main"},
          {qory, "latest", "main"},
          {qory, "workspace", nil},
          {repository, "latest", nil},
          {repository, "tag", nil},
          {repository, nil, "main"},
          {repository, "fixed_branch", "main"}
        ] do
      assert_raise Postgrex.Error, ~r/stacks_version_check/, fn -> set.(id, kind, name) end
    end
  end
end
