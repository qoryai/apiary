defmodule Apiary.WorkItems do
  # WorkItems holds a workspace's work items (`Apiary.WorkItems.WorkItem`): what the
  # sidebar counts, how the pages name a work item's ticket, the work items a page reads,
  # and what a person does to them.
  #
  # ## What a person does: take in, take in again, undo, close
  #
  # `take_in(scope, item_id, attrs)` takes the ticket `item_id` (`tk_…`) of the Backlog of
  # the scope's workspace in as a new work item, with its first run queued;
  # `take_in_again(scope, item_id, attrs)` brings back the ended work item of that ticket,
  # in the organisation, live again in the scope's workspace, with a new count of runs;
  # `take_in_test(scope, line)` makes a test work item from a line the person typed, with
  # no ticket, and queues its first run; `undo(scope, work_item)` undoes the latest take
  # in while no claim holds its run; `close(scope, work_item)` closes a live one. `attrs`
  # has the owner (`owner_id`), the first instruction (`first_instruction`) and a comment
  # on the ticket (`comment`) the page sends. Each runs in one transaction with
  # its event, its run, its feed entry and its entry in the trail, asks its action of
  # `Apiary.Access`, and tells the pages once it commits. `Apiary.WorkItems.Moves` says
  # how, what each refuses, and the order of its locks.
  #
  # ## What a member gives Explore: answer, review comments, confirm, explore again
  #
  # `answer(scope, work_item, attempt, answers)` answers one or more of the open questions
  # of the work item, by their position (`"1"` to `"20"`), or, given a text, writes a
  # review comment on the proposal and sends it, and queues the take in's next run, which
  # reads the questions and the review comments as artifacts (`Apiary.Explore.Questions`,
  # `Apiary.Explore.ReviewComments`); `reply/5` writes a reply while no run is running,
  # and queues no run; `review_comment/4` writes a review comment the same way, and
  # `send_review_comments(scope, work_item, attempt)` queues the next run where the
  # questions or the proposal wait and a review comment is open: no page calls these
  # two, and tests call them to set up a work item;
  # `another_round(scope, work_item, attempt, round)` does what Run another round on
  # Explore's tab sends, in one move: the answers, a comment on the whole proposal and
  # the open review comments go to one next run;
  # `confirm(scope, work_item, attempt)` confirms the latest run's proposal, which makes
  # the work item ready for Shape;
  # `explore_again(scope, work_item, attempt)` queues the take in's next run after a run
  # that gave no result, was lost or was cancelled. `attempt` is the latest run's, as the
  # page read it. `Apiary.WorkItems.Moves` says how and what each refuses.
  #
  # ## People's comments on the Thread
  #
  # `comment(scope, work_item, body)` writes a comment of the scope's person on the work
  # item, in any state, and `delete_comment(scope, comment_id)` deletes the comment
  # `comment_id` (`cm_…`) of the scope's workspace, leaving a line in its place
  # (`Apiary.WorkItems.Comment`, `Apiary.WorkItems.Moves`). `list_comments/2` is the work
  # item's comments, deleted ones too, oldest first; `count_comments/2` how many are not
  # deleted, the count beside the Thread's tab; and `thread/3` the Thread itself: what
  # happened at Explore (`explore_thread/3`) and the comments, oldest first. Each read
  # answers nothing to a person who may not read the work item.
  #
  # ## Reading Explore: `explore/2` and `explore_thread/2`
  #
  # `explore(scope, work_item)` is where Explore stands for the work item, and
  # `explore_thread(scope, work_item)` what happened to it at Explore, for the Thread, as
  # the work item pages draw them (`Apiary.WorkItems.ExploreView`), to a person who may
  # read the work item; nil and none otherwise.
  #
  # The pages hear of a change to a workspace's work items on its topic (`topic/1`,
  # `subscribe/1`): `{:work_items_changed, ids}`, the work items' public ids, sent once the
  # change commits.
  #
  # ## Reading: the list and the lookups
  #
  # `list_work_items(scope, params)` is a page of the Work items list, `list_bands/4` its
  # Open view by stage, `list_stage_counts/3` how many live work items are at each stage
  # of the workflow model and `list_filter_values/3` what its Filter menu offers
  # (`Apiary.WorkItems.WorkList`); `get_by_number/2`, `get_by_public_id/2` and
  # `get_for_ticket/2` find one work item for a page, and `ticket/3` is its ticket for the
  # work item page's Ticket tab. Each answers nothing to a person who may not read the
  # workspace's work items (`work_item.read`). Each reads a test work item
  # (`Apiary.WorkItems.WorkItem.test_changeset/2`) as any work item; its ticket has no
  # record and no integration.
  #
  # ## Closing: `close_locked/3` and `close_for_adapter/2`
  #
  # `close_locked(work_items, closer, now)` is the one close of a work item, whoever
  # closes it, inside the caller's transaction, which holds each work item `FOR UPDATE`.
  # Each one is live (`Apiary.WorkItems.State.live?/1`): exploring, the one state a member
  # may close, whatever it waits on (Confirm, the questions, a run without a result, the
  # run limit, Shape once confirmed). Each moves to `:closed`
  # (`Apiary.WorkItems.State.next/2`), with `closed_at` `now` and `closed_by_id` the
  # person who closed it, or nil when the instance did, and gets its event, `:closed`,
  # by the person, or by the instance with the reason it gives in the event's data
  # (`%{"reason" => reason}`), and with the stage Explore was at, `"stage"`
  # (`Apiary.WorkItems.Explore.stage/1`). Its runs of the
  # queue not yet handed over end (`Apiary.Dispatches.cancel_for_close/2`); a run handed
  # over goes on to its end. Its ticket, and anything at the ticket's source, is left as
  # it is. It answers the workspaces whose queue changed, for the caller to tell once its
  # transaction commits (`Apiary.Dispatches.broadcast/1`).
  #
  # The instance closes a work item with one of three reasons: `last_stage_done`, when its
  # last stage finishes (`Apiary.Stages`), `ticket_closed`, when its ticket closes at the
  # source (`Apiary.Sources.Ingest`), and `adapter_removed`, below.
  #
  # `close_for_adapter(adapter, now)` closes, as the instance (`adapter_removed`), every
  # live work item of every organisation whose ticket came through a connection to
  # `adapter`, inside the caller's transaction: the removal of the adapter
  # (`Apiary.Adapters.delete_adapter/2`). Closed and undone work items are left
  # as they are.
  #
  # **The lock order.** The core takes its locks in one order, which
  # `Apiary.Adapters.Collections` writes out in full: the adapter's row, its connections,
  # the workspaces `FOR SHARE`, the collections, the targets, then the work items
  # `FOR UPDATE`, by id when there are several, then a workspace's counter of numbers
  # (`Apiary.WorkItems.Number`), taken only right after its work item, then the
  # environment records, the runs of the queue and their dispatches
  # (`Apiary.Dispatches.Slots`), the adapter's feed counter, and, last, for a work item that
  # moves, the target's counter of run numbers (`Apiary.Runs.Number.raise_past/2`). A
  # comment of a work item (`Apiary.WorkItems.Comment`) is locked `FOR UPDATE` only right
  # after its work item, as a comment's deletion locks it. No collection or
  # target is locked after a work item. A close takes the connections first (the removal
  # ends them before it closes), then the work items `FOR UPDATE` in the order of their
  # ids, then their runs of the queue `FOR UPDATE` in the order of their ids, then the
  # dispatches of those runs, written. The slots of a node pool's instance limit that the
  # ended dispatches held are freed by a write of the dispatches that frees each one once
  # (`Apiary.Dispatches.Slots`), with no lock on the pool's row: a claim holds its pool
  # before the runs it lapses, so a close that held runs and then waited on a pool could
  # wait on a claim that waits on it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false
  import Apiary.WorkItems.Finished, only: [finished: 2]

  alias Apiary.{Access, Dispatches, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Sources.Comment, as: SourceComment
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{Comment, Explore, ExploreView, Moves, State, WorkItem}
  alias Apiary.WorkItems.{WorkItemEvent, WorkList}

  # The largest number a work item has, the column's: a bigint.
  @max_number 9_223_372_036_854_775_807

  # How many of a ticket's latest comments the Ticket tab draws before Show earlier
  # comments.
  @latest_comments 3

  @typedoc """
  Who closes a work item: a person, by the id of their account, or the instance, with the
  reason it gives.
  """
  @type closer :: {:person, Ecto.UUID.t()} | {:instance, String.t()}

  @doc false
  # How many of the scope's workspace's work items wait on the scope's person: the count
  # beside the sidebar's Work items, and the Work items list's Waiting on you. They are the
  # live work items the person owns whose proposal waits at Confirm
  # (`Apiary.WorkItems.WorkList.waiting_on/2`, with its `opts`); 0 to a person who may not
  # read them.
  @spec count_waiting_on(Scope.t(), keyword) :: non_neg_integer
  def count_waiting_on(%Scope{} = scope, opts \\ []), do: WorkList.waiting_on(scope, opts)

  ## What a person does

  @doc false
  # take_in/3 takes the ticket `item_id` (`tk_…`) of the Backlog of the scope's workspace
  # in as a new work item (`Apiary.WorkItems.Moves`): `{:ok, work_item}`, or a refusal.
  @spec take_in(Scope.t(), String.t(), Moves.take_in_attrs()) ::
          {:ok, WorkItem.t()} | {:error, Moves.take_in_refusal()}
  def take_in(%Scope{} = scope, item_id, attrs \\ %{}),
    do: Moves.take_in(scope, item_id, Map.new(attrs))

  @doc false
  # take_in_test/2 makes a test work item of the scope's workspace from `line`, the line
  # a person typed, with its first run queued, asked as a take in is
  # (`Apiary.WorkItems.Moves`): `{:ok, work_item}`, or a refusal.
  @spec take_in_test(Scope.t(), term) ::
          {:ok, WorkItem.t()}
          | {:error, :not_found | :forbidden | :test_running | Ecto.Changeset.t()}
  defdelegate take_in_test(scope, line), to: Moves

  @doc false
  # take_in_again/3 brings back the ended work item of the ticket `item_id`, live again in
  # the scope's workspace (`Apiary.WorkItems.Moves`): `{:ok, work_item}`, or a refusal.
  @spec take_in_again(Scope.t(), String.t(), Moves.take_in_attrs()) ::
          {:ok, WorkItem.t()} | {:error, Moves.take_in_refusal()}
  def take_in_again(%Scope{} = scope, item_id, attrs \\ %{}),
    do: Moves.take_in_again(scope, item_id, Map.new(attrs))

  @doc false
  # undo/2 undoes the latest take in of `work_item` while no claim holds its run
  # (`Apiary.WorkItems.Moves`).
  @spec undo(Scope.t(), WorkItem.t()) ::
          {:ok, WorkItem.t()} | {:error, :not_found | :forbidden | :not_live | :claimed}
  defdelegate undo(scope, work_item), to: Moves

  @doc false
  # close/2 closes `work_item`, as the scope's person (`close_locked/3`,
  # `Apiary.WorkItems.Moves`).
  @spec close(Scope.t(), WorkItem.t()) ::
          {:ok, WorkItem.t()} | {:error, :not_found | :forbidden | :not_live}
  defdelegate close(scope, work_item), to: Moves

  @doc false
  # answer/4 answers open questions at the latest run, `attempt`, of `work_item`'s take
  # in, or writes a review comment on its proposal and sends it, and queues its next run
  # (`Apiary.WorkItems.Moves`).
  @spec answer(Scope.t(), WorkItem.t(), pos_integer, map | String.t() | [Moves.answer_by_id()]) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  def answer(%Scope{} = scope, %WorkItem{} = work_item, attempt, answers),
    do: member_round(scope, work_item, fn -> Moves.answer(scope, work_item, attempt, answers) end)

  @doc false
  # review_comment/4 writes the scope's member's review comment on the newest proposal of
  # `work_item`'s take in, whose latest run is `attempt`, while no run is running; it
  # queues no run (`Apiary.WorkItems.Moves`).
  @spec review_comment(Scope.t(), WorkItem.t(), pos_integer, term) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  defdelegate review_comment(scope, work_item, attempt, text), to: Moves

  @doc false
  # reply/5 adds the scope's member's reply to the review comment `id`, which opens it
  # again, while no run is running; it queues no run (`Apiary.WorkItems.Moves`).
  @spec reply(Scope.t(), WorkItem.t(), pos_integer, String.t(), term) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  defdelegate reply(scope, work_item, attempt, id, text), to: Moves

  @doc false
  # send_review_comments/3 queues the next run of `work_item`'s take in, where the
  # questions or the proposal of its latest run, `attempt`, wait and a review comment is
  # open (`Apiary.WorkItems.Moves`).
  @spec send_review_comments(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  def send_review_comments(%Scope{} = scope, %WorkItem{} = work_item, attempt),
    do:
      member_round(scope, work_item, fn ->
        Moves.send_review_comments(scope, work_item, attempt)
      end)

  @doc false
  # another_round/4 queues the next run of `work_item`'s take in with the answers and the
  # comment of `round`, and the open review comments, where the questions or the proposal
  # of its latest run, `attempt`, wait (`Apiary.WorkItems.Moves`).
  @spec another_round(Scope.t(), WorkItem.t(), pos_integer, Moves.round()) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  def another_round(%Scope{} = scope, %WorkItem{} = work_item, attempt, round),
    do:
      member_round(scope, work_item, fn ->
        Moves.another_round(scope, work_item, attempt, round)
      end)

  # Hand-over: with the workflow model, a move that runs the stage's next round where it
  # resolves an escalation, or at the gate of a stage after Explore's, has the same check
  # as the stage's gate, and records who resolved the escalation
  # (`Apiary.Stages.member_round/3`). The move runs inside that transaction, so what it
  # tells before the commit is told again once the commit is done (`Moves.tell/1`).
  defp member_round(scope, work_item, move) do
    if Apiary.Stages.on?() do
      case Apiary.Stages.member_round(scope, work_item, move) do
        {:ok, %WorkItem{} = done} = ok ->
          Moves.tell(done)
          ok

        refused ->
          refused
      end
    else
      move.()
    end
  end

  @doc false
  # confirm/3 confirms the proposal of the latest run, `attempt`, of `work_item`'s take
  # in (`Apiary.WorkItems.Moves`).
  @spec confirm(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  def confirm(%Scope{} = scope, %WorkItem{} = work_item, attempt) do
    # Hand-over: with the workflow model, the confirmation approves Explore's gate in the
    # same transaction (`Apiary.Stages.confirmed/3`).
    if Apiary.Stages.on?() do
      Repo.transact(fn ->
        with {:ok, confirmed} <- Moves.confirm(scope, work_item, attempt),
             explore = Apiary.Stages.confirmed_stage_id(confirmed, attempt),
             {:ok, _placed} <-
               Apiary.Stages.confirmed(scope, confirmed, expect_stage: explore),
             do: {:ok, Repo.get!(WorkItem, confirmed.id)}
      end)
    else
      Moves.confirm(scope, work_item, attempt)
    end
  end

  @doc false
  # explore_again/3 queues the next run of `work_item`'s take in after its latest run,
  # `attempt`, gave no result, was lost or was cancelled (`Apiary.WorkItems.Moves`).
  @spec explore_again(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, Moves.step_refusal()}
  def explore_again(%Scope{} = scope, %WorkItem{} = work_item, attempt) do
    again = fn -> Moves.explore_again(scope, work_item, attempt) end

    # Hand-over: with the workflow model, Explore again where it resolves an escalation
    # has the same check as the stage's gate (`Apiary.Stages.member_round/3`).
    member_round(scope, work_item, again)
  end

  @doc false
  # comment/3 writes a comment of the scope's person on `work_item`
  # (`Apiary.WorkItems.Moves`): `{:ok, comment}`, or a refusal.
  @spec comment(Scope.t(), WorkItem.t(), term) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  defdelegate comment(scope, work_item, body), to: Moves

  @doc false
  # delete_comment/2 deletes the comment `comment_id` (`cm_…`) of the scope's workspace,
  # leaving a line in its place (`Apiary.WorkItems.Moves`): `{:ok, comment}`, or a refusal.
  @spec delete_comment(Scope.t(), term) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | :deleted}
  defdelegate delete_comment(scope, comment_id), to: Moves

  ## Reading Explore

  @doc false
  # explore/3 is where Explore stands for `work_item` at `now`, as the work item pages
  # draw it (`Apiary.WorkItems.ExploreView`), to a person who may read it there; nil
  # otherwise. Only the work item's id is taken from `work_item`: the row is read again
  # within the scope's organisation and workspace, and drawn as the database holds it.
  @spec explore(Scope.t(), WorkItem.t(), DateTime.t()) :: map | nil
  def explore(%Scope{} = scope, %WorkItem{} = work_item, now \\ DateTime.utc_now()) do
    case readable(scope, work_item) do
      {:ok, row} -> ExploreView.explore(row, now)
      :error -> nil
    end
  end

  @doc false
  # explore_thread/3 is what happened to `work_item` at Explore, at `now`, for the
  # Thread (`Apiary.WorkItems.ExploreView`), to a person who may read it there; none
  # otherwise. The row is read again by its id, as for `explore/3`.
  @spec explore_thread(Scope.t(), WorkItem.t(), DateTime.t()) :: [map]
  def explore_thread(%Scope{} = scope, %WorkItem{} = work_item, now \\ DateTime.utc_now()) do
    case readable(scope, work_item) do
      {:ok, row} -> ExploreView.thread(row, now)
      :error -> []
    end
  end

  ## Reading people's comments

  @doc false
  # list_comments/2 is every comment of `work_item`, deleted ones too (no body), oldest
  # first, to a person who may read it in the scope's workspace; none otherwise.
  @spec list_comments(Scope.t(), WorkItem.t()) :: [Comment.t()]
  def list_comments(%Scope{} = scope, %WorkItem{} = work_item) do
    case readable(scope, work_item) do
      {:ok, row} -> comments(row)
      :error -> []
    end
  end

  @doc false
  # count_comments/2 is how many comments of `work_item` are not deleted, to a person who
  # may read it in the scope's workspace; 0 otherwise.
  @spec count_comments(Scope.t(), WorkItem.t()) :: non_neg_integer
  def count_comments(%Scope{} = scope, %WorkItem{} = work_item) do
    case readable(scope, work_item) do
      {:ok, row} ->
        Repo.one(
          from c in Comment,
            where:
              c.work_item_id == ^row.id and c.workspace_id == ^row.workspace_id and
                is_nil(c.deleted_at),
            select: count()
        )

      :error ->
        0
    end
  end

  @doc false
  # thread/3 is the Thread of `work_item` at `now`, oldest first, to a person who may read
  # it in the scope's workspace; none otherwise: what happened at Explore, as
  # `explore_thread/3` gives it, and each comment, deleted ones too, as
  # `%{kind: :comment, at: inserted_at, comment: comment}`. An entry of Explore and a
  # comment at the same moment keep Explore's first; each kind keeps its order.
  @spec thread(Scope.t(), WorkItem.t(), DateTime.t()) :: [map]
  def thread(%Scope{} = scope, %WorkItem{} = work_item, now \\ DateTime.utc_now()) do
    case readable(scope, work_item) do
      {:ok, row} ->
        events = Enum.map(ExploreView.thread(row, now), &{&1, 0})

        comments =
          Enum.map(comments(row), &{%{kind: :comment, at: &1.inserted_at, comment: &1}, 1})

        (events ++ comments)
        |> Enum.with_index()
        |> Enum.sort_by(fn {{entry, kind}, index} ->
          {DateTime.to_unix(entry.at, :microsecond), kind, index}
        end)
        |> Enum.map(fn {{entry, _kind}, _index} -> entry end)

      :error ->
        []
    end
  end

  defp comments(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.all(
      from c in Comment,
        where: c.work_item_id == ^id and c.workspace_id == ^workspace_id,
        order_by: [asc: c.inserted_at, asc: c.id]
    )
  end

  # The row of the work item `id` names, of the scope's organisation and workspace, which
  # the person may read: `{:ok, row}`, or `:error` for an id that is not a UUID, a work
  # item of another organisation or workspace, one not there, or a person who may not
  # read it.
  defp readable(scope, %WorkItem{id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, organisation_id, workspace_id} <- workspace(scope),
         %WorkItem{} = row <-
           Repo.one(
             from w in WorkItem,
               where:
                 w.id == ^id and w.organisation_id == ^organisation_id and
                   w.workspace_id == ^workspace_id
           ),
         true <- Access.can?(scope, :"work_item.read", row) do
      {:ok, row}
    else
      _refused -> :error
    end
  end

  ## What the pages hear

  @doc false
  # topic/1 is the topic of the work items of the workspace `workspace_id`.
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: "work_items:" <> workspace_id

  @doc false
  # subscribe/1 subscribes the caller to the topic of the work items of the scope's
  # workspace, for a person who may read them (`work_item.read`, asked of the person as
  # they are now): `:ok`, or `Apiary.Access`'s refusal.
  @spec subscribe(Scope.t()) :: :ok | {:error, Access.reason()}
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id} = workspace} = scope) do
    with :ok <- Access.authorize(scope, :"work_item.read", workspace),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))
  end

  def subscribe(%Scope{}), do: {:error, :not_found}

  ## Reading

  @doc false
  # list_work_items/4 is a page of the Work items list of the scope's workspace
  # (`Apiary.WorkItems.WorkList.list/4`, with its `opts`).
  @spec list_work_items(Scope.t(), map | keyword, DateTime.t(), keyword) :: WorkList.page()
  def list_work_items(%Scope{} = scope, params \\ %{}, now \\ DateTime.utc_now(), opts \\ []),
    do: WorkList.list(scope, params, now, opts)

  @doc false
  # list_bands/4 is the Work items list's Open view of the scope's workspace by stage
  # (`Apiary.WorkItems.WorkList.bands/4`, with its `opts`).
  @spec list_bands(Scope.t(), map | keyword, DateTime.t(), keyword) :: WorkList.bands()
  def list_bands(%Scope{} = scope, params \\ %{}, now \\ DateTime.utc_now(), opts \\ []),
    do: WorkList.bands(scope, params, now, opts)

  @doc false
  # list_stage_counts/3 is how many live work items of the scope's workspace are at each
  # stage of the workflow model (`Apiary.WorkItems.WorkList.stage_counts/3`).
  @spec list_stage_counts(Scope.t(), map | keyword, DateTime.t()) :: [WorkList.stage_count()]
  def list_stage_counts(%Scope{} = scope, params \\ %{}, now \\ DateTime.utc_now()),
    do: WorkList.stage_counts(scope, params, now)

  @doc false
  # list_filter_values/3 is what the Work items list's Filter menu offers for `kind`
  # (`Apiary.WorkItems.WorkList.filter_values/3`).
  @spec list_filter_values(Scope.t(), :owner | :collection, String.t() | nil) ::
          [WorkList.value()]
  def list_filter_values(%Scope{} = scope, kind, query \\ nil),
    do: WorkList.filter_values(scope, kind, query)

  @doc false
  # get_by_number/2 is the work item of the scope's workspace numbered `number`, to a
  # person who may read its work items; nil otherwise, and for no such number.
  @spec get_by_number(Scope.t(), term) :: WorkItem.t() | nil
  def get_by_number(%Scope{} = scope, number) do
    with {:ok, number} <- number(number),
         {:ok, organisation_id, workspace_id} <- workspace(scope) do
      Repo.one(
        from w in WorkItem,
          where:
            w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id and
              w.number == ^number
      )
    else
      _none -> nil
    end
  end

  # A number the column holds, a bigint: an integer up to its largest, or text of at most
  # 18 digits, as the Work items list reads one.
  defp number(number) when is_integer(number) and number in 1..@max_number//1,
    do: {:ok, number}

  defp number(text) when is_binary(text) and byte_size(text) <= 18 do
    case Integer.parse(text) do
      {number, ""} when number >= 1 -> {:ok, number}
      _not -> :error
    end
  end

  defp number(_other), do: :error

  @doc false
  # get_by_public_id/2 is the work item of the scope's organisation whose public id is
  # `public_id` (`wi_…`), in whichever of its workspaces it is now, with that workspace,
  # to a person who may read the work items there. nil otherwise.
  @spec get_by_public_id(Scope.t(), term) :: WorkItem.t() | nil
  def get_by_public_id(%Scope{organisation: %Organisation{id: organisation_id}} = scope, id) do
    with true <- Apiary.PublicId.valid?(WorkItem.prefix(), id),
         %WorkItem{} = work_item <-
           Repo.one(
             from w in WorkItem,
               where: w.public_id == ^id and w.organisation_id == ^organisation_id,
               preload: :workspace
           ),
         true <-
           Access.can?(%{scope | workspace: work_item.workspace}, :"work_item.read", work_item) do
      work_item
    else
      _none -> nil
    end
  end

  def get_by_public_id(%Scope{}, _id), do: nil

  @doc false
  # locate/2 is what the address `stable_url/1` returns leads to: the work item whose
  # public id is `public_id` (`wi_…`), in whichever organisation and workspace it is now,
  # and the person's scope in that workspace, for a person who reaches that workspace and
  # may read its work items there, as the work item's page checks: `{:ok, work_item,
  # scope}`, the work item with that workspace. `:error` for anything else, one result
  # for all, so the caller's response does not show whether the id exists.
  #
  # The reads are the same for every id, in the same order, so their time does not show
  # it either: the person's scope in each workspace of each organisation they reach
  # (`Apiary.Organisations.list_places/1`, `Apiary.Organisations.workspace_scopes/1`, as
  # `Apiary.Organisations.resolve_scope/4` puts it when the person opens one), then one
  # read of the work item among those workspaces, with an empty id, which no work item
  # has, in place of a malformed one. `Apiary.Access.can?/3` then checks in that scope
  # whether the person may read it, with no read.
  @spec locate(Scope.t(), term) :: {:ok, WorkItem.t(), Scope.t()} | :error
  def locate(%Scope{user: %Apiary.Accounts.User{} = user} = scope, public_id) do
    scopes =
      for %{organisation: %Organisation{} = organisation} <-
            Apiary.Organisations.list_places(user),
          {:ok, reached} <- [Apiary.Organisations.put_reach(scope, organisation)],
          {workspace_id, there} <- Apiary.Organisations.workspace_scopes(reached),
          into: %{},
          do: {workspace_id, there}

    id = if Apiary.PublicId.valid?(WorkItem.prefix(), public_id), do: public_id, else: ""
    workspace_ids = Map.keys(scopes)

    with %WorkItem{} = work_item <-
           Repo.one(
             from w in WorkItem,
               where: w.public_id == ^id and w.workspace_id in ^workspace_ids
           ),
         %Scope{workspace: %Workspace{} = workspace} = there <- scopes[work_item.workspace_id],
         work_item = %{work_item | workspace: workspace},
         true <- Access.can?(there, :"work_item.read", work_item) do
      {:ok, work_item, there}
    else
      _none -> :error
    end
  end

  def locate(_scope, _public_id), do: :error

  @doc false
  # get_for_ticket/2 is the work item of the ticket `item_id` (`tk_…`) of a collection
  # assigned to the scope's workspace: the one of the ticket's organisation, adapter and
  # ref, in any workspace of the organisation and in any state, as the Backlog shows it
  # (`as_seen/2`): the whole work item when it is in the scope's workspace and the person
  # may read it there, else a work item with its state alone. nil for none, and to a
  # person who may not read the workspace's work items.
  @spec get_for_ticket(Scope.t(), term) :: WorkItem.t() | nil
  def get_for_ticket(%Scope{} = scope, item_id) do
    with true <- Item.public_id?(item_id),
         {:ok, organisation_id, workspace_id} <- workspace(scope) do
      Repo.one(
        from i in Item,
          join: c in Collection,
          on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
          join: w in WorkItem,
          on:
            w.organisation_id == i.organisation_id and w.adapter_id == i.adapter_id and
              w.external_ref == i.external_ref,
          where:
            i.public_id == ^item_id and i.organisation_id == ^organisation_id and
              c.workspace_id == ^workspace_id,
          select: w
      )
      |> case do
        nil -> nil
        %WorkItem{} = work_item -> as_seen(scope, work_item)
      end
    else
      _none -> nil
    end
  end

  @doc false
  # take_in_again?/1 is whether Take in again can bring the ended `work_item` back: its
  # ticket's record (`ticket_query/0`) is open at its source, and the work item is not
  # finished with its ticket not reopened (`Apiary.WorkItems.Finished`).
  @spec take_in_again?(WorkItem.t()) :: boolean
  def take_in_again?(%WorkItem{id: id}) do
    Repo.exists?(
      from w in WorkItem,
        as: :work_item,
        left_lateral_join: t in subquery(ticket_query()),
        on: true,
        join: i in Item,
        on: i.id == t.item_id and i.organisation_id == w.organisation_id,
        where: w.id == ^id and i.state == :open and not finished(w, i)
    )
  end

  @doc false
  # as_seen/2 is `work_item` as a person of the scope's workspace sees it, as the Backlog
  # shows a ticket's work item: the whole work item when it is in the scope's workspace and
  # the person may read it there (`work_item.read`, asked of it); else a work item with
  # its state alone, no id, public id, number or workspace of it.
  @spec as_seen(Scope.t(), WorkItem.t()) :: WorkItem.t()
  def as_seen(
        %Scope{workspace: %Workspace{id: workspace_id}} = scope,
        %WorkItem{workspace_id: workspace_id} = work_item
      ) do
    if Access.can?(scope, :"work_item.read", work_item),
      do: work_item,
      else: state_only(work_item)
  end

  def as_seen(%Scope{}, %WorkItem{} = work_item), do: state_only(work_item)

  defp state_only(%WorkItem{state: state}), do: %WorkItem{state: state}

  @doc false
  # item_nouns/2 is what the sources of the work items `ids` of the organisation
  # `organisation_id` call their items, by work item, for those whose adapter names them
  # (`Apiary.Adapters.item_noun/1`): how the Activity page names a ticket taken in.
  @spec item_nouns(Ecto.UUID.t(), [Ecto.UUID.t()]) :: %{
          Ecto.UUID.t() => %{one: String.t(), other: String.t()}
        }
  def item_nouns(_organisation_id, []), do: %{}

  def item_nouns(organisation_id, ids) when is_binary(organisation_id) and is_list(ids) do
    from(w in WorkItem,
      join: n in Node,
      on: n.id == w.adapter_id,
      where: w.organisation_id == ^organisation_id and w.id in ^ids,
      select: {w.id, n}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {id, adapter} ->
      case Apiary.Adapters.item_noun(adapter) do
        nil -> []
        noun -> [{id, noun}]
      end
    end)
    |> Map.new()
  end

  @doc false
  # ticket_names/2 is how the work item pages name the ticket of each of `work_items`, by
  # the work item's id: its `key` at the source, such as `"#1204"`, or nil, the
  # `collection_title`, the title of the collection that holds it, as the Backlog draws
  # them, and `ticket_id`, the public id (`tk_…`) of its live record, which the Backlog
  # opens it by (Take in again), or nil when no record of it is live. The ticket's ref at
  # the source is never in it.
  #
  # A work item's ticket is the record of the work item's organisation, adapter and ref,
  # as the Backlog links them, of a collection assigned to the work item's workspace,
  # with its Backlog on or off. Where
  # several records share the ref, it is the live one (the record not disconnected, its
  # collection not ended, its connection connected), else the one that ended last. A work
  # item with no such record has no key, and its collection title as it was taken in.
  #
  # Only work items of the scope's workspace are named, and only when the scope's person
  # may read its work items (`work_item.read`); any other gets no entry. One query names
  # them all, whatever their number.
  @spec ticket_names(Scope.t(), [WorkItem.t()]) :: %{
          Ecto.UUID.t() => %{
            key: String.t() | nil,
            collection_title: String.t(),
            ticket_id: String.t() | nil
          }
        }
  def ticket_names(%Scope{} = scope, work_items) when is_list(work_items) do
    ids = for %WorkItem{id: id} when is_binary(id) <- work_items, uniq: true, do: id

    case {ids, workspace(scope)} do
      {[_ | _], {:ok, organisation_id, workspace_id}} ->
        from(w in WorkItem,
          as: :work_item,
          left_lateral_join: t in subquery(ticket_query()),
          on: true,
          where:
            w.id in ^ids and w.organisation_id == ^organisation_id and
              w.workspace_id == ^workspace_id,
          select:
            {w.id,
             %{
               key: t.key,
               collection_title: coalesce(t.title, w.collection_title),
               ticket_id: fragment("CASE WHEN ? THEN ? END", t.live, t.public_id)
             }}
        )
        |> Repo.all()
        |> Map.new()

      _none ->
        %{}
    end
  end

  @doc false
  # ticket_query/0 is the ticket of the work item named `:work_item` in the query around
  # it, for a lateral join: the key, the collection's title and the public id of its live
  # record, else of the one that ended last, and whether it is live, as `ticket_names/2`
  # and the Work items list read it; with the record's id, whether its connection ended at
  # the integration's uninstall, and when it ended, as `ticket/3` reads them.
  @spec ticket_query() :: Ecto.Query.t()
  def ticket_query do
    from i in Item,
      join: c in Collection,
      on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      where:
        i.organisation_id == parent_as(:work_item).organisation_id and
          i.adapter_id == parent_as(:work_item).adapter_id and
          i.external_ref == parent_as(:work_item).external_ref and
          c.workspace_id == parent_as(:work_item).workspace_id,
      order_by: [
        desc:
          is_nil(i.disconnected_at) and is_nil(c.ended_at) and k.state == :connected and
            is_nil(k.ended_at),
        desc_nulls_last: fragment("LEAST(?, ?, ?)", i.disconnected_at, c.ended_at, k.ended_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      limit: 1,
      select: %{
        key: i.key,
        title: c.title,
        public_id: i.public_id,
        item_id: i.id,
        live:
          is_nil(i.disconnected_at) and is_nil(c.ended_at) and k.state == :connected and
            is_nil(k.ended_at),
        uninstalled: k.state == :ended and k.ended_reason == :adapter_reported,
        connection_ended_at: k.ended_at
      }
  end

  @doc false
  # ticket/3 is the ticket of `work_item`, as the work item page's Ticket tab draws it,
  # to a person who may read the work item in the scope's workspace; nil otherwise. The
  # row is read again by its id, as for `explore/3`, and its ticket is the record
  # `ticket_query/0` names. It is a map of:
  #
  #   * `integration` - the title of the adapter the ticket came through, nil for a test
  #     work item, which came through none, with
  #     `item_noun` and `collection_noun`, its words (`Apiary.Adapters.item_noun/1`,
  #     `collection_noun/1`), and `adapter_removed`, whether the adapter was removed;
  #   * `uninstalled` - whether the record's connection ended because the integration was
  #     uninstalled at the source, so the record is no longer kept current, and
  #     `uninstalled_at`, when it ended, nil otherwise;
  #   * `ticket` - the record: `filer` (`%{name:}`), `filed_at`, `updated_at`, `labels`,
  #     `body`, `format`, `comment_count`, the comments it holds, not deleted at the
  #     source, and `received_at`, when an adapter last changed it; nil for a work item
  #     with no record;
  #   * `comments` - its comments, oldest first, by their time at the source, each with
  #     `public_id` (the comment's id in Qory Apiary), `author` (a name), `at`, `body`,
  #     `format` and `url` (nil for a member's comment not posted at its source); for a
  #     member's comment (`Apiary.Sources.Comment`), `comment_id`, `post_state`,
  #     `post_failure` and `author_id`, each nil for a source's comment: the latest 3 for
  #     `:latest`, every one for `:all`.
  @spec ticket(Scope.t(), WorkItem.t(), :latest | :all) :: map | nil
  def ticket(%Scope{} = scope, %WorkItem{} = work_item, comments \\ :latest)
      when comments in [:latest, :all] do
    case readable(scope, work_item) do
      {:ok, %WorkItem{test: true}} -> no_ticket()
      {:ok, row} -> ticket_of(row, comments)
      :error -> nil
    end
  end

  defp no_ticket do
    %{
      integration: nil,
      item_noun: nil,
      collection_noun: nil,
      adapter_removed: false,
      uninstalled: false,
      uninstalled_at: nil,
      ticket: nil,
      comments: []
    }
  end

  defp ticket_of(%WorkItem{} = row, comments) do
    adapter = Repo.get!(Node, row.adapter_id)

    record =
      Repo.one(
        from w in WorkItem,
          as: :work_item,
          left_lateral_join: t in subquery(ticket_query()),
          on: true,
          left_join: i in Item,
          on: i.id == t.item_id and i.organisation_id == w.organisation_id,
          where: w.id == ^row.id,
          select: {i, t.uninstalled, t.connection_ended_at}
      )

    {item, uninstalled, ended_at} = record || {nil, nil, nil}

    %{
      integration: Apiary.Adapters.title(adapter),
      item_noun: Apiary.Adapters.item_noun(adapter),
      collection_noun: Apiary.Adapters.collection_noun(adapter),
      adapter_removed: not is_nil(adapter.deleted_at),
      uninstalled: uninstalled == true,
      uninstalled_at: if(uninstalled == true, do: ended_at),
      ticket: item && ticket_record(item),
      comments: if(item, do: ticket_comments(item, comments), else: [])
    }
  end

  defp ticket_record(%Item{} = item) do
    count =
      Repo.one(
        from c in SourceComment,
          where:
            c.item_id == ^item.id and c.organisation_id == ^item.organisation_id and
              is_nil(c.deleted_at),
          select: count(c.id)
      )

    %{
      filer: %{name: item.filed_by_name},
      filed_at: item.source_created_at,
      updated_at: item.source_updated_at,
      labels: item.labels,
      body: item.body,
      format: item.body_format,
      comment_count: count,
      received_at: item.updated_at
    }
  end

  defp ticket_comments(%Item{} = item, comments) do
    from(c in SourceComment,
      where:
        c.item_id == ^item.id and c.organisation_id == ^item.organisation_id and
          is_nil(c.deleted_at),
      order_by: [desc: c.source_created_at, desc: c.inserted_at, desc: c.id],
      select: %{
        public_id: c.id,
        author: c.author_name,
        at: c.source_created_at,
        body: c.body,
        format: c.body_format,
        comment_id: c.comment_id,
        post_state: c.post_state,
        post_failure: c.post_failure,
        author_id: c.author_id,
        url: c.url
      }
    )
    |> then(fn query ->
      if comments == :latest, do: limit(query, @latest_comments), else: query
    end)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc false
  # taken_in_comment?/2 is whether the person who took `work_item` in wrote a comment
  # with this take in, for Undo's hint, to a person who may read the work items of the
  # scope's workspace; false otherwise, and for a work item of another workspace. The
  # comment is a member's comment of theirs on its ticket (`Apiary.Sources.Comment`),
  # not deleted, written in the take in's transaction (`take_in/3`, `take_in_again/3`).
  # That transaction gives the comment the take in's time, to the second, and saves it
  # after the take in's time, so the comment of an earlier take in in the same second
  # is not this one.
  @spec taken_in_comment?(Scope.t(), WorkItem.t()) :: boolean
  def taken_in_comment?(%Scope{} = scope, %WorkItem{id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, organisation_id, workspace_id} <- workspace(scope) do
      Repo.exists?(
        from w in WorkItem,
          join: c in SourceComment,
          on:
            c.organisation_id == w.organisation_id and c.item_id == w.item_id and
              c.author_id == w.taken_in_by_id and
              c.source_created_at == fragment("date_trunc('second', ?)", w.taken_in_at) and
              c.inserted_at >= w.taken_in_at and not is_nil(c.post_state) and
              is_nil(c.deleted_at),
          where:
            w.id == ^id and w.organisation_id == ^organisation_id and
              w.workspace_id == ^workspace_id
      )
    else
      _none -> false
    end
  end

  @doc false
  # backlog_off/2 is the ids of those of `work_items` whose ticket the Backlog of their
  # workspace leaves out while it is still assigned there: the ticket's live record (not
  # disconnected, its collection not ended, its connection connected) is of a collection
  # assigned to the work item's workspace that is not linked, its Backlog turned off, or
  # with no items, it or its adapter (`Apiary.Adapters.Collection.linked?/1`). So its work
  # item cannot be taken in again from there. A work item whose ticket has no live record
  # there is not among them. Only work items of the scope's workspace are read, and only
  # when the scope's person may read its work items (`work_item.read`); none otherwise.
  @spec backlog_off(Scope.t(), [WorkItem.t()]) :: MapSet.t(Ecto.UUID.t())
  def backlog_off(%Scope{} = scope, work_items) when is_list(work_items) do
    ids = for %WorkItem{id: id} when is_binary(id) <- work_items, uniq: true, do: id

    case {ids, workspace(scope)} do
      {[_ | _], {:ok, organisation_id, workspace_id}} ->
        from(w in WorkItem,
          join: i in Item,
          on:
            i.organisation_id == w.organisation_id and i.adapter_id == w.adapter_id and
              i.external_ref == w.external_ref and is_nil(i.disconnected_at),
          join: c in Collection,
          on:
            c.id == i.collection_id and c.organisation_id == i.organisation_id and
              c.workspace_id == w.workspace_id and is_nil(c.ended_at),
          join: k in Connection,
          on:
            k.id == c.connection_id and k.organisation_id == c.organisation_id and
              k.state == :connected and is_nil(k.ended_at),
          join: n in Node,
          on: n.id == c.adapter_id,
          where:
            w.id in ^ids and w.organisation_id == ^organisation_id and
              w.workspace_id == ^workspace_id,
          where: not (c.backlog and c.items and n.items),
          distinct: true,
          select: w.id
        )
        |> Repo.all()
        |> MapSet.new()

      _none ->
        MapSet.new()
    end
  end

  # The scope's organisation's id and its workspace's id, when the scope's person may read
  # the workspace's work items; `:error` otherwise.
  defp workspace(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{organisation_id: organisation_id} = workspace
         } = scope
       ) do
    if Access.can?(scope, :"work_item.read", workspace),
      do: {:ok, organisation_id, workspace.id},
      else: :error
  end

  defp workspace(%Scope{}), do: :error

  @doc false
  # stable_url/1 is the address of `work_item` that Qory gives another system: the
  # instance's public URL (`Apiary.Setup.public_url/0`, the configured one where no
  # endpoint runs, as under `bin/apiary eval`), then `/work-items/` and the work item's
  # public id. It names no organisation and no workspace, so it stays the same when the
  # work item moves to another workspace. `ApiaryWeb.WorkItemRedirectController` serves
  # it, by `locate/2`.
  @spec stable_url(WorkItem.t()) :: String.t()
  def stable_url(%WorkItem{public_id: public_id}) when is_binary(public_id),
    do: Apiary.Setup.public_url() <> "/work-items/" <> public_id

  ## Closing

  @doc false
  # close_locked/3 closes `work_items`, each held `FOR UPDATE` by the caller's
  # transaction and read under that lock, at `now`, as `closer` (the moduledoc):
  # `{:ok, workspace_ids}`, the workspaces whose queue changed; `{:error, :not_live}`,
  # writing nothing, when one of them is not live; or `{:error, changeset}` of an event
  # the database refused, after which the caller's transaction is to roll back.
  @spec close_locked([WorkItem.t()], closer, DateTime.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :not_live | Ecto.Changeset.t()}
  def close_locked(work_items, closer, %DateTime{} = now) when is_list(work_items) do
    in_transaction!("close_locked/3")
    {closed_by_id, actor_kind, actor_id, data} = actor(closer)

    if Enum.all?(work_items, &(State.next(&1.state, :close) == {:ok, :closed})) do
      ids = work_items |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()

      {count, _rows} =
        Repo.update_all(
          from(w in WorkItem, where: w.id in ^ids and w.state == :exploring),
          set: [state: :closed, closed_at: now, closed_by_id: closed_by_id, updated_at: now]
        )

      # Each one was read live under the caller's lock, so each one closes.
      unless count == length(ids),
        do: raise(ArgumentError, "close_locked/3 closes work items the caller holds")

      with :ok <- record_closes(work_items, actor_kind, actor_id, data, now) do
        Dispatches.cancel_for_close(ids, now)
      end
    else
      {:error, :not_live}
    end
  end

  @doc false
  # close_for_adapter/2 closes, as the instance, every live work item whose ticket came
  # through a connection to `adapter`, in every organisation, inside the caller's
  # transaction (the moduledoc): `{:ok, workspace_ids}`, the workspaces whose queue
  # changed, or `close_locked/3`'s error.
  @spec close_for_adapter(Node.t(), DateTime.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :not_live | Ecto.Changeset.t()}
  def close_for_adapter(%Node{kind: :adapter, id: adapter_id}, %DateTime{} = now) do
    in_transaction!("close_for_adapter/2")

    connections = from c in Connection, where: c.adapter_id == ^adapter_id, select: c.id

    work_items =
      Repo.all(
        from w in WorkItem,
          where: w.connection_id in subquery(connections),
          where: w.state == :exploring,
          order_by: w.id,
          lock: "FOR UPDATE"
      )

    case work_items do
      [] -> {:ok, []}
      _some -> close_locked(work_items, {:instance, "adapter_removed"}, now)
    end
  end

  defp actor({:person, user_id}) when is_binary(user_id),
    do: {user_id, :person, user_id, %{}}

  defp actor({:instance, reason}) when is_binary(reason),
    do: {nil, :instance, nil, %{"reason" => reason}}

  # The `:closed` event of each work item, in the workspace the work item is in, with the
  # stage Explore was at.
  defp record_closes(work_items, actor_kind, actor_id, data, now) do
    work_items
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(:ok, fn work_item, :ok ->
      stage = Explore.stage(Explore.current(work_item, now).status)
      data = Map.put(data, "stage", Atom.to_string(stage))

      %WorkItemEvent{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id
      }
      |> WorkItemEvent.changeset(%{
        kind: :closed,
        actor_kind: actor_kind,
        actor_id: actor_id,
        at: now,
        data: data
      })
      |> Repo.insert()
      |> case do
        {:ok, _event} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.WorkItems.#{what} runs inside the caller's transaction")
  end
end
