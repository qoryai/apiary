defmodule Apiary.WorkItems.Moves do
  # Moves holds what a person does to a workspace's work items, each in one transaction
  # with its event, its run of the queue, its feed entry and its entry in the audit trail:
  # taking a ticket in, taking it in again, undoing a take in, declining and closing; what
  # a member gives Explore: answering a run's questions, confirming a run's proposal,
  # changed or not, and running Explore again; and people's comments on the Thread,
  # writing one and deleting one.
  # `Apiary.WorkItems` names each function and what it answers; this module says how.
  #
  # ## Who may
  #
  # Each asks `Apiary.Access.authorize/3` first, inside its transaction: a take in and a
  # take in again `work_item.take_in` of the scope's workspace, where the work item will
  # be; an undo, a decline and a close `work_item.undo`, `work_item.decline` and
  # `work_item.close` of the work item, which must be in the scope's workspace; an answer,
  # a confirmation and a run of Explore again `work_item.answer`, `work_item.confirm` and
  # `work_item.explore_again` of the work item, likewise; a comment `work_item.comment` of
  # the work item, and a comment's deletion `work_item.comment_delete` of the comment, which
  # its author may take too while they may still comment (`Apiary.Access`). Each
  # writes its entry in the trail with the change (`Apiary.Audit.record/6`), about the work
  # item: a take in again with `details` `again: true`.
  #
  # ## What a take in reads
  #
  # The ticket is named by the id Qory Apiary gives its record (`tk_…`). It is taken in
  # only while it is in the Backlog of the scope's workspace: its connection connected,
  # its collection live and assigned to that workspace, the record not disconnected; else
  # `:not_found`. A collection assigned there that is not linked, its Backlog switch off or
  # with no items, it or its adapter (`Apiary.Adapters.Collection.linked?/1`), is
  # `:not_linked`. A ticket closed at its source is `:ticket_closed`. The work item's
  # target is the ticket's target, else its collection's, as the workspace's domain checks
  # it (`Apiary.Lingo.Domain.check_target/2`): with neither, `:no_target` where the domain
  # needs a target, else a work item without one; one that breaks the domain's rules,
  # `:target_invalid`. Its owner is the person the page names, the one taking it in
  # unless named, who must act in the workspace
  # (`Apiary.Organisations.list_workspace_members/1`), else `:owner`.
  # The page gives the owner and the first instruction under atom keys or their strings.
  # Its first instruction is the one the page gives, empty for none, within the bounds of
  # `Apiary.WorkItems.WorkItem.take_in_changeset/2`, else the changeset.
  #
  # ## The order of the locks
  #
  # Every move takes its locks in the order the core keeps for everything that holds more
  # than one of them (`Apiary.Adapters.Collections` names it in full): the ticket's
  # connection `FOR SHARE`, so no listing's part, item or end of it runs meanwhile; the
  # ticket's collection `FOR SHARE`, so no assign, move, Backlog switch or end changes its
  # link meanwhile, its adapter's `items` read after it; then the work item `FOR UPDATE`;
  # then, only right after the work item, the workspace's counter of numbers
  # (`Apiary.WorkItems.Number`), for a new work item or one that moves; then the runs of
  # the queue (`Apiary.Dispatches`); then the adapter's feed counter, last
  # (`Apiary.Adapters.Feed`). An undo, a decline and a close take no connection or
  # collection: the work item, then its runs. An answer, a confirmation and a run of
  # Explore again take the work item alone, then queue through
  # `Apiary.Dispatches.queue_next/2`, which takes the work item again, in the same
  # transaction, before it reads the runs; they lock no run, as a run that ended stays
  # ended and a new run is only written under the work item's lock. A comment takes the
  # work item alone; a comment's deletion the work item, then the comment, `FOR UPDATE`,
  # right after it. No workspace row is locked: an assign holds
  # its workspace `FOR SHARE` before the collections, and a move must never wait on it
  # holding a collection. No collection or target is locked after a work item.
  #
  # ## Take in
  #
  # A first take in finds no work item of the ticket in the organisation, by its adapter
  # and its ref, live or not. It makes one, `:exploring`, numbered next in the workspace,
  # take in 1, taken in by the person now, with its `:taken_in` event (`data`
  # `{"take_in": 1, "before": null}`), queues its first run (`Apiary.Dispatches.queue/2`),
  # and tells the adapter `taken_in` (`Apiary.Adapters.Feed`). A work item of the ticket
  # that exists, in any workspace and any state, is `{:error, {:taken, work_item}}`; so is
  # a take in that loses the race to another: the unique index on (`organisation_id`,
  # `adapter_id`, `external_ref`) refuses the second, which rolls back, and the winner is
  # read once it has. The work item comes as the person sees it
  # (`Apiary.WorkItems.as_seen/2`): one of another workspace by its state alone, as the
  # Backlog shows it; a take in again's `{:taken, work_item}` too.
  #
  # ## Take in a test
  #
  # A take in of a test (`take_in_test/2`) is asked as a take in is, `work_item.take_in` of
  # the scope's workspace, and reads no ticket, connection, collection or target. It makes
  # a test work item of the line the person typed
  # (`Apiary.WorkItems.WorkItem.test_changeset/2`), `:exploring`, owned by the person,
  # numbered next in the workspace, take in 1, with its `:taken_in` event, as a first take
  # in has, its first run queued (`Apiary.Dispatches.queue/2`), and its entry in the trail,
  # `details` `test: true`. No adapter is told, as none is behind it. A line the changeset
  # refuses is the changeset.
  #
  # A workspace has one live test work item at most, and a run's end leaves it live. So a
  # take in of a test first holds the live one, if there is one, `FOR UPDATE`, then its
  # runs `FOR UPDATE`, by id: while one of them is claimed or is handed over, a machine
  # holds it, and it is `:test_running`; otherwise it closes that one, as the person,
  # through the one close (`Apiary.WorkItems.close_locked/3`), which ends the runs that
  # still wait (`end_cause: :closed`), with its entry in the trail, as a close writes it,
  # then makes the new one: a test whose run no machine took is tried again at once. A
  # take in of a test that commits meanwhile is refused by the index on live test work
  # items, `:test_running` too. It locks the workspace's counter of numbers right after
  # the new work item, then the runs of the queue. An undo, a decline and a close work on
  # a test work item as on any other, and tell no adapter and no Backlog, as it has no
  # ticket.
  #
  # ## Take in again
  #
  # A take in again finds the work item of the ticket by that key: none is `:not_taken`,
  # a live one `{:error, {:taken, work_item}}`. An ended one, declined, closed or undone,
  # becomes `:exploring` again, its take in counted one more, pointed at the ticket's
  # current record and its connection, with the ticket's title and address and its
  # collection's title as they are now, and the target, the owner, the first instruction,
  # who took it in and when of this take in. A work item of another workspace moves to the
  # scope's, numbered next there; its old number is never given again, and its runs stay
  # in the workspace they were queued in. Its `:taken_in` event keeps how it had ended,
  # `before` (its state, when and by whom it ended, who had taken it in and when, its
  # owner and its target), for an undo. Its first run is queued, run 1 of the new count.
  # The adapter is told `taken_in` only for one that had ended undone, whose label came
  # off; a declined or closed one kept its label, and nothing is sent.
  #
  # ## Undo
  #
  # An undo works on a live work item while no claim holds a run of its take in
  # (`Apiary.Dispatches.cancel_for_undo/1`, `{:error, :claimed}` otherwise), and ends its
  # waiting runs. A first take in becomes `:undone`, and the adapter is told `undone`. A
  # take in again goes back to how it had ended, from its event's `before`: declined or
  # closed with when and by whom, and its owner, its target and who had taken it in, and
  # nothing is sent, as the label stayed; one that had ended undone becomes `:undone`
  # again, and the adapter is told `undone`, as its take in again put the label back on.
  # A work item moved by its take in again stays in the workspace it moved to, with its
  # new number. The first instruction stays the one of the take in undone: it is given to
  # no run until a take in again gives a new one.
  #
  # ## Decline and close
  #
  # A decline works on a live work item none of whose runs of its take in waits, is
  # claimed or is handed over, else `:running`, and whose take in is not confirmed, else
  # `:confirmed`: a decline is offered where Explore waits for a member, and a confirmed
  # work item waits for Shape. It becomes `:declined`, by the person, now, with its
  # event, which records the stage Explore was at (`"stage"`, `"explore"` or `"confirm"`,
  # `Apiary.WorkItems.Explore.stage/1`), and nothing is sent, as the label stays. A close
  # works on a live work item, whatever its runs (`Apiary.WorkItems.close_locked/3`),
  # and its event records the stage too, `"shape"` once confirmed.
  #
  # ## What a member gives Explore
  #
  # Each works on a live work item whose take in is still the one the page read
  # (`take_in` of the work item it is given), and on the latest run of that take in, by
  # its `attempt`, which the page names: another take in or another latest run is
  # `:stale`. Where Explore stands is read under the work item's lock
  # (`Apiary.WorkItems.Explore.current/2`): a run not ended, or one that reads as running,
  # is `:running`; at the run limit, `:used_up`; anywhere else than the step's place,
  # `:not_waiting`. Each writes its event and its entry in the trail, and marks the work
  # item changed (`updated_at`); none sends a feed entry, as the label stays.
  #
  #   * An answer (`answer/4`) works where the latest run asked its questions: every
  #     question answered (`Apiary.WorkItems.Proposal.check_answers/2`, else
  #     `{:invalid, errors}`, by position, or `{:invalid, :form}`). It keeps each answer
  #     with its question (`Apiary.WorkItems.Answer`), and queues the take in's next run
  #     (`Apiary.Dispatches.queue_next/2`), which reads them
  #     (`Apiary.WorkItems.take_in_answers/2`). Its event, `:answered`, has the take in,
  #     the attempt answered and the count.
  #   * A confirmation (`confirm/4`) works where the latest run's proposal waits: as it
  #     stands, or with the changes the edit page gives
  #     (`Apiary.WorkItems.Proposal.changes/2`, else `{:invalid, errors}` by field, or
  #     `{:invalid, :form}`). It keeps the run's result and the changes
  #     (`Apiary.WorkItems.Confirmation`); the work item is then ready for Shape. Its
  #     event, `:confirmed`, has the take in, the attempt and the fields changed.
  #   * A run of Explore again (`explore_again/3`) works after a run that gave no result,
  #     was lost or was cancelled, while a run is left: it queues the take in's next run.
  #     Its event, `:explore_again`, has the take in and the attempt of the new run.
  #
  # ## People's comments
  #
  # A comment (`comment/3`) is written on a work item in any state, live or ended, by the
  # scope's person, now, with its body as `Apiary.WorkItems.Comment.changeset/2` holds it,
  # else the changeset. It marks the work item changed (`updated_at`). Its entry in the
  # trail names the comment by its public id (`details` `comment_id`), never its text.
  #
  # A comment's deletion (`delete_comment/2`) names the comment by its public id (`cm_…`),
  # of the scope's workspace, whatever the state of its work item; else `:not_found`. One
  # already deleted is `:deleted`. Its body goes, and it keeps who deleted it and when, so
  # the Thread keeps a line in its place. The work item is not marked changed. Its entry
  # names the comment and its author (`details` `comment_id`, `author_id`).
  #
  # Neither writes an event of the work item or a feed entry: the comment is a line of the
  # Thread by itself.
  #
  # ## What is told
  #
  # Once the transaction commits, each workspace whose Backlog shows the ticket is sent
  # `{:tickets_changed, ids}` on the Backlog's topic (`Apiary.Sources.Topic`), and the
  # workspace the work item is in, and the one it moved from, `{:work_items_changed, ids}`
  # on its work items' topic (`Apiary.WorkItems.topic/1`): public ids only. A close also
  # tells the workspaces whose queue changed (`Apiary.Dispatches.broadcast/1`). A comment
  # and its deletion tell the work items' topic alone: the Backlog shows no comment.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Dispatches, Organisations, PublicId, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection, Feed}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.{Item, Topic}
  alias Apiary.WorkItems.{Answer, Comment, Confirmation, Explore, Number, Proposal, State}
  alias Apiary.WorkItems.WorkItem
  alias Apiary.WorkItems.WorkItemEvent

  @typedoc "Why a take in, or a take in again, is refused."
  @type take_in_refusal ::
          :not_found
          | :forbidden
          | :not_linked
          | :ticket_closed
          | :no_target
          | :target_invalid
          | :owner
          | :not_taken
          | {:taken, WorkItem.t()}
          | Ecto.Changeset.t()

  @typedoc """
  What the page gives a take in: the owner, and the first instruction, under atom keys or
  their strings.
  """
  @type take_in_attrs :: %{
          optional(:owner_id | String.t()) => Ecto.UUID.t(),
          optional(:first_instruction | String.t()) => String.t()
        }

  ## Take in

  @doc false
  @spec take_in(Scope.t(), String.t(), take_in_attrs) ::
          {:ok, WorkItem.t()} | {:error, take_in_refusal}
  def take_in(%Scope{} = scope, item_id, attrs) when is_map(attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, workspace} <- workspace(scope),
             :ok <- Access.authorize(scope, :"work_item.take_in", workspace),
             {:ok, ticket} <- hold_ticket(scope, workspace, item_id),
             :ok <- none_yet(scope, ticket),
             :ok <- open(ticket),
             {:ok, target} <- target(workspace, ticket),
             {:ok, owner_id} <- owner(scope, attrs) do
          make(scope, workspace, ticket, target, owner_id, attrs)
        end
      end)

    case result do
      {:ok, {work_item, told}} ->
        tell(told)
        {:ok, work_item}

      {:error, {:raced, ticket}} ->
        {:error, {:taken, WorkItems.as_seen(scope, by_key(ticket, false))}}

      {:error, _refusal} = refused ->
        refused
    end
  end

  # A new work item of the ticket, its event, its first run, its feed entry and its entry
  # in the trail.
  defp make(scope, workspace, ticket, target, owner_id, attrs) do
    %{item: item, collection: collection, adapter: adapter} = ticket
    now = DateTime.utc_now()

    changeset =
      %WorkItem{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        state: :exploring,
        taken_in_by_id: scope.user.id,
        taken_in_at: now
      }
      |> WorkItem.take_in_changeset(%{
        connection_id: collection.connection_id,
        adapter_id: collection.adapter_id,
        item_id: item.id,
        external_ref: item.external_ref,
        url: item.url,
        title: item.title,
        collection_title: collection.title,
        target_system: target && target.system,
        target_path: target && target.path,
        owner_id: owner_id,
        first_instruction: instruction(attrs)
      })

    with {:ok, changeset} <- valid(changeset),
         {:ok, work_item} <- insert(changeset, workspace, ticket),
         :ok <- event(work_item, :taken_in, scope, now, %{"take_in" => 1, "before" => nil}),
         {:ok, _run} <- Dispatches.queue(work_item, 1),
         {:ok, _seq} <- feed(adapter, work_item, "taken_in"),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             after: %{state: :exploring},
             details: %{"take_in" => 1}
           }) do
      {:ok,
       {work_item,
        %{
          work_items: [{work_item.workspace_id, work_item.public_id}],
          tickets: [{collection.workspace_id, item.public_id}]
        }}}
    end
  end

  # The number is taken once the changeset holds, right after the work item it numbers:
  # one refused gives none back, as none was taken.
  defp insert(changeset, workspace, ticket) do
    changeset
    |> Ecto.Changeset.put_change(:number, Number.next(workspace))
    |> PublicId.Insert.insert()
    |> case do
      {:ok, work_item} ->
        {:ok, work_item}

      {:error, %Ecto.Changeset{errors: errors} = refused} ->
        case errors[:external_ref] do
          {_message, opts} when is_list(opts) ->
            if opts[:constraint] == :unique,
              do: {:error, {:raced, ticket}},
              else: {:error, refused}

          nil ->
            {:error, refused}
        end
    end
  end

  ## Take in a test

  @doc false
  @spec take_in_test(Scope.t(), term) ::
          {:ok, WorkItem.t()}
          | {:error, :not_found | :forbidden | :test_running | Ecto.Changeset.t()}
  def take_in_test(%Scope{} = scope, line) do
    result =
      Repo.transact(fn ->
        with {:ok, workspace} <- workspace(scope),
             :ok <- Access.authorize(scope, :"work_item.take_in", workspace),
             {:ok, closed} <- close_last_test(scope, workspace),
             {:ok, {work_item, told}} <- make_test(scope, workspace, line) do
          {:ok, {work_item, with_closed(told, closed)}}
        end
      end)

    finish(result)
  end

  # A new test work item of the line, its event, its first run and its entry in the trail.
  defp make_test(scope, workspace, line) do
    now = DateTime.utc_now()

    changeset =
      %WorkItem{
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        state: :exploring,
        taken_in_by_id: scope.user.id,
        taken_in_at: now
      }
      |> WorkItem.test_changeset(%{title: line, owner_id: scope.user.id})

    with {:ok, changeset} <- valid(changeset),
         {:ok, work_item} <- insert_test(changeset, workspace),
         :ok <- event(work_item, :taken_in, scope, now, %{"take_in" => 1, "before" => nil}),
         {:ok, _run} <- Dispatches.queue(work_item, 1),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             after: %{state: :exploring},
             details: %{"take_in" => 1, "test" => true}
           }) do
      {:ok,
       {work_item, %{work_items: [{work_item.workspace_id, work_item.public_id}], tickets: []}}}
    end
  end

  # The workspace's live test work item, held `FOR UPDATE`, closed by the person once no
  # machine holds a run of it, which ends the runs that still wait (`end_cause: :closed`,
  # `WorkItems.close_locked/3`): `{:ok, {closed, workspace_ids}}`, the workspaces whose
  # queue changed, or `{:ok, nil}` for none; `:test_running` while a run of it is claimed
  # or handed over.
  defp close_last_test(scope, %Workspace{id: workspace_id, organisation_id: organisation_id}) do
    live =
      Repo.one(
        from w in WorkItem,
          where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id,
          where: w.test and w.state == :exploring,
          lock: "FOR UPDATE"
      )

    case live do
      nil ->
        {:ok, nil}

      %WorkItem{} = held ->
        with :ok <- test_ended(held),
             :ok <- Access.authorize(scope, :"work_item.close", held),
             {:ok, workspace_ids} <-
               WorkItems.close_locked([held], {:person, scope.user.id}, DateTime.utc_now()),
             closed = Repo.get!(WorkItem, held.id),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.close", closed, %{
                 before: %{state: held.state},
                 after: %{state: closed.state}
               }) do
          {:ok, {closed, workspace_ids}}
        end
    end
  end

  # No run of the test work item's take in is claimed or handed over. Its runs that wait,
  # are claimed or are handed over are held `FOR UPDATE`, by id, as `no_run/1` holds them,
  # and their state is read under that lock: a claim that took one first is seen claimed,
  # and a claim after skips the held ones (`FOR UPDATE SKIP LOCKED`), then finds them
  # ended by the close.
  defp test_ended(%WorkItem{id: id, take_in: take_in}) do
    states =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^id and r.take_in == ^take_in,
          where: fragment("? IN ('waiting', 'claimed', 'handed_over')", r.state),
          order_by: r.id,
          lock: "FOR UPDATE",
          select: r.state
      )

    if Enum.all?(states, &(&1 == :waiting)), do: :ok, else: {:error, :test_running}
  end

  defp with_closed(told, nil), do: told

  defp with_closed(told, {closed, workspace_ids}) do
    told
    |> Map.update!(:work_items, &[{closed.workspace_id, closed.public_id} | &1])
    |> Map.put(:queues, workspace_ids)
  end

  # The number is taken once the changeset holds, as for a first take in.
  defp insert_test(changeset, workspace) do
    changeset
    |> Ecto.Changeset.put_change(:number, Number.next(workspace))
    |> PublicId.Insert.insert()
    |> case do
      {:ok, work_item} ->
        {:ok, work_item}

      {:error, %Ecto.Changeset{errors: errors} = refused} ->
        case errors[:test] do
          {_message, opts} when is_list(opts) ->
            if opts[:constraint] == :unique,
              do: {:error, :test_running},
              else: {:error, refused}

          nil ->
            {:error, refused}
        end
    end
  end

  ## Take in again

  @doc false
  @spec take_in_again(Scope.t(), String.t(), take_in_attrs) ::
          {:ok, WorkItem.t()} | {:error, take_in_refusal}
  def take_in_again(%Scope{} = scope, item_id, attrs) when is_map(attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, workspace} <- workspace(scope),
             :ok <- Access.authorize(scope, :"work_item.take_in", workspace),
             {:ok, ticket} <- hold_ticket(scope, workspace, item_id),
             {:ok, ended} <- ended(scope, ticket),
             :ok <- open(ticket),
             {:ok, target} <- target(workspace, ticket),
             {:ok, owner_id} <- owner(scope, attrs) do
          again(scope, workspace, ended, ticket, target, owner_id, attrs)
        end
      end)

    case result do
      {:ok, {work_item, told}} ->
        tell(told)
        {:ok, work_item}

      {:error, _refusal} = refused ->
        refused
    end
  end

  # The ended work item of the ticket, held `FOR UPDATE`: `:not_taken` for none, and
  # `{:taken, work_item}` for a live one, as the person sees it (`Apiary.WorkItems.as_seen/2`).
  defp ended(scope, ticket) do
    case by_key(ticket, true) do
      nil ->
        {:error, :not_taken}

      %WorkItem{state: state} = work_item ->
        if State.next(state, :take_in_again) == {:ok, :exploring},
          do: {:ok, work_item},
          else: {:error, {:taken, WorkItems.as_seen(scope, work_item)}}
    end
  end

  defp again(scope, workspace, ended, ticket, target, owner_id, attrs) do
    %{item: item, collection: collection, adapter: adapter} = ticket
    now = DateTime.utc_now()
    take_in = ended.take_in + 1

    changeset =
      ended
      |> WorkItem.take_in_again_changeset(%{
        connection_id: collection.connection_id,
        item_id: item.id,
        url: item.url,
        title: item.title,
        collection_title: collection.title,
        target_system: target && target.system,
        target_path: target && target.path,
        owner_id: owner_id,
        first_instruction: instruction(attrs)
      })
      |> Ecto.Changeset.change(
        state: :exploring,
        declined_at: nil,
        declined_by_id: nil,
        closed_at: nil,
        closed_by_id: nil,
        taken_in_by_id: scope.user.id,
        taken_in_at: now
      )

    with {:ok, changeset} <- valid(changeset),
         {:ok, work_item} <- changeset |> move(ended, workspace) |> Repo.update(),
         :ok <-
           event(work_item, :taken_in, scope, now, %{
             "take_in" => take_in,
             "before" => before(ended)
           }),
         {:ok, _run} <- Dispatches.queue(work_item, take_in),
         {:ok, _seq} <- feed_if(ended.state == :undone, adapter, work_item, "taken_in"),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             before: %{state: ended.state},
             after: %{state: :exploring},
             details: %{"again" => true, "take_in" => take_in}
           }) do
      {:ok,
       {work_item,
        %{
          work_items:
            Enum.uniq([
              {work_item.workspace_id, work_item.public_id},
              {ended.workspace_id, work_item.public_id}
            ]),
          tickets: [{collection.workspace_id, item.public_id}]
        }}}
    end
  end

  # A work item of another workspace moves to the scope's, numbered next there, right
  # after the work item is held.
  defp move(changeset, %WorkItem{workspace_id: workspace_id}, %Workspace{id: workspace_id}),
    do: changeset

  defp move(changeset, _ended, %Workspace{} = workspace),
    do:
      Ecto.Changeset.change(changeset, workspace_id: workspace.id, number: Number.next(workspace))

  # How `work_item` had ended, for the undo of the take in again that leaves it.
  defp before(%WorkItem{} = work_item) do
    {at, by_id} =
      case work_item.state do
        :declined -> {work_item.declined_at, work_item.declined_by_id}
        :closed -> {work_item.closed_at, work_item.closed_by_id}
        :undone -> {nil, nil}
      end

    %{
      "state" => Atom.to_string(work_item.state),
      "at" => at && DateTime.to_iso8601(at),
      "by_id" => by_id,
      "taken_in_by_id" => work_item.taken_in_by_id,
      "taken_in_at" => DateTime.to_iso8601(work_item.taken_in_at),
      "owner_id" => work_item.owner_id,
      "target_system" => work_item.target_system,
      "target_path" => work_item.target_path
    }
  end

  ## Undo

  @doc false
  @spec undo(Scope.t(), WorkItem.t()) ::
          {:ok, WorkItem.t()} | {:error, :not_found | :forbidden | :not_live | :claimed}
  def undo(%Scope{} = scope, %WorkItem{} = work_item) do
    result =
      Repo.transact(fn ->
        with {:ok, held} <- hold(scope, :"work_item.undo", work_item),
             :ok <- live(held),
             :ok <- Dispatches.cancel_for_undo(held) do
          undone(scope, held)
        end
      end)

    finish(result)
  end

  defp undone(scope, held) do
    now = DateTime.utc_now()
    before = before_of(held)
    {:ok, state} = State.next(:exploring, :undo, before && before.state)

    changes =
      case before do
        %{state: ended} when ended in [:declined, :closed] ->
          [state: state] ++ ended_fields(ended, before) ++ taken_in_fields(before)

        %{state: :undone} ->
          [state: state] ++ taken_in_fields(before)

        nil ->
          [state: state]
      end

    # A test work item has no adapter to tell.
    tell_undone? = not held.test and (is_nil(before) or before.state == :undone)

    with {:ok, work_item} <- held |> Ecto.Changeset.change(changes) |> Repo.update(),
         :ok <- event(work_item, :undone, scope, now, %{"take_in" => work_item.take_in}),
         {:ok, _seq} <- feed_if(tell_undone?, work_item, "undone"),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.undo", work_item, %{
             before: %{state: :exploring},
             after: %{state: state},
             details: %{"take_in" => work_item.take_in}
           }) do
      {:ok, {work_item, told(work_item)}}
    end
  end

  # How the latest take in of `work_item` found it, from its `:taken_in` event: nil for a
  # first take in.
  defp before_of(%WorkItem{id: id, take_in: take_in}) do
    data =
      Repo.one(
        from e in WorkItemEvent,
          where: e.work_item_id == ^id and e.kind == :taken_in,
          where: fragment("?->>'take_in' = ?", e.data, ^Integer.to_string(take_in)),
          order_by: [desc: e.at, desc: e.id],
          limit: 1,
          select: e.data
      )

    case data do
      %{"before" => %{"state" => state} = before}
      when state in ["declined", "closed", "undone"] ->
        %{
          state: String.to_existing_atom(state),
          at: time(before["at"]),
          by_id: before["by_id"],
          taken_in_by_id: before["taken_in_by_id"],
          taken_in_at: time(before["taken_in_at"]),
          owner_id: before["owner_id"],
          target_system: before["target_system"],
          target_path: before["target_path"]
        }

      _first ->
        nil
    end
  end

  defp time(nil), do: nil

  defp time(text) when is_binary(text) do
    {:ok, at} = Ecto.Type.cast(:utc_datetime_usec, text)
    at
  end

  defp ended_fields(:declined, before), do: [declined_at: before.at, declined_by_id: before.by_id]
  defp ended_fields(:closed, before), do: [closed_at: before.at, closed_by_id: before.by_id]

  defp taken_in_fields(before) do
    [
      taken_in_by_id: before.taken_in_by_id,
      taken_in_at: before.taken_in_at,
      owner_id: before.owner_id,
      target_system: before.target_system,
      target_path: before.target_path
    ]
  end

  ## Decline

  @doc false
  @spec decline(Scope.t(), WorkItem.t()) ::
          {:ok, WorkItem.t()}
          | {:error, :not_found | :forbidden | :not_live | :running | :confirmed}
  def decline(%Scope{} = scope, %WorkItem{} = work_item) do
    result =
      Repo.transact(fn ->
        with {:ok, held} <- hold(scope, :"work_item.decline", work_item),
             :ok <- live(held),
             :ok <- no_run(held),
             {:ok, stage} <- not_confirmed(held) do
          declined(scope, held, stage)
        end
      end)

    finish(result)
  end

  # No run of the work item's take in waits, is claimed or is handed over: those there
  # are held `FOR UPDATE`, by id, as a close holds them, so a claim that took one first is
  # seen claimed.
  defp no_run(%WorkItem{id: id, take_in: take_in}) do
    running =
      Repo.all(
        from r in DispatchRun,
          where: r.work_item_id == ^id and r.take_in == ^take_in,
          where: fragment("? IN ('waiting', 'claimed', 'handed_over')", r.state),
          order_by: r.id,
          lock: "FOR UPDATE",
          select: r.id
      )

    if running == [], do: :ok, else: {:error, :running}
  end

  # The stage Explore is at, unless the take in is confirmed.
  defp not_confirmed(held) do
    case Explore.current(held, DateTime.utc_now()).status do
      :shape -> {:error, :confirmed}
      status -> {:ok, Explore.stage(status)}
    end
  end

  defp declined(scope, held, stage) do
    now = DateTime.utc_now()
    {:ok, state} = State.next(held.state, :decline)

    with {:ok, work_item} <-
           held
           |> Ecto.Changeset.change(state: state, declined_at: now, declined_by_id: scope.user.id)
           |> Repo.update(),
         :ok <- event(work_item, :declined, scope, now, %{"stage" => Atom.to_string(stage)}),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.decline", work_item, %{
             before: %{state: :exploring},
             after: %{state: state}
           }) do
      {:ok, {work_item, told(work_item)}}
    end
  end

  ## Close

  @doc false
  @spec close(Scope.t(), WorkItem.t()) ::
          {:ok, WorkItem.t()} | {:error, :not_found | :forbidden | :not_live}
  def close(%Scope{} = scope, %WorkItem{} = work_item) do
    result =
      Repo.transact(fn ->
        with {:ok, held} <- hold(scope, :"work_item.close", work_item),
             {:ok, workspace_ids} <-
               WorkItems.close_locked([held], {:person, scope.user.id}, DateTime.utc_now()),
             closed = Repo.get!(WorkItem, held.id),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.close", closed, %{
                 before: %{state: held.state},
                 after: %{state: closed.state}
               }) do
          {:ok, {closed, Map.put(told(closed), :queues, workspace_ids)}}
        end
      end)

    finish(result)
  end

  ## What a member gives Explore

  @typedoc "Why an answer, a confirmation or a run of Explore again is refused."
  @type step_refusal ::
          :not_found
          | :forbidden
          | :not_live
          | :stale
          | :running
          | :used_up
          | :not_waiting
          | {:invalid, map | :form}
          | Ecto.Changeset.t()

  @doc false
  @spec answer(Scope.t(), WorkItem.t(), pos_integer, map) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def answer(%Scope{} = scope, %WorkItem{} = work_item, attempt, answers) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held, current} <- hold_step(scope, :"work_item.answer", work_item, now),
             :ok <- waiting(current, [:questions], attempt),
             {:ok, checked} <-
               invalid(Proposal.check_answers(Proposal.questions(current.step.result), answers)),
             :ok <- keep_answers(held, scope, attempt, checked, now),
             data = %{"take_in" => held.take_in, "attempt" => attempt, "count" => length(checked)},
             :ok <- event(held, :answered, scope, now, data),
             {:ok, _run} <- next_run(held),
             {:ok, work_item} <- touch(held, now),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.answer", work_item, %{details: data}) do
          {:ok, {work_item, told(work_item)}}
        end
      end)

    finish(result)
  end

  @doc false
  @spec confirm(Scope.t(), WorkItem.t(), pos_integer, map | nil) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def confirm(%Scope{} = scope, %WorkItem{} = work_item, attempt, params) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held, current} <- hold_step(scope, :"work_item.confirm", work_item, now),
             :ok <- waiting(current, [:confirm], attempt),
             {:ok, changes} <- proposal_changes(current.step, params),
             :ok <- keep_confirmation(held, scope, current.step, changes, now),
             changed = changes |> Proposal.encode() |> Map.keys() |> Enum.sort(),
             data = %{"take_in" => held.take_in, "attempt" => attempt, "changed" => changed},
             :ok <- event(held, :confirmed, scope, now, data),
             {:ok, work_item} <- touch(held, now),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.confirm", work_item, %{details: data}) do
          {:ok, {work_item, told(work_item)}}
        end
      end)

    finish(result)
  end

  @doc false
  @spec explore_again(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def explore_again(%Scope{} = scope, %WorkItem{} = work_item, attempt) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held, current} <- hold_step(scope, :"work_item.explore_again", work_item, now),
             :ok <- waiting(current, [:no_result, :lost, :cancelled], attempt),
             {:ok, run} <- next_run(held),
             data = %{"take_in" => held.take_in, "attempt" => run.attempt},
             :ok <- event(held, :explore_again, scope, now, data),
             {:ok, work_item} <- touch(held, now),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.explore_again", work_item, %{details: data}) do
          {:ok, {work_item, told(work_item)}}
        end
      end)

    finish(result)
  end

  ## People's comments

  @doc false
  @spec comment(Scope.t(), WorkItem.t(), term) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def comment(%Scope{} = scope, %WorkItem{} = work_item, body) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held} <- hold(scope, :"work_item.comment", work_item),
             {:ok, comment} <- insert_comment(held, scope, body, now),
             {:ok, work_item} <- touch(held, now),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.comment", work_item, %{
                 details: %{"comment_id" => comment.public_id}
               }) do
          {:ok, {comment, comment_told(work_item)}}
        end
      end)

    finish(result)
  end

  defp insert_comment(held, scope, body, now) do
    %Comment{
      organisation_id: held.organisation_id,
      workspace_id: held.workspace_id,
      work_item_id: held.id,
      author_id: scope.user.id,
      inserted_at: now
    }
    |> Comment.changeset(%{body: body})
    |> PublicId.Insert.insert()
  end

  @doc false
  @spec delete_comment(Scope.t(), term) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | :deleted}
  def delete_comment(%Scope{} = scope, comment_id) do
    result =
      Repo.transact(fn ->
        with {:ok, workspace} <- workspace(scope),
             %Comment{} = found <- comment_in(workspace, comment_id),
             :ok <- Access.authorize(scope, :"work_item.comment_delete", found),
             %WorkItem{} = held <- in_workspace(workspace, found.work_item_id, true),
             %Comment{} = comment <- held_comment(held, found.id),
             :ok <- not_deleted(comment),
             {:ok, deleted} <-
               comment
               |> Ecto.Changeset.change(
                 body: nil,
                 deleted_at: DateTime.utc_now(),
                 deleted_by_id: scope.user.id
               )
               |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.comment_delete", held, %{
                 details: %{"comment_id" => comment.public_id, "author_id" => comment.author_id}
               }) do
          {:ok, {deleted, comment_told(held)}}
        else
          nil -> {:error, :not_found}
          {:error, _refusal} = refused -> refused
        end
      end)

    finish(result)
  end

  # The comment `id` names, of `workspace`, read with no lock; nil for an id that is not a
  # comment's public id, and for a comment of another workspace.
  defp comment_in(%Workspace{id: workspace_id, organisation_id: organisation_id}, id) do
    if Apiary.PublicId.valid?(Comment.prefix(), id) do
      Repo.one(
        from c in Comment,
          where:
            c.public_id == ^id and c.organisation_id == ^organisation_id and
              c.workspace_id == ^workspace_id
      )
    end
  end

  # The comment `id` of the work item `held`, held `FOR UPDATE` right after it: nil once
  # it moved with its work item to another workspace, or went.
  defp held_comment(%WorkItem{id: work_item_id, workspace_id: workspace_id}, id) do
    Repo.one(
      from c in Comment,
        where:
          c.id == ^id and c.work_item_id == ^work_item_id and c.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  defp not_deleted(%Comment{deleted_at: nil}), do: :ok
  defp not_deleted(%Comment{}), do: {:error, :deleted}

  # The one workspace to tell of a comment: the one its work item is in.
  defp comment_told(%WorkItem{} = work_item),
    do: %{work_items: [{work_item.workspace_id, work_item.public_id}], tickets: []}

  # `work_item` held as `hold/3` holds it, live, of the take in the page read, with where
  # Explore stands for it at `now`, read under its lock.
  defp hold_step(scope, action, %WorkItem{take_in: take_in} = work_item, now) do
    with {:ok, held} <- hold(scope, action, work_item),
         :ok <- live(held) do
      if held.take_in == take_in,
        do: {:ok, held, Explore.current(held, now)},
        else: {:error, :stale}
    end
  end

  # The latest run of the take in is the one the page named, and Explore stands at one of
  # `places`.
  defp waiting(%{step: %{attempt: attempt}, status: status}, places, attempt) do
    cond do
      status in places -> :ok
      status in [:queued, :running] -> {:error, :running}
      status == :used_up -> {:error, :used_up}
      true -> {:error, :not_waiting}
    end
  end

  defp waiting(_current, _places, _attempt), do: {:error, :stale}

  defp invalid({:ok, _checked} = ok), do: ok
  defp invalid({:error, :invalid}), do: {:error, {:invalid, :form}}
  defp invalid({:error, errors}) when is_map(errors), do: {:error, {:invalid, errors}}

  defp proposal_changes(_step, nil), do: {:ok, %{}}

  defp proposal_changes(step, params),
    do: invalid(Proposal.changes(Proposal.from_result(step.result), params))

  # The take in's next run (`Apiary.Dispatches.queue_next/2`): a take in with no run yet
  # does not wait for a member.
  defp next_run(held) do
    case Dispatches.queue_next(held, held.take_in) do
      {:ok, run} -> {:ok, run}
      {:error, :no_run} -> {:error, :not_waiting}
      {:error, _refusal} = refused -> refused
    end
  end

  defp keep_answers(held, scope, attempt, checked, now) do
    rows =
      for {position, question, answer} <- checked do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: held.organisation_id,
          workspace_id: held.workspace_id,
          work_item_id: held.id,
          take_in: held.take_in,
          attempt: attempt,
          position: position,
          question: question,
          answer: answer,
          answered_by_id: scope.user.id,
          answered_at: now
        }
      end

    {count, _rows} = Repo.insert_all(Answer, rows)
    if count == length(rows), do: :ok, else: {:error, :not_waiting}
  end

  defp keep_confirmation(held, scope, step, changes, now) do
    %Confirmation{
      id: Ecto.UUID.generate(),
      organisation_id: held.organisation_id,
      workspace_id: held.workspace_id,
      work_item_id: held.id,
      take_in: held.take_in,
      attempt: step.attempt,
      result: step.result,
      changes: Proposal.encode(changes),
      confirmed_by_id: scope.user.id,
      confirmed_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:take_in,
      name: :work_item_confirmations_work_item_id_take_in_index
    )
    |> Repo.insert()
    |> case do
      {:ok, _confirmation} -> :ok
      {:error, _changeset} = refused -> refused
    end
  end

  # The work item, marked changed at `now`.
  defp touch(held, now), do: held |> Ecto.Changeset.change(updated_at: now) |> Repo.update()

  ## Reading and holding

  # The scope's workspace, of its organisation.
  defp workspace(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{organisation_id: organisation_id} = workspace,
         user: %{id: user_id}
       })
       when is_binary(user_id),
       do: {:ok, workspace}

  defp workspace(%Scope{}), do: {:error, :not_found}

  # The ticket `item_id` while it is in the Backlog of `workspace`, its connection held
  # `FOR SHARE`, then its collection, read again under its lock (the moduledoc): the item,
  # its collection and its adapter; `:not_linked` for a collection assigned there that is
  # not linked.
  defp hold_ticket(
         %Scope{organisation: %Organisation{id: organisation_id}},
         %Workspace{id: workspace_id},
         item_id
       ) do
    with true <- Item.public_id?(item_id),
         %{} = found <-
           Repo.one(
             from i in Item,
               join: c in Collection,
               on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
               where: i.public_id == ^item_id and i.organisation_id == ^organisation_id,
               select: %{id: i.id, collection_id: c.id, connection_id: c.connection_id}
           ),
         %Connection{} <-
           Repo.one(
             from k in Connection,
               where: k.id == ^found.connection_id and k.state == :connected,
               where: is_nil(k.ended_at),
               lock: "FOR SHARE"
           ),
         %Collection{ended_at: nil, workspace_id: ^workspace_id} = collection <-
           Repo.one(from c in Collection, where: c.id == ^found.collection_id, lock: "FOR SHARE"),
         %Item{disconnected_at: nil} = item <- Repo.get(Item, found.id) do
      collection = Repo.preload(collection, :adapter, force: true)

      if Collection.linked?(collection),
        do: {:ok, %{item: item, collection: collection, adapter: collection.adapter}},
        else: {:error, :not_linked}
    else
      _not_in_the_backlog -> {:error, :not_found}
    end
  end

  # The work item of the ticket, by its organisation, its adapter and its ref, the key
  # that makes it one per ticket; held `FOR UPDATE` when `lock?`.
  defp by_key(%{item: %Item{} = item}, lock?) do
    query =
      from w in WorkItem,
        where:
          w.organisation_id == ^item.organisation_id and w.adapter_id == ^item.adapter_id and
            w.external_ref == ^item.external_ref

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  # No work item of the ticket yet; else `{:taken, work_item}`, as the person sees it
  # (`Apiary.WorkItems.as_seen/2`): one of another workspace by its state alone.
  defp none_yet(scope, ticket) do
    case by_key(ticket, true) do
      nil -> :ok
      %WorkItem{} = work_item -> {:error, {:taken, WorkItems.as_seen(scope, work_item)}}
    end
  end

  defp open(%{item: %Item{state: :open}}), do: :ok
  defp open(_ticket), do: {:error, :ticket_closed}

  # The work item's target: the ticket's target, else its collection's, nil for neither,
  # as the workspace's domain allows it (`Apiary.Lingo.Domain.check_target/2`).
  defp target(workspace, %{item: item, collection: collection}) do
    target =
      cond do
        is_binary(item.target_system) ->
          %{system: item.target_system, path: item.target_path}

        is_binary(collection.target_system) ->
          %{system: collection.target_system, path: collection.target_path}

        true ->
          nil
      end

    with :ok <- Domain.check_target(workspace, target), do: {:ok, target}
  end

  # The owner the page names, else the person taking it in, who acts in the workspace.
  defp owner(%Scope{user: %{id: user_id}} = scope, attrs) do
    case attr(attrs, :owner_id) do
      nil ->
        {:ok, user_id}

      ^user_id ->
        {:ok, user_id}

      owner_id when is_binary(owner_id) ->
        if Enum.any?(Organisations.list_workspace_members(scope), &(&1.user_id == owner_id)),
          do: {:ok, owner_id},
          else: {:error, :owner}

      _other ->
        {:error, :owner}
    end
  end

  defp instruction(attrs) do
    case attr(attrs, :first_instruction) do
      nil -> ""
      text -> text
    end
  end

  # What the page gives under `key`, an atom, or its string, as a form's params name it.
  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  # `work_item`, of the scope's workspace, asked `action` of, then held `FOR UPDATE` and
  # read again: one that moved meanwhile is not found, as is one whose id is no UUID.
  defp hold(scope, action, %WorkItem{id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id, false),
         :ok <- Access.authorize(scope, action, found),
         %WorkItem{} = held <- in_workspace(workspace, id, true) do
      {:ok, held}
    else
      :error -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _reason} = refused -> refused
    end
  end

  defp in_workspace(%Workspace{id: workspace_id, organisation_id: organisation_id}, id, lock?) do
    query =
      from w in WorkItem,
        where:
          w.id == ^id and w.organisation_id == ^organisation_id and
            w.workspace_id == ^workspace_id

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp live(%WorkItem{state: state}),
    do: if(State.live?(state), do: :ok, else: {:error, :not_live})

  defp adapter_of(%WorkItem{adapter_id: adapter_id}), do: Repo.get!(Node, adapter_id)

  ## Writing

  defp event(work_item, kind, %Scope{user: %{id: user_id}}, now, data) do
    %WorkItemEvent{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id
    }
    |> WorkItemEvent.changeset(%{
      kind: kind,
      actor_kind: :person,
      actor_id: user_id,
      at: now,
      data: data
    })
    |> Repo.insert()
    |> case do
      {:ok, _event} -> :ok
      {:error, _changeset} = refused -> refused
    end
  end

  defp feed(%Node{} = adapter, work_item, status) do
    Feed.append(adapter, %{
      kind: "work_item",
      work_item_id: work_item.public_id,
      ref: work_item.external_ref,
      status: status,
      url: WorkItems.stable_url(work_item)
    })
  end

  defp feed_if(true, adapter, work_item, status), do: feed(adapter, work_item, status)
  defp feed_if(false, _adapter, _work_item, _status), do: {:ok, nil}

  # The adapter of `work_item` is read only when it is told.
  defp feed_if(true, work_item, status), do: feed(adapter_of(work_item), work_item, status)
  defp feed_if(false, _work_item, _status), do: {:ok, nil}

  ## Telling

  # The workspaces to tell of a change to `work_item`: the one it is in, and each whose
  # Backlog shows its ticket's live record. A test work item has no ticket.
  defp told(%WorkItem{test: true} = work_item),
    do: %{work_items: [{work_item.workspace_id, work_item.public_id}], tickets: []}

  defp told(%WorkItem{} = work_item) do
    tickets =
      Repo.all(
        from i in Item,
          join: c in Collection,
          on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
          where:
            i.organisation_id == ^work_item.organisation_id and
              i.adapter_id == ^work_item.adapter_id and
              i.external_ref == ^work_item.external_ref,
          where: is_nil(i.disconnected_at) and is_nil(c.ended_at) and not is_nil(c.workspace_id),
          select: {c.workspace_id, i.public_id}
      )

    %{work_items: [{work_item.workspace_id, work_item.public_id}], tickets: tickets}
  end

  defp finish({:ok, {work_item, told}}) do
    tell(told)
    {:ok, work_item}
  end

  defp finish({:error, _refusal} = refused), do: refused

  # Sent once the change commits: ids only, grouped by workspace.
  defp tell(told) do
    for {workspace_id, ids} <- group(told.work_items) do
      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        WorkItems.topic(workspace_id),
        {:work_items_changed, ids}
      )
    end

    for {workspace_id, ids} <- group(told.tickets) do
      Phoenix.PubSub.broadcast(Apiary.PubSub, Topic.topic(workspace_id), {:tickets_changed, ids})
    end

    Dispatches.broadcast(Map.get(told, :queues, []))
  end

  defp group(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
