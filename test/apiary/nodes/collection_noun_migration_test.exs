defmodule Apiary.Nodes.CollectionNounMigrationTest do
  # The migration that refuses "work item" and "work items" as what a source calls its
  # collections (`nodes_collection_noun_check`), run down and up again inside the test's
  # transaction, which rolls it all back. It changes `nodes` under every other test, so
  # this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Ecto.Query
  import Apiary.NodesFixtures

  alias Apiary.Nodes.Node

  # The adapters are made where the feature they belong to is on.
  @moduletag needs: :factory

  @refuse {20_261_018_150_000, Apiary.Repo.Migrations.RefuseWorkItemAsACollectionNoun,
           "refuse_work_item_as_a_collection_noun"}

  setup_all do
    {version, migration, name} = @refuse

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp set(node, one, other) do
    Repo.update_all(from(n in Node, where: n.id == ^node.id),
      set: [collection_noun_one: one, collection_noun_other: other]
    )
  end

  defp words(node) do
    node = Repo.get!(Node, node.id)
    {node.collection_noun_one, node.collection_noun_other}
  end

  test "up clears the words it refuses, and the check refuses them after; down lets them in" do
    down!(@refuse)

    [work_item, work_items, project, plain] = for _ <- 1..4, do: adapter_fixture()

    assert {1, _} = set(work_item, "work item", "projects")
    assert {1, _} = set(work_items, "board", "work-items")
    assert {1, _} = set(project, "project", "projects")

    up!(@refuse)

    assert words(work_item) == {nil, nil}
    assert words(work_items) == {nil, nil}
    assert words(project) == {"project", "projects"}
    assert words(plain) == {nil, nil}

    for {one, other} <- [
          {"work item", "projects"},
          {"project", "work items"},
          {"work-item", "projects"},
          {"project", "work-items"}
        ] do
      assert_raise Postgrex.Error, ~r/nodes_collection_noun_check/, fn ->
        Repo.transaction(fn -> set(plain, one, other) end)
      end
    end

    # A word that holds "work" or "items" and is not one of those is not refused.
    assert {1, _} = set(plain, "work board", "work items list")

    down!(@refuse)

    assert {1, _} = set(plain, "work item", "work-items")

    up!(@refuse)

    assert words(plain) == {nil, nil}
  end
end
