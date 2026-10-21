defmodule Apiary.WorkItems.CommentsRacesTest do
  # People's comments on a work item's Thread, racing the same deletion, or a comment
  # beside a close of the same work item. Each side runs on a separate connection,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end; the adapter, which outlives
  # an organisation, by what it made.
  #
  # The rule under test (`Apiary.WorkItems.Moves`): a comment holds its work item
  # `FOR UPDATE` before it writes, and a deletion holds the work item, then the comment,
  # before it reads whether the comment is deleted, so a second side waits for the first,
  # then reads what the first left.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.WorkItemsFixtures

  alias Apiary.{Repo, WorkItems}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.WorkItems.{Comment, WorkItem}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  # Wide, so a slow machine fails no race by its clock: a side that never ends fails the
  # test only after this long.
  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{scope: scope} = sign_up()
    work_item = work_item_fixture(scope)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # organisation and its rows first, then the adapter.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from c in Connection, where: c.adapter_id == ^work_item.adapter_id)
      Repo.delete_all(from k in AccessKey, where: k.node_id == ^work_item.adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^work_item.adapter_id)
      Sandbox.checkin(Repo)
    end)

    %{scope: scope, work_item: work_item}
  end

  defp await(%{task: task}), do: Task.await(task, @await)

  defp entries(action, ctx),
    do:
      Repo.aggregate(
        from(e in Entry, where: e.action == ^action and e.subject_id == ^ctx.work_item.id),
        :count
      )

  test "two deletions of one comment: the second waits, then finds it deleted", ctx do
    {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "Wrong work item, sorry")
    delete = fn -> WorkItems.delete_comment(ctx.scope, comment.public_id) end

    {first, first_pid} = hold(delete)
    assert {:ok, %Comment{body: nil}} = first.result
    second = start(delete)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :deleted}
    assert entries("work_item.comment_delete", ctx) == 1
  end

  test "a comment beside a close: it waits, then is written on the closed work item", ctx do
    {closed, closed_pid} = hold(fn -> WorkItems.close(ctx.scope, ctx.work_item) end)
    assert {:ok, %WorkItem{state: :closed}} = closed.result
    commenting = start(fn -> WorkItems.comment(ctx.scope, ctx.work_item, "After the close") end)
    await_blocked(commenting.backend, closed_pid)
    commit(closed)

    assert {:ok, %Comment{body: "After the close"}} = await(commenting)
    assert %WorkItem{state: :closed} = Repo.get!(WorkItem, ctx.work_item.id)
    assert entries("work_item.comment", ctx) == 1
  end

  test "a deletion beside a comment on the same work item: it waits for the work item", ctx do
    {:ok, comment} = WorkItems.comment(ctx.scope, ctx.work_item, "First")

    {written, written_pid} =
      hold(fn -> WorkItems.comment(ctx.scope, ctx.work_item, "Second") end)

    assert {:ok, %Comment{}} = written.result
    deleting = start(fn -> WorkItems.delete_comment(ctx.scope, comment.public_id) end)
    await_blocked(deleting.backend, written_pid)
    commit(written)

    assert {:ok, %Comment{body: nil}} = await(deleting)
    assert WorkItems.count_comments(ctx.scope, ctx.work_item) == 1
  end
end
