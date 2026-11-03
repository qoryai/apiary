defmodule Apiary.Sources.TicketCloseRacesTest do
  # A post that closes a ticket (`Apiary.Sources.Ingest`) and so closes its work item,
  # racing a person's close and a take in again. Each side runs on a separate connection,
  # outside the SQL sandbox, so each commits and each waits on the other's locks as it
  # would in production. Not async: what these tests commit is visible to every other test
  # while they run, and they delete it again before they end.
  #
  # The rules under test: a post holds the ticket's connection and its item before the
  # work item, and a take in again holds that connection before the work item, so each
  # race ends with both sides answered and no deadlock; one close of a work item wins; a
  # take in again that waits on the post reads the ticket as closed; and the post holds
  # the connection `FOR NO KEY UPDATE`, so a claim that holds the work item's run and
  # then checks a foreign key to the connection does not wait on the post.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races
  import Apiary.SourcesFixtures

  alias Apiary.{Edition, Repo, Sources, WorkItems}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode, PublicKey}
  alias Apiary.Adapters.Connection
  alias Apiary.Audit.Entry
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag needs: :factory

  @await 60_000

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    started = database_now()
    %{scope: scope} = sign_up()
    tracker = tracker_fixture(scope)
    adapter_id = tracker.connection.adapter_id

    public_keys =
      Repo.all(from k in AccessKey, where: k.node_id == ^adapter_id, select: k.public_key)

    # Registered after the setup of `Apiary.Races`, so it runs before that one: the
    # organisation and its rows first, then the adapter, its key's public half and the
    # entries of the instance's organisation.
    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Organisation, where: o.id == ^scope.organisation.id)
      Repo.delete_all(from c in Connection, where: c.adapter_id == ^adapter_id)
      Repo.delete_all(from k in AccessKey, where: k.node_id == ^adapter_id)
      Repo.delete_all(from c in EnrolmentCode, where: c.node_id == ^adapter_id)
      Repo.delete_all(from n in Node, where: n.id == ^adapter_id)
      Repo.delete_all(from p in PublicKey, where: p.public_key in ^public_keys)

      Repo.delete_all(
        from e in Entry,
          where: e.organisation_id == ^Edition.instance_organisation_id(),
          where: e.inserted_at >= ^started
      )

      Sandbox.checkin(Repo)
    end)

    {:ok, :accepted} =
      Sources.post_items(tracker.key_scope, items_body("TRK", [item("R")]))

    ticket = Repo.get_by!(Item, collection_id: tracker.collection.id)
    {:ok, work_item} = WorkItems.take_in(scope, ticket.public_id)

    Map.merge(tracker, %{scope: scope, ticket: ticket, work_item: work_item})
  end

  defp closing(ctx) do
    updated_at = DateTime.add(at(), 60, :second)
    body = items_body("TRK", [item("R", state: "closed", updated_at: updated_at)])
    fn -> Sources.post_items(ctx.key_scope, body) end
  end

  defp close(ctx), do: fn -> WorkItems.close(ctx.scope, ctx.work_item) end
  defp take_in_again(ctx), do: fn -> WorkItems.take_in_again(ctx.scope, ctx.ticket.public_id) end
  defp await(%{task: task}), do: Task.await(task, @await)
  defp reloaded(ctx), do: Repo.get!(WorkItem, ctx.work_item.id)

  defp close_reason(ctx) do
    Repo.one!(
      from e in WorkItemEvent,
        where: e.work_item_id == ^ctx.work_item.id and e.kind == :closed,
        order_by: [desc: e.at],
        limit: 1,
        select: e.data["reason"]
    )
  end

  test "a post waits on a person's close, and leaves the work item as the person closed it",
       ctx do
    {first, first_pid} = hold(close(ctx))
    assert {:ok, %WorkItem{state: :closed}} = first.result

    second = start(closing(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:ok, :accepted}
    assert %WorkItem{state: :closed, closed_by_id: id} = reloaded(ctx)
    assert id == ctx.scope.user.id
    assert close_reason(ctx) == nil
  end

  test "a person's close waits on the post, and finds the work item closed", ctx do
    {first, first_pid} = hold(closing(ctx))
    assert first.result == {:ok, :accepted}

    second = start(close(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, _reason} = await(second)
    assert %WorkItem{state: :closed, closed_by_id: nil} = reloaded(ctx)
    assert close_reason(ctx) == "ticket_closed"
  end

  test "a take in again waits on the post, and reads the ticket as closed", ctx do
    {:ok, _closed} = close(ctx).()

    {first, first_pid} = hold(closing(ctx))
    assert first.result == {:ok, :accepted}

    second = start(take_in_again(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:error, :ticket_closed}
    assert %WorkItem{state: :closed, take_in: 1} = reloaded(ctx)
  end

  test "a claim that holds the run checks the connection's key while the post waits on the run",
       ctx do
    run_id =
      Repo.one!(
        from r in DispatchRun,
          where: r.work_item_id == ^ctx.work_item.id and r.state == :waiting,
          select: r.id
      )

    # The claim's two steps (`Apiary.Dispatches.waiting_query/1`, then the insert of the
    # run's credential entry, `Apiary.Runs.RunCredentials.insert!/2`): the run held, then
    # the foreign key check on the connection.
    {claim, claim_pid} =
      hold(fn ->
        Repo.one(
          from r in DispatchRun,
            where: r.id == ^run_id,
            lock: "FOR UPDATE SKIP LOCKED",
            select: r.id
        )
      end)

    assert claim.result == run_id

    post = start(closing(ctx))
    await_blocked(post.backend, claim_pid)

    checked =
      continue(claim, fn ->
        Repo.query(
          "SELECT 1 FROM adapter_connections WHERE id = $1 AND organisation_id = $2 FOR KEY SHARE",
          [
            Ecto.UUID.dump!(ctx.connection.id),
            Ecto.UUID.dump!(ctx.connection.organisation_id)
          ]
        )
      end)

    assert {:ok, %{num_rows: 1}} = checked
    commit(claim)

    assert await(post) == {:ok, :accepted}
    assert %WorkItem{state: :closed, closed_by_id: nil} = reloaded(ctx)
  end

  test "a post waits on a take in again, then closes the work item it brought back", ctx do
    {:ok, _closed} = close(ctx).()

    {first, first_pid} = hold(take_in_again(ctx))
    assert {:ok, %WorkItem{state: :exploring, take_in: 2}} = first.result

    second = start(closing(ctx))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert await(second) == {:ok, :accepted}
    assert %WorkItem{state: :closed, take_in: 2, closed_by_id: nil} = reloaded(ctx)
    assert close_reason(ctx) == "ticket_closed"
  end
end
