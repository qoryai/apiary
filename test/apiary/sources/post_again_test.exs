defmodule Apiary.Sources.PostAgainTest do
  # A member posts again a comment the adapter reported not posted
  # (`Apiary.Sources.post_again/2`): a new `comment` entry with the same comment_id and the
  # comment `:posting` again, its reason cleared, in one transaction, and the Backlog and
  # the ticket's work item told; `:kept` and no entry where the source no longer takes
  # comments; `:forbidden` without `work_item.take_in` in the workspace, first;
  # `:not_found` for a comment that is not on a ticket of the workspace, another
  # organisation's included; `:not_failed` for a comment not marked not posted.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, Repo, Sources, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Nodes.Node
  alias Apiary.Sources.{Comment, Topic}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  # The edition narrows a member's rights: no take in.
  defmodule NoTakeIn do
    @moduledoc false
    def check(_scope, :"work_item.take_in", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    set_comments(connection.adapter_id, true)
    %{scope: scope, connection: connection}
  end

  defp set_comments(adapter_id, comments),
    do: Repo.update_all(from(n in Node, where: n.id == ^adapter_id), set: [comments: comments])

  defp adapter(ctx), do: Repo.get!(Node, ctx.connection.adapter_id)

  # A comment taken in with a ticket, then marked as `state` with `failure`.
  defp comment(ctx, state \\ :not_posted, failure \\ :unreachable) do
    ticket = backlog_ticket_fixture(ctx.scope, connection: ctx.connection)
    {:ok, _work_item} = WorkItems.take_in(ctx.scope, ticket.public_id, %{comment: "Look here."})
    comment = Repo.get_by!(Comment, item_id: ticket.id)

    {ref, url} =
      if state == :posted,
        do: {"C-1", "https://tracker.example.com/comments/C-1"},
        else: {nil, nil}

    Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
      set: [post_state: state, post_failure: failure, external_ref: ref, url: url]
    )

    {ticket, Repo.get!(Comment, comment.id)}
  end

  test "writes a new entry, the same comment_id, and sets the comment posting", ctx do
    {ticket, comment} = comment(ctx)
    before = Feed.entries(adapter(ctx))
    Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(ctx.scope.workspace.id))
    Phoenix.PubSub.subscribe(Apiary.PubSub, WorkItems.topic(ctx.scope.workspace.id))

    assert {:ok, %Comment{} = again} = Sources.post_again(ctx.scope, comment.comment_id)
    assert {again.id, again.post_state, again.post_failure} == {comment.id, :posting, nil}
    assert Repo.get!(Comment, comment.id).post_state == :posting

    assert Feed.entries(adapter(ctx)) -- before == [
             %{
               seq: length(before) + 1,
               kind: "comment",
               data: %{
                 "comment_id" => comment.comment_id,
                 "ref" => ticket.external_ref,
                 "author_name" => comment.author_name,
                 "body" => "Look here."
               }
             }
           ]

    ticket_id = ticket.public_id
    assert_receive {:tickets_changed, [^ticket_id]}
    work_item_id = Repo.get_by!(WorkItem, external_ref: ticket.external_ref).public_id
    assert_receive {:work_items_changed, [^work_item_id]}

    # Posting now: not failed, and nothing more is written.
    assert Sources.post_again(ctx.scope, comment.comment_id) == {:error, :not_failed}
    assert length(Feed.entries(adapter(ctx))) == length(before) + 1
  end

  test "takes every reason, deleted at the source included", ctx do
    for failure <- [:item_gone, :not_permitted, :too_long, :unreachable, :deleted_at_source] do
      {_ticket, comment} = comment(ctx, :not_posted, failure)

      assert {:ok, %Comment{post_state: :posting}} =
               Sources.post_again(ctx.scope, comment.comment_id)
    end
  end

  test "keeps the comment in Qory Apiary, with no entry, where the source no longer takes comments",
       ctx do
    {_ticket, comment} = comment(ctx)
    set_comments(ctx.connection.adapter_id, false)
    before = Feed.entries(adapter(ctx))

    assert {:ok, %Comment{post_state: :kept, post_failure: nil}} =
             Sources.post_again(ctx.scope, comment.comment_id)

    assert Feed.entries(adapter(ctx)) == before
  end

  test "a comment not marked not posted is not failed, and nothing is written", ctx do
    for state <- [:posting, :posted, :kept] do
      {_ticket, comment} = comment(ctx, state, nil)
      before = Feed.entries(adapter(ctx))
      assert Sources.post_again(ctx.scope, comment.comment_id) == {:error, :not_failed}
      assert Repo.get!(Comment, comment.id).post_state == state
      assert Feed.entries(adapter(ctx)) == before
    end
  end

  test "a comment of no ticket of the workspace is not found", ctx do
    %{scope: other} = sign_up_fixture()
    other_connection = ticket_connection_fixture(other)
    {_ticket, elsewhere} = comment(%{scope: other, connection: other_connection})

    for id <- [elsewhere.comment_id, "sc_0000000000000000", "SC_0000000000000000", "", nil, 1] do
      assert Sources.post_again(ctx.scope, id) == {:error, :not_found}, inspect(id)
    end

    assert Repo.get!(Comment, elsewhere.id).post_state == :not_posted
  end

  test "a comment of another organisation is not found, and stays as it was", ctx do
    %{scope: other} = sign_up_fixture()
    refute other.organisation.id == ctx.scope.organisation.id
    other_connection = ticket_connection_fixture(other)
    set_comments(other_connection.adapter_id, true)
    {_ticket, elsewhere} = comment(%{scope: other, connection: other_connection})
    before = Feed.entries(Repo.get!(Node, other_connection.adapter_id))

    assert Sources.post_again(ctx.scope, elsewhere.comment_id) == {:error, :not_found}
    assert Repo.get!(Comment, elsewhere.id) == elsewhere
    assert Feed.entries(Repo.get!(Node, other_connection.adapter_id)) == before
  end

  test "a comment on a ticket of another workspace of the organisation is not found", ctx do
    workspace = workspace_fixture(ctx.scope.organisation)
    there = workspace_scope(ctx.scope.user, workspace)
    connection = ticket_connection_fixture(there)
    set_comments(connection.adapter_id, true)
    {_ticket, comment} = comment(%{scope: there, connection: connection})

    assert Sources.post_again(ctx.scope, comment.comment_id) == {:error, :not_found}
    assert {:ok, %Comment{post_state: :posting}} = Sources.post_again(there, comment.comment_id)
  end

  test "without take in in the workspace, forbidden, first", ctx do
    {_ticket, comment} = comment(ctx)
    Edition.put_test_stub(NoTakeIn)

    for id <- [comment.comment_id, "sc_0000000000000000"] do
      assert Sources.post_again(ctx.scope, id) == {:error, :forbidden}
    end

    assert Repo.get!(Comment, comment.id).post_state == :not_posted
  end
end
