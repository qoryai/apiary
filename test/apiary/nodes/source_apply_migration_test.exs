defmodule Apiary.Nodes.SourceApplyMigrationTest do
  # The migration of an adapter's apply items, run down and up again inside the test's
  # transaction, which rolls it all back: up adds `source_apply` and `egress_hosts` with
  # `nodes_source_apply_check`, and down takes them away. It changes `nodes` under every
  # other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.NodesFixtures

  @version 20_261_025_160_400
  @migration Apiary.Repo.Migrations.KeepTheApplyItemsAnAdapterDeclares

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_the_apply_items_an_adapter_declares.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp columns do
    Repo.query!(
      "SELECT column_name FROM information_schema.columns " <>
        "WHERE table_name = 'nodes' AND column_name IN ('source_apply', 'egress_hosts') " <>
        "ORDER BY column_name"
    ).rows
  end

  defp set!(id, assignments) do
    Repo.query!("UPDATE nodes SET #{assignments} WHERE id = $1", [Ecto.UUID.dump!(id)])
  end

  test "down takes the columns and the check away, and up brings them back" do
    adapter = adapter_fixture()

    set!(
      adapter.id,
      ~s(source_apply = '[{"hosts": ["a.example"], "scheme": "bearer"}]', ) <>
        "egress_hosts = ARRAY['a.example']"
    )

    down!()
    assert columns() == []

    up!()
    assert columns() == [["egress_hosts"], ["source_apply"]]

    assert_raise Postgrex.Error, ~r/nodes_source_apply_check/, fn ->
      set!(adapter.id, "source_apply = '[]'")
    end

    assert %{num_rows: 1} =
             set!(adapter.id, ~s(source_apply = '[{"hosts": ["a.example"], "scheme": "bearer"}]'))
  end
end
