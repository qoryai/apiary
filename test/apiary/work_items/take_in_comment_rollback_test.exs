defmodule Apiary.WorkItems.TakeInCommentRollbackTest do
  # A take in whose comment the database refuses writes nothing: no work item, no run, no
  # feed entry and no comment. The test changes the check on `source_item_comments`
  # inside its transaction, which keeps the table's lock until it ends, so it is not
  # async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Comment
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  test "a comment the database refuses rolls the take in back, and the take in again", _ctx do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    ticket = backlog_ticket_fixture(scope, connection: connection)
    again = backlog_ticket_fixture(scope, connection: connection)
    {:ok, work_item} = WorkItems.take_in(scope, again.public_id)
    {:ok, closed} = WorkItems.close(scope, work_item)

    Repo.query!("""
    ALTER TABLE source_item_comments DROP CONSTRAINT source_item_comments_body_check,
      ADD CONSTRAINT source_item_comments_body_check
        CHECK (char_length(body) <= 65536 AND body <> 'Refused.')
    """)

    assert {:error, %Ecto.Changeset{errors: [body: {_message, opts}]}} =
             WorkItems.take_in(scope, ticket.public_id, %{comment: "Refused."})

    assert opts[:constraint] == :check
    assert Repo.aggregate(from(w in WorkItem, where: w.item_id == ^ticket.id), :count) == 0
    assert Repo.aggregate(from(c in Comment, where: c.item_id == ^ticket.id), :count) == 0
    assert Feed.entries(Repo.get!(Node, ticket.adapter_id)) |> length() == 1

    runs_before = Repo.aggregate(DispatchRun, :count)

    assert {:error, %Ecto.Changeset{}} =
             WorkItems.take_in_again(scope, again.public_id, %{comment: "Refused."})

    assert Repo.get!(WorkItem, work_item.id).state == closed.state
    assert Repo.get!(WorkItem, work_item.id).take_in == 1
    assert Repo.aggregate(DispatchRun, :count) == runs_before
    assert Repo.aggregate(from(c in Comment, where: c.item_id == ^again.id), :count) == 0
  end
end
