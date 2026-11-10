defmodule Apiary.Stacks.QoryVersionMigrationTest do
  # The migration that lets a choice of the Qory harness take a branch, a tag or a commit,
  # run down and up again inside the test's transaction, which rolls it all back: up makes
  # each row of the Qory harness at `latest`, at `named` or with no version the branch
  # `main`, with `main` as its document's `ref`, and leaves the rows of harness
  # repositories as they were. It changes `stacks` under every other test, so this is not
  # async. The rows are written in raw SQL, as a save before the migration wrote them.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Runs.Target

  @migration {20_261_106_190_100, Apiary.Repo.Migrations.ChooseABranchTagOrCommitOfTheQoryHarness,
              "choose_a_branch_tag_or_commit_of_the_qory_harness"}

  @pin String.duplicate("0a", 20)

  # The document a save wrote for the Qory harness, at the commit it wrote.
  defp qory(ref, stack \\ "core"),
    do:
      "extends:\n  git: \"https://github.com/qoryai/harness\"\n" <>
        "  ref: \"#{ref}\"\n  stack: \"#{stack}\"\n"

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

  # A row with `harness`, `choice` and the version `{kind, name}` at `place`.
  defp insert!(ctx, place, harness, choice, {kind, name}) do
    id = Ecto.UUID.generate()

    {workspace_id, target_id} =
      case place do
        :organisation -> {nil, nil}
        :workspace -> {Ecto.UUID.dump!(ctx.scope.workspace.id), nil}
        :target -> {Ecto.UUID.dump!(ctx.scope.workspace.id), Ecto.UUID.dump!(ctx.target.id)}
      end

    Repo.query!(
      "INSERT INTO stacks (id, organisation_id, workspace_id, target_id, harness, choice, " <>
        "version_kind, version_name, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(ctx.scope.organisation.id),
        workspace_id,
        target_id,
        harness,
        choice,
        kind,
        name
      ]
    )

    id
  end

  defp row(id) do
    %{rows: [row]} =
      Repo.query!("SELECT version_kind, version_name, harness FROM stacks WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    row
  end

  test "up makes each row of the Qory harness the branch main, and its document's ref main",
       ctx do
    assert :ok = down!()

    shared = insert!(ctx, :organisation, qory(@pin), "qory", {"latest", nil})
    named = insert!(ctx, :workspace, qory(@pin, "software"), "qory", {"named", "v0.1"})
    by_target = insert!(ctx, :target, qory(@pin), "qory", {"workspace", nil})
    %{scope: second} = sign_up_fixture()
    unversioned = insert!(%{ctx | scope: second}, :workspace, qory(@pin), "qory", {nil, nil})

    %{scope: third} = sign_up_fixture()

    repository =
      insert!(%{ctx | scope: third}, :workspace, @repository, "repository", {"branch", "main"})

    assert :ok = up!()

    assert row(shared) == ["branch", "main", qory("main")]
    assert row(named) == ["branch", "main", qory("main", "software")]
    assert row(by_target) == ["workspace", nil, qory("main")]
    assert row(unversioned) == ["branch", "main", qory("main")]
    assert row(repository) == ["branch", "main", @repository]
  end

  test "the check takes a branch, a tag or a commit of the Qory harness, and latest no more",
       ctx do
    assert :ok = down!()
    assert :ok = up!()

    qory = insert!(ctx, :workspace, qory("main"), "qory", {"branch", "main"})

    set = fn kind, name ->
      Repo.transact(fn ->
        {:ok,
         Repo.query!(
           "UPDATE stacks SET version_kind = $2, version_name = $3 WHERE id = $1",
           [Ecto.UUID.dump!(qory), kind, name]
         )}
      end)
    end

    for {kind, name} <- [{"tag", "v1"}, {"commit", @pin}, {"branch", "main"}],
        do: assert({:ok, _result} = set.(kind, name))

    for {kind, name} <- [{"latest", nil}, {"named", "v1"}, {"tag", nil}] do
      assert_raise Postgrex.Error, ~r/stacks_version_check/, fn -> set.(kind, name) end
    end
  end

  test "down makes the branch rows of the Qory harness latest, and refuses while one is at a tag",
       ctx do
    branch = insert!(ctx, :organisation, qory("main"), "qory", {"branch", "main"})

    assert :ok = down!()
    assert row(branch) == ["latest", nil, qory("main")]
    assert :ok = up!()

    %{scope: second} = sign_up_fixture()
    insert!(%{ctx | scope: second}, :workspace, qory("v1"), "qory", {"tag", "v1"})

    assert_raise Postgrex.Error, ~r/Choose the Qory harness at a branch/, fn -> down!() end
  end
end
