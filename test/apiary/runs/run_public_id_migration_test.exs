defmodule Apiary.Runs.RunPublicIdMigrationTest do
  # The migration that gives every run its `rn_` id, run down and up again inside the
  # test's transaction, which rolls it all back. It changes the `runs` table under every
  # other test, so it is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.PublicId

  @version 20_261_017_100_000
  @migration Apiary.Repo.Migrations.GiveARunItsId

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_give_a_run_its_id.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  # A run row written in SQL, with no public id: the column may not be there.
  defp insert!(scope) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO runs (id, organisation_id, workspace_id, node_run_id, state, inserted_at, " <>
        "updated_at) VALUES ($1, $2, $3, $4, 'pending', now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    id
  end

  defp public_ids do
    %{rows: rows} = Repo.query!("SELECT id, public_id FROM runs")
    Map.new(rows, fn [id, public_id] -> {Ecto.UUID.load!(id), public_id} end)
  end

  defp column? do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.columns " <>
          "WHERE table_name = 'runs' AND column_name = 'public_id'"
      )

    count == 1
  end

  defp function? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_proc WHERE proname = 'run_public_id'")

    count == 1
  end

  test "up gives every run that was there before an id of the shape, each another" do
    %{scope: scope} = sign_up_fixture()

    down!()
    refute column?()
    refute function?()

    before = for _ <- 1..6, do: insert!(scope)

    up!()
    assert column?()
    assert function?()

    ids = public_ids()

    for id <- before, do: assert(PublicId.valid?("rn", Map.fetch!(ids, id)))
    for {_id, public_id} <- ids, do: assert(PublicId.valid?("rn", public_id))
    assert ids |> Map.values() |> Enum.uniq() |> length() == map_size(ids)
  end

  test "the function runs under pg_catalog alone, whatever the caller's search_path" do
    %{rows: [[config]]} =
      Repo.query!("SELECT proconfig FROM pg_proc WHERE proname = 'run_public_id'")

    assert config == ["search_path=pg_catalog"]

    Repo.query!("SET LOCAL search_path = nowhere")
    %{rows: [[id]]} = Repo.query!("SELECT public.run_public_id()")
    assert PublicId.valid?("rn", id)
  end

  test "down removes the column and the function; up brings both back, and the default works" do
    %{scope: scope} = sign_up_fixture()

    down!()
    refute column?()
    refute function?()

    up!()
    assert column?()
    assert function?()

    id = insert!(scope)
    assert PublicId.valid?("rn", Map.fetch!(public_ids(), id))
  end
end
