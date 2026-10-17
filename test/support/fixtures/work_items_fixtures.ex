defmodule Apiary.WorkItemsFixtures do
  @moduledoc "Test helpers for the work items of a workspace and their events."

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{Number, WorkItem, WorkItemEvent}

  @doc """
  A work item of the scope's workspace, taken in by the scope's person, who owns it,
  with the next number and its `taken_in` event, written in one transaction as a take in
  writes them. `attrs` overrides the snapshot: `connection_id` (else a new connection of
  the scope's organisation, `ticket_connection_fixture/1`), `item_id` (else a new ticket
  of that connection with the work item's ref, `source_item_fixture/2`), `external_ref`,
  `url`, `title`, `collection_title`, `target_system`, `target_path`, `owner_id` and
  `first_instruction`. The adapter is the connection's.
  """
  def work_item_fixture(%Scope{workspace: workspace, user: user} = scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:connection_id, fn -> ticket_connection_fixture(scope).id end)
      |> Enum.into(%{
        external_ref: "acme/shop#12",
        url: "https://forge.example.com/acme/shop/issues/12",
        title: "The checkout keeps the old price",
        collection_title: "acme/shop",
        target_system: "forge.example.com",
        target_path: "acme/shop",
        owner_id: user.id
      })

    connection = Repo.get!(Connection, attrs.connection_id)

    attrs =
      attrs
      |> Map.put(:adapter_id, connection.adapter_id)
      |> Map.put_new_lazy(:item_id, fn ->
        source_item_fixture(scope, connection: connection, external_ref: attrs.external_ref).id
      end)

    {:ok, work_item} =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        work_item =
          %WorkItem{
            organisation_id: workspace.organisation_id,
            workspace_id: workspace.id,
            number: Number.next(workspace),
            state: :exploring,
            taken_in_by_id: user.id,
            taken_in_at: now
          }
          |> WorkItem.take_in_changeset(attrs)
          |> Repo.insert!()

        %WorkItemEvent{
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          work_item_id: work_item.id
        }
        |> WorkItemEvent.changeset(%{
          kind: :taken_in,
          actor_kind: :person,
          actor_id: user.id,
          at: now
        })
        |> Repo.insert!()

        {:ok, work_item}
      end)

    work_item
  end

  @doc """
  A collection of the connection, of the scope's organisation, linked to the scope's
  workspace, with a ref no other collection has, written straight to the database.
  `attrs` overrides `external_ref`, `url`, `title`, `target_system`, `target_path` and
  `workspace_id`.
  """
  def source_collection_fixture(%Scope{} = scope, %Connection{} = connection, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    fields =
      Enum.into(attrs, %{
        external_ref: "acme/shop-#{unique}",
        url: "https://forge.example.com/acme/shop-#{unique}",
        title: "acme/shop",
        target_system: nil,
        target_path: nil,
        workspace_id: scope.workspace && scope.workspace.id
      })

    Repo.insert!(
      struct!(
        %Collection{
          public_id: Apiary.PublicId.generate(Collection.prefix()),
          organisation_id: connection.organisation_id,
          adapter_id: connection.adapter_id,
          connection_id: connection.id,
          last_listed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        fields
      )
    )
  end

  @doc """
  A ticket, an open item of a collection, as an adapter sends one, written through
  `Apiary.Sources.Item.changeset/2`. `attrs` takes `collection` (else a new one of
  `connection`, else of a new connection of the scope's organisation) and overrides any
  field of the item.
  """
  def source_item_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)

    collection =
      Map.get_lazy(attrs, :collection, fn ->
        connection = Map.get_lazy(attrs, :connection, fn -> ticket_connection_fixture(scope) end)
        source_collection_fixture(scope, connection)
      end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fields =
      attrs
      |> Map.drop([:collection, :connection])
      |> Enum.into(%{
        external_ref: "acme/shop#12",
        key: "#12",
        url: "https://forge.example.com/acme/shop/issues/12",
        title: "The checkout keeps the old price",
        body: "The basket shows the price from before the sale.",
        body_format: "markdown",
        filed_by_name: "Avery Example",
        filed_by_kind: :person,
        labels: ["bug"],
        state: :open,
        state_reason: nil,
        comment_count: 0,
        source_created_at: now,
        source_updated_at: now
      })

    %Item{
      organisation_id: collection.organisation_id,
      adapter_id: collection.adapter_id,
      collection_id: collection.id
    }
    |> Item.changeset(fields)
    |> Repo.insert!()
  end

  @doc """
  A connected connection of the scope's organisation to a new adapter of the instance,
  the kind of row a work item's ticket comes through, written straight to the database
  so that it needs no feature on (`Apiary.NodesFixtures.connection_fixture/3` goes
  through `Apiary.Adapters.connect/2`, which does).
  """
  def ticket_connection_fixture(%Scope{organisation: organisation, user: user}) do
    adapter =
      %Node{
        kind: :adapter,
        organisation_id: nil,
        workspace_id: nil,
        created_by_id: user.id,
        instance_limit: nil,
        gateway_choice: :direct
      }
      |> Node.adapter_changeset(%{name: Apiary.NodesFixtures.unique_node_name()})
      |> Repo.insert!()

    now = DateTime.utc_now()

    Repo.insert!(%Connection{
      public_id: Apiary.PublicId.generate(Connection.prefix()),
      organisation_id: organisation.id,
      adapter_id: adapter.id,
      created_by_id: user.id,
      state: :connected,
      pass_nonce: :crypto.strong_rand_bytes(16),
      pass_nonce_used_at: now,
      connected_at: now
    })
  end
end
