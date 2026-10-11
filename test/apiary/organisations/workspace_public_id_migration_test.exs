defmodule Apiary.Organisations.WorkspacePublicIdMigrationTest do
  # The migration that gives every workspace its public id, run down and up again inside
  # the test's transaction, which rolls it all back. It changes the `workspaces` table
  # under every other test, so it is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.PublicId

  @version 20_261_011_100_000
  @migration Apiary.Repo.Migrations.GiveAWorkspaceItsId

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_give_a_workspace_its_id.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A workspace row written in SQL, with no public id: the column may not be there.
  defp insert!(organisation, name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO workspaces (id, organisation_id, name, slug, domain, inserted_at, " <>
        "updated_at) VALUES ($1, $2, $3, $4, 'software', now(), now())",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(organisation.id), name, String.downcase(name)]
    )

    id
  end

  defp public_ids do
    %{rows: rows} = Repo.query!("SELECT id, public_id FROM workspaces")
    Map.new(rows, fn [id, public_id] -> {Ecto.UUID.load!(id), public_id} end)
  end

  defp column? do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = 'workspaces' AND column_name = 'public_id'"
      )

    count == 1
  end

  defp function? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_proc WHERE proname = 'workspace_public_id'")

    count == 1
  end

  test "up gives every workspace that was there before its own id of the shape" do
    %{scope: scope} = sign_up_fixture()
    workspace_fixture(scope.organisation)

    down!()
    refute column?()
    refute function?()

    before = for name <- ~w(alpha beta gamma delta), do: insert!(scope.organisation, name)

    up!()
    assert column?()
    assert function?()

    ids = public_ids()
    assert map_size(ids) >= 6

    for id <- before, do: assert(Map.has_key?(ids, id))

    for {_id, public_id} <- ids, do: assert(PublicId.valid?("ws", public_id))

    assert ids |> Map.values() |> Enum.uniq() |> length() == map_size(ids)
  end

  test "the check refuses a malformed id, and the index a taken one" do
    %{scope: scope} = sign_up_fixture()
    id = insert!(scope.organisation, "checked")

    for bad <- ~w(ws_000000000000000 ws_000000000000000u np_0000000000000000) do
      assert_raise Postgrex.Error, ~r/workspaces_public_id_format/, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE workspaces SET public_id = $1 WHERE id = $2", [
            bad,
            Ecto.UUID.dump!(id)
          ])
        end)
      end
    end

    assert_raise Postgrex.Error, ~r/workspaces_public_id_index/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE workspaces SET public_id = $1 WHERE id = $2", [
          scope.workspace.public_id,
          Ecto.UUID.dump!(id)
        ])
      end)
    end
  end

  test "down removes the column and the function; up brings both back, and the default works" do
    %{scope: scope} = sign_up_fixture()

    down!()
    refute column?()
    refute function?()

    up!()
    assert column?()
    assert function?()

    id = insert!(scope.organisation, "after")
    assert PublicId.valid?("ws", Map.fetch!(public_ids(), id))
  end
end
