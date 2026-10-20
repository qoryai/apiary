defmodule Apiary.Adapters.CollectionNounTest do
  # What an adapter calls its collections, as its description's source role says
  # (`Apiary.Nodes.Node.source_role_changeset/2`): the words of one source
  # (`Apiary.Adapters.collection_noun/1`), and the words a page about many uses
  # (`shared_collection_noun/1`, `workspace_collection_noun/1`,
  # `organisation_collection_noun/1`). A source with no items names its collections too,
  # so it counts.
  use Apiary.DataCase, async: true

  import Apiary.DescriptionFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @project %{one: "project", other: "projects"}
  @board %{one: "board", other: "boards"}

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

  # An adapter whose source calls its collections boards: example-tracker.json with other
  # words for them, which no description of the contract names.
  defp boards_adapter(scope) do
    %{adapter: adapter} = adapter(scope)

    description =
      "example-tracker.json"
      |> contract_description()
      |> put_in(["roles", "source", "collection_noun"], %{"one" => "board", "other" => "boards"})
      |> read_description()

    adapter |> Node.source_role_changeset(description) |> Repo.update!()
  end

  test "an adapter's: the description's, or none for collection and collections", ctx do
    %{adapter: plain} = adapter(ctx.scope)
    assert Adapters.collection_noun(plain) == nil

    %{adapter: tracker} = adapter(ctx.scope, "example-tracker.json")
    assert Adapters.collection_noun(tracker) == @project

    # A source with no items names its collections.
    %{adapter: projects} = adapter(ctx.scope, "example-projects.json")
    refute Adapters.items?(projects)
    assert Adapters.collection_noun(projects) == @project

    # Another source's words.
    assert Adapters.collection_noun(boards_adapter(ctx.scope)) == @board

    # Described again, with none: the words go.
    assert Adapters.collection_noun(describe_source(tracker, "acme-tracker.json")) == nil
  end

  test "of many: the one all the sources name, those with no items included", ctx do
    %{adapter: tracker} = adapter(ctx.scope, "example-tracker.json")
    %{adapter: projects} = adapter(ctx.scope, "example-projects.json")
    %{adapter: plain} = adapter(ctx.scope)
    boards = boards_adapter(ctx.scope)

    assert Adapters.shared_collection_noun([]) == nil
    assert Adapters.shared_collection_noun([tracker]) == @project
    assert Adapters.shared_collection_noun([tracker, projects]) == @project
    assert Adapters.shared_collection_noun([projects]) == @project
    assert Adapters.shared_collection_noun([tracker, plain]) == nil
    assert Adapters.shared_collection_noun([tracker, boards]) == nil
    assert Adapters.shared_collection_noun([boards]) == @board
    assert Adapters.shared_collection_noun([plain]) == nil
  end

  test "a workspace's: of the sources of the live collections assigned to it", ctx do
    %{connection: tracker} = adapter(ctx.scope, "example-tracker.json")
    %{connection: projects} = adapter(ctx.scope, "example-projects.json")
    %{connection: plain} = adapter(ctx.scope)
    other = workspace_fixture(ctx.scope.organisation, "Second")

    assert Adapters.workspace_collection_noun(ctx.scope) == nil

    source_collection_fixture(ctx.scope, tracker)
    source_collection_fixture(ctx.scope, projects)
    assert Adapters.workspace_collection_noun(ctx.scope) == @project

    # Another workspace's and an unassigned one do not count.
    source_collection_fixture(ctx.scope, plain, %{workspace_id: other.id})
    source_collection_fixture(ctx.scope, plain, %{workspace_id: nil})
    assert Adapters.workspace_collection_noun(ctx.scope) == @project

    # One assigned here that names none makes them differ.
    source_collection_fixture(ctx.scope, plain)
    assert Adapters.workspace_collection_noun(ctx.scope) == nil

    # Another organisation's person reads none of them.
    %{scope: stranger} = sign_up_fixture()
    assert Adapters.workspace_collection_noun(stranger) == nil
    assert Adapters.workspace_collection_noun(%{stranger | workspace: ctx.scope.workspace}) == nil
  end

  test "an organisation's: of the sources of its connected connections", ctx do
    adapter(ctx.scope, "example-projects.json")
    assert Adapters.organisation_collection_noun(ctx.scope) == @project

    adapter(ctx.scope, "example-tracker.json")
    assert Adapters.organisation_collection_noun(ctx.scope) == @project

    %{connection: plain} = adapter(ctx.scope)
    assert Adapters.organisation_collection_noun(ctx.scope) == nil

    plain
    |> Ecto.Changeset.change(
      state: :ended,
      ended_at: DateTime.utc_now(),
      ended_reason: :adapter_reported
    )
    |> Repo.update!()

    assert Adapters.organisation_collection_noun(ctx.scope) == @project

    %{scope: stranger} = sign_up_fixture()
    assert Adapters.organisation_collection_noun(stranger) == nil

    assert Adapters.organisation_collection_noun(%{
             stranger
             | organisation: ctx.scope.organisation
           }) == nil
  end
end
