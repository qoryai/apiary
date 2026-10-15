defmodule Apiary.WorkItemsFixtures do
  @moduledoc "Test helpers for the work items of a workspace and their events."

  alias Apiary.Accounts.Scope
  alias Apiary.Repo
  alias Apiary.WorkItems.{Number, WorkItem, WorkItemEvent}

  @doc """
  A work item of the scope's workspace, taken in by the scope's person, who owns it,
  with the next number and its `taken_in` event, written in one transaction as a take in
  writes them. `attrs` overrides the snapshot: `ref`, `url`, `title`,
  `collection_title`, `owner_id` and `first_instruction`.
  """
  def work_item_fixture(%Scope{workspace: workspace, user: user}, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        ref: "acme/shop#12",
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
end
