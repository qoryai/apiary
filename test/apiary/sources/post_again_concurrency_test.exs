defmodule Apiary.Sources.PostAgainConcurrencyTest do
  # Two posts again of one comment at once (`Apiary.Sources.post_again/2`), on real
  # transactions and real connections: the sandbox would run them one after the other on
  # one connection and prove nothing. A third transaction locks the adapter's feed
  # counter until both have read the comment `:not_posted` and wait for the counter, so
  # both reach the update. What the test commits goes with its organisation, its adapter
  # and its user when it ends.
  use ExUnit.Case, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Ecto.Query

  alias Apiary.{Repo, Sources, WorkItems}
  alias Apiary.Adapters.Feed
  alias Apiary.Nodes.Node
  alias Apiary.Sources.Comment
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
  end

  test "two at once write one entry: one posts the comment again, the other is not failed" do
    %{scope: scope, user: user} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.delete_all(
        from o in Apiary.Organisations.Organisation, where: o.id == ^scope.organisation.id
      )

      Repo.delete_all(from n in Node, where: n.id == ^connection.adapter_id)
      Repo.delete_all(from u in Apiary.Accounts.User, where: u.id == ^user.id)
      Sandbox.mode(Repo, :manual)
    end)

    Repo.update_all(from(n in Node, where: n.id == ^connection.adapter_id), set: [comments: true])
    ticket = backlog_ticket_fixture(scope, connection: connection)
    {:ok, _work_item} = WorkItems.take_in(scope, ticket.public_id, %{comment: "Look here."})
    comment = Repo.get_by!(Comment, item_id: ticket.id)

    Repo.update_all(from(c in Comment, where: c.id == ^comment.id),
      set: [post_state: :not_posted, post_failure: :unreachable]
    )

    adapter = Repo.get!(Node, connection.adapter_id)
    before = Feed.entries(adapter)
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT 1 FROM adapter_feed_counters WHERE adapter_id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(adapter.id)]
          )

          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(test_pid, {:holding, pid})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holding, holder_pid}, 5_000

    posts =
      for _n <- 1..2,
          do: Task.async(fn -> Sources.post_again(scope, comment.comment_id) end)

    # Both have read the comment and wait for the counter.
    wait_for_waiting(holder_pid, 2)
    send(holder.pid, :release)
    Task.await(holder)

    results = Enum.map(posts, &Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, %Comment{post_state: :posting}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_failed})) == 1

    assert [%{kind: "comment", data: %{"comment_id" => id}}] = Feed.entries(adapter) -- before
    assert id == comment.comment_id

    assert %Comment{post_state: :posting, post_failure: nil} = Repo.get!(Comment, comment.id)
  end

  # Waits until `count` backends wait for the lock of the backend `pid`: behind it, or
  # behind a backend that waits behind it, as a second waiter for one row does.
  defp wait_for_waiting(pid, count, tries \\ 500) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_stat_activity a
        WHERE $1 = ANY(pg_blocking_pids(a.pid))
           OR EXISTS (
             SELECT 1 FROM pg_stat_activity b
             WHERE $1 = ANY(pg_blocking_pids(b.pid)) AND b.pid = ANY(pg_blocking_pids(a.pid))
           )
        """,
        [pid]
      )

    cond do
      waiting >= count -> :ok
      tries == 0 -> flunk("#{waiting} of #{count} posts again wait for the feed counter")
      true -> wait_again(pid, count, tries)
    end
  end

  defp wait_again(pid, count, tries) do
    Process.sleep(10)
    wait_for_waiting(pid, count, tries - 1)
  end
end
