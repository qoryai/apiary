defmodule Apiary.WorkItems.TakenInCommentTest do
  # Whether the person who took a work item in wrote a comment with that take in
  # (`Apiary.WorkItems.taken_in_comment?/2`): their comment of this take in only, not an
  # earlier take in's in the same second, not a deleted one, and nothing through a scope
  # of another organisation.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    %{scope: scope, ticket: ticket}
  end

  defp comments(ticket), do: from(c in Comment, where: c.item_id == ^ticket.id)

  test "the comment of this take in only, and nothing through another organisation", ctx do
    %{scope: scope, ticket: ticket} = ctx
    id = ticket.public_id

    {:ok, work_item} = WorkItems.take_in(scope, id, %{comment: "First look."})
    assert WorkItems.taken_in_comment?(scope, work_item)

    %{scope: other} = sign_up_fixture()
    refute WorkItems.taken_in_comment?(other, work_item)

    {:ok, _undone} = WorkItems.undo(scope, work_item)
    {:ok, again} = WorkItems.take_in_again(scope, id, %{})

    # The first take in's comment, as if both take ins fell in the same second.
    Repo.update_all(comments(ticket),
      set: [source_created_at: DateTime.truncate(again.taken_in_at, :second)]
    )

    refute WorkItems.taken_in_comment?(scope, again)

    {:ok, _undone} = WorkItems.undo(scope, Repo.get!(WorkItem, work_item.id))
    {:ok, third} = WorkItems.take_in_again(scope, id, %{comment: "Second look."})
    assert WorkItems.taken_in_comment?(scope, third)

    Repo.update_all(comments(ticket), set: [deleted_at: DateTime.utc_now()])
    refute WorkItems.taken_in_comment?(scope, third)
  end
end
