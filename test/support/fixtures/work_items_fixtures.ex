defmodule Apiary.WorkItemsFixtures do
  @moduledoc "Test helpers for the work items of a workspace and their events."

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.WorkItems.{Number, WorkItem, WorkItemEvent}

  @doc """
  A work item of the scope's workspace, taken in by the scope's person, who owns it,
  with the next number and its `taken_in` event, written in one transaction as a take in
  writes them. `attrs` overrides the snapshot: `connection_id` (else a new connection of
  the scope's organisation, `ticket_connection_fixture/1`), `external_ref`, `url`,
  `title`, `collection_title`, `owner_id` and `first_instruction`.
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
        owner_id: user.id
      })

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
