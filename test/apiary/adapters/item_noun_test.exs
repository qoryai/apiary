defmodule Apiary.Adapters.ItemNounTest do
  # What an adapter calls its items, and whether it reports any, as its description's
  # source role says (`Apiary.Nodes.Node.source_role_changeset/2`), held by the database
  # to the contract's words; the words of one source (`Apiary.Adapters.item_noun/1`), and
  # the words a page about many uses (`shared_item_noun/1`, `workspace_item_noun/1`,
  # `organisation_item_noun/1`), and those of a target's sources (`target_item_nouns/2`).
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Adapters, Repo, Targets}
  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @issue %{one: "issue", other: "issues"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp adapter(scope, description \\ nil) do
    connection = ticket_connection_fixture(scope)
    adapter = Repo.get!(Node, connection.adapter_id)
    adapter = if description, do: describe_source(adapter, description), else: adapter
    %{adapter: adapter, connection: connection}
  end

  defp set(%Node{id: id}, fields),
    do: Repo.update_all(from(n in Node, where: n.id == ^id), set: fields)

  describe "an adapter's words" do
    test "the description's, or none for the default; and whether it reports items", ctx do
      %{adapter: plain} = adapter(ctx.scope)
      assert Adapters.item_noun(plain) == nil
      assert Adapters.items?(plain)

      %{adapter: tracker} = adapter(ctx.scope, "example-tracker.json")
      assert {tracker.item_noun_one, tracker.item_noun_other} == {"issue", "issues"}
      assert Adapters.item_noun(tracker) == @issue
      assert Adapters.items?(tracker)

      %{adapter: projects} = adapter(ctx.scope, "example-projects.json")
      assert Adapters.item_noun(projects) == nil
      refute Adapters.items?(projects)

      # Described again, with none: the words go.
      assert Adapters.item_noun(describe_source(tracker, "acme-tracker.json")) == nil
    end

    test "the database holds them to the contract's words, and to adapters", ctx do
      %{adapter: tracker} = adapter(ctx.scope, "example-tracker.json")

      for fields <- [
            [item_noun_one: "work item"],
            [item_noun_other: "work-items"],
            [item_noun_one: "Issue"],
            [item_noun_one: "user  story"],
            [item_noun_one: String.duplicate("z", 33)],
            [item_noun_one: nil],
            [items: false]
          ] do
        assert_raise Postgrex.Error, ~r/nodes_items_check/, fn -> set(tracker, fields) end
      end

      pool = pool_fixture(ctx.scope)

      for fields <- [[items: false], [item_noun_one: "issue", item_noun_other: "issues"]] do
        assert_raise Postgrex.Error, ~r/nodes_items_check/, fn -> set(pool, fields) end
      end
    end
  end

  describe "the words of many sources" do
    test "the one all the sources with items name; none when they differ or name none", ctx do
      %{adapter: tracker} = adapter(ctx.scope, "example-tracker.json")
      %{adapter: also} = adapter(ctx.scope, "example-tracker.json")
      %{adapter: plain} = adapter(ctx.scope)
      %{adapter: projects} = adapter(ctx.scope, "example-projects.json")

      assert Adapters.shared_item_noun([]) == nil
      assert Adapters.shared_item_noun([tracker]) == @issue
      assert Adapters.shared_item_noun([tracker, also]) == @issue
      assert Adapters.shared_item_noun([tracker, plain]) == nil
      assert Adapters.shared_item_noun([plain]) == nil

      # A source with no items is left out.
      assert Adapters.shared_item_noun([tracker, projects]) == @issue
      assert Adapters.shared_item_noun([projects]) == nil
    end

    test "a workspace's: of the sources of the live collections assigned to it", ctx do
      %{connection: tracker} = adapter(ctx.scope, "example-tracker.json")
      %{connection: plain} = adapter(ctx.scope)
      %{connection: projects} = adapter(ctx.scope, "example-projects.json")
      other = workspace_fixture(ctx.scope.organisation, "Second")

      assert Adapters.workspace_item_noun(ctx.scope) == nil

      source_collection_fixture(ctx.scope, tracker)
      source_collection_fixture(ctx.scope, projects)
      assert Adapters.workspace_item_noun(ctx.scope) == @issue

      # Another workspace's, an unassigned one and an ended one do not count.
      source_collection_fixture(ctx.scope, plain, %{workspace_id: other.id})
      source_collection_fixture(ctx.scope, plain, %{workspace_id: nil})

      source_collection_fixture(ctx.scope, plain, %{
        ended_at: DateTime.utc_now(),
        ended_reason: :disconnected
      })

      assert Adapters.workspace_item_noun(ctx.scope) == @issue

      # Nor one of a connection that ended.
      ended = source_collection_fixture(ctx.scope, plain)
      assert Adapters.workspace_item_noun(ctx.scope) == nil

      Repo.get!(Connection, ended.connection_id)
      |> Ecto.Changeset.change(
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )
      |> Repo.update!()

      assert Adapters.workspace_item_noun(ctx.scope) == @issue
    end

    test "nothing to a person who may not read the workspace's work items", ctx do
      %{connection: tracker} = adapter(ctx.scope, "example-tracker.json")
      source_collection_fixture(ctx.scope, tracker)
      assert Adapters.workspace_item_noun(ctx.scope) == @issue

      # Another organisation's person, in their workspace or with this one put in their
      # scope.
      %{scope: stranger} = sign_up_fixture()
      assert Adapters.workspace_item_noun(stranger) == nil
      assert Adapters.workspace_item_noun(%{stranger | workspace: ctx.scope.workspace}) == nil
    end
  end

  describe "an organisation's words" do
    test "of the sources of its connected connections, to a reader of its Activity", ctx do
      adapter(ctx.scope, "example-tracker.json")
      assert Adapters.organisation_item_noun(ctx.scope) == @issue

      # A source with no items is left out; one that names none makes them differ.
      adapter(ctx.scope, "example-projects.json")
      assert Adapters.organisation_item_noun(ctx.scope) == @issue

      %{connection: plain} = adapter(ctx.scope)
      assert Adapters.organisation_item_noun(ctx.scope) == nil

      # A connection that ended does not count.
      plain
      |> Ecto.Changeset.change(
        state: :ended,
        ended_at: DateTime.utc_now(),
        ended_reason: :adapter_reported
      )
      |> Repo.update!()

      assert Adapters.organisation_item_noun(ctx.scope) == @issue

      # Another organisation's person reads none of them.
      %{scope: stranger} = sign_up_fixture()
      assert Adapters.organisation_item_noun(stranger) == nil

      assert Adapters.organisation_item_noun(%{stranger | organisation: ctx.scope.organisation}) ==
               nil
    end
  end

  describe "a target's words" do
    test "of the sources of the collections with its system and path, by target", ctx do
      started_run(ctx.scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
      started_run(ctx.scope, %{"forge" => "code.example.com", "repository" => "acme/api"})
      shop = Targets.get(ctx.scope, "code.example.com", "acme/shop")
      api = Targets.get(ctx.scope, "code.example.com", "acme/api")
      org = ctx.scope.organisation.id

      assert Adapters.target_item_nouns(org, []) == %{}
      assert Adapters.target_item_nouns(org, [shop.id, api.id]) == %{}

      %{connection: tracker} = adapter(ctx.scope, "example-tracker.json")
      %{connection: plain} = adapter(ctx.scope)
      at = fn path -> %{target_system: "code.example.com", target_path: path} end

      # An ended collection counts: the entry is about what was so.
      source_collection_fixture(
        ctx.scope,
        tracker,
        Map.merge(at.("acme/shop"), %{ended_at: DateTime.utc_now(), ended_reason: :disconnected})
      )

      source_collection_fixture(ctx.scope, plain, at.("acme/api"))
      assert Adapters.target_item_nouns(org, [shop.id, api.id]) == %{shop.id => @issue}

      # Another organisation's targets are not read.
      %{scope: stranger} = sign_up_fixture()
      assert Adapters.target_item_nouns(stranger.organisation.id, [shop.id]) == %{}
    end
  end
end
