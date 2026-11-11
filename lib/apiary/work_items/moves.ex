defmodule Apiary.WorkItems.Moves do
  # Moves holds what a person does to a workspace's work items, each in one transaction
  # with its event, its run of the queue, its feed entry and its entry in the audit trail:
  # taking a ticket in, taking it in again, undoing a take in and closing; what
  # a member gives Explore: answering a run's questions, confirming a run's proposal,
  # changed or not, and running Explore again; and people's comments on the Thread,
  # writing one and deleting one.
  # `Apiary.WorkItems` names each function and what it answers; this module says how.
  #
  # ## Who may
  #
  # Each asks `Apiary.Access.authorize/3` first, inside its transaction: a take in and a
  # take in again `work_item.take_in` of the scope's workspace, where the work item will
  # be; an undo and a close `work_item.undo` and `work_item.close` of the work item, which
  # must be in the scope's workspace; an answer, a review comment, a reply to one and a
  # send of the review comments, a confirmation and a run of Explore again
  # `work_item.answer`, `work_item.review_comment` (the three of the review comments),
  # `work_item.confirm` and `work_item.explore_again` of the work item, likewise, asked
  # of the work item before its lock and again once it is locked; a comment
  # `work_item.comment` of
  # the work item, and a comment's deletion `work_item.comment_delete` of the comment, which
  # its author may take too while they may still comment (`Apiary.Access`). Each
  # writes its entry in the trail with the change (`Apiary.Audit.record/6`), about the work
  # item: a take in again with `details` `again: true`.
  #
  # ## What a take in reads
  #
  # A take in, a take in again and a test's take in hold the table of machine types
  # (`Apiary.MachineTypes.hold/0`) before they lock a row, as a save of a process does
  # (`Apiary.Processes.save/4`): a key change takes the table first, so a take in waits for
  # it and then reads the current version after it, and places its work item and run on
  # the key after. Neither waits on a row the other holds while it waits.
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
  # ## A comment at take in
  #
  # A take in and a take in again may have a comment, `comment`, under its atom key or
  # its string. Its line breaks become line feeds and it is trimmed; none, or a blank
  # one, is no comment. A comment with a character a text of several lines may not have
  # (`Apiary.Names.validate_characters/3`) is a changeset with the error on `:comment`;
  # one of more than 65,000 characters (`Apiary.Sources.Comment.max_member_body/0`) is
  # `:comment_too_long`. Both are checked after every other refusal, and before anything
  # is written. The comment is a comment on the ticket's record
  # (`Apiary.Sources.Comment.member_changeset/3`), written in the take in's transaction
  # after its feed entry: by the person, under the name members see for them, in the
  # state `Apiary.Sources.Comment.first_state/1` returns for the source: `:posting` for a
  # source that takes comments, `:kept` for any other. The ticket's comments show it, and
  # Explore's input has it. A comment `:posting` gets a `comment` entry in the adapter's
  # feed right after it is written, after the take in's `taken_in` entry, for the adapter
  # to post it on the item (`Apiary.Adapters.Feed`).
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
  # the queue (`Apiary.Dispatches`); then the adapter's feed counter
  # (`Apiary.Adapters.Feed`); then, last, the target's counter of run numbers: raised for
  # a work item that moves (`Apiary.Runs.Number.raise_past/2`), then taken by the take in's
  # first run, which a take in queues as its last step, as its run record takes the next
  # number (`Apiary.Dispatches.Queued`). A comment at take in, written
  # after the feed counter, locks the ticket's record `FOR KEY SHARE` through its key; a
  # write of the record's comments (`Apiary.Sources.Ingest`) locks the record
  # `FOR UPDATE` and waits on none of the locks above. An undo and a close take no
  # connection or collection: the work item, then its runs. An answer, a confirmation and
  # a run of Explore again take the work item alone, then queue through
  # `Apiary.Dispatches.queue_next/3`, which takes the work item again, in the same
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
  # the new work item, then the runs of the queue. An undo and a close work on
  # a test work item as on any other, and tell no adapter and no Backlog, as it has no
  # ticket.
  #
  # ## Take in again
  #
  # A take in again finds the work item of the ticket by that key: none is `:not_taken`,
  # a live one `{:error, {:taken, work_item}}`, and so is a finished one whose ticket has
  # not reopened (`Apiary.WorkItems.Finished`), which stays taken in. Any other ended one,
  # closed or undone, becomes `:exploring` again, its take in counted one more, pointed at
  # the ticket's
  # current record and its connection, with the ticket's title and address and its
  # collection's title as they are now, and the target, the owner, the first instruction,
  # who took it in and when of this take in. A work item of another workspace moves to the
  # scope's, numbered next there; its old number is never given again, and its runs stay
  # in the workspace they were queued in. Its `:taken_in` event keeps how it had ended,
  # `before` (its state, when and by whom it ended, who had taken it in and when, its
  # owner and its target), for an undo. Its first run is queued, run 1 of the new count.
  # The adapter is told `taken_in` only for one that had ended undone, whose label came
  # off; a closed one kept its label, and nothing is sent.
  #
  # ## Undo
  #
  # An undo works on a live work item while no claim holds a run of its take in
  # (`Apiary.Dispatches.cancel_for_undo/1`, `{:error, :claimed}` otherwise), and ends its
  # waiting runs. A first take in becomes `:undone`, and the adapter is told `undone`. A
  # take in again goes back to how it had ended, from its event's `before`: closed with
  # when and by whom, and its owner, its target, who had taken it in and its place in
  # its process (version, stage, state, round and entries), and
  # nothing is sent, as the label stayed; one that had ended undone becomes `:undone`
  # again, and the adapter is told `undone`, as its take in again put the label back on.
  # A work item moved by its take in again stays in the workspace it moved to, with its
  # new number, and gets no place in a process: the place it had is of the old one. An
  # event written before the place was kept leaves the place as it is. The first instruction stays the one of the take in undone: it is given to
  # no run until a take in again gives a new one.
  #
  # ## Close
  #
  # A close works on a live work item, whatever its runs (`Apiary.WorkItems.close_locked/3`).
  # Its event records the stage Explore was at (`"stage"`, `"explore"`, `"confirm"` or
  # `"shape"`, `Apiary.WorkItems.Explore.stage/1`), and nothing is sent, as the label stays.
  #
  # ## What a member gives Explore
  #
  # Each works on a live work item whose take in is still the one the page read
  # (`take_in` of the work item it is given), and on the latest run of that take in, by
  # its `attempt`, which the page names: another take in or another latest run is
  # `:stale`. Where Explore stands is read under the work item's lock
  # (`Apiary.WorkItems.Explore.current/2`): a run not ended, or one that reads as running,
  # is `:running`; at the run limit, `:used_up`; anywhere else than the step's place,
  # `:not_waiting`. A newest version of the questions or the review comments whose file
  # cannot be read, or a store that cannot keep the member's version, is
  # `:store_unavailable`, and nothing is written. Each writes its event and its entry in
  # the trail, and marks the work item changed (`updated_at`); none sends a feed entry, as
  # the label stays.
  #
  #   * An answer (`answer/4`) works where the latest run's questions wait. It answers one
  #     or more open questions of the work item's newest questions, and only questions
  #     that a run of the take in asked at the stage the work item is in, by the run's
  #     `stage_id` (`Apiary.Explore.Questions.open_in_take_in/2`). The answers come by
  #     position (`Apiary.WorkItems.Proposal.check_answers/2`, else `{:invalid, errors}`,
  #     by position, or `{:invalid, :form}`). A form may give the answers by question id
  #     instead, a list (`Apiary.WorkItems.Proposal.check_answers_by_id/2`, else
  #     `{:invalid, errors}`, by id, or `{:invalid, :form}`), where an answer may have an
  #     option and a note together. An answer by id to a question left open in an earlier
  #     take in, or to an open or decided question of another stage's runs, returns
  #     `{:invalid, %{id => :not_open}}`, as for a question that is not open. It writes a
  #     new version of the questions, by the member, with those answers
  #     (`Apiary.Explore.Questions.answer/4`): an option's title as the answer's
  #     `option`, the member's text as its `note` with `option` null; the others
  #     stay open. It queues the take in's next run at any count of runs: at the run limit
  #     the next run's `attempt` and `of` are one more each
  #     (`Apiary.Dispatches.queue_next/3`). Its event, `:answered`, has the take in, the
  #     attempt answered, the count and the ids of the questions answered (`"questions"`).
  #   * `review_comment/4` writes one review comment and queues no run. No page calls
  #     it: Explore's tab writes a comment with `another_round/4`, and tests call it to
  #     set up a work item. It works wherever no run is running and the take in has a
  #     proposal: where its questions wait, where its proposal waits, and after a run
  #     that gave no result, was lost or was cancelled. It asks
  #     `work_item.review_comment` (`Apiary.Access`, else `:not_approver`), which only
  #     the approvers of the stage the work item is in have, where the stage lists them,
  #     and checks the text (`Apiary.WorkItems.Proposal.check_comment/1`, else
  #     `{:invalid, %{comment: error}}`, or `{:invalid, :form}`). It writes a new version
  #     of the review comments, by the scope's person, with the review comment, open, on
  #     the newest version of the take in's proposal
  #     (`Apiary.WorkItems.Explore.proposal_version/3`,
  #     `Apiary.Explore.ReviewComments.comment/5`); with none, `:not_waiting`. Its event,
  #     `:answered`, has the take in, the attempt of the latest run, the count, 1,
  #     `"comment"` true and the review comment's id (`"review_comment"`).
  #   * A reply and a send work at the gate of a stage after Explore's too
  #     (`Apiary.WorkItems.Explore.member_view/2`). An answer and a send work wherever the
  #     stage waits for answers, after a confirmation too.
  #   * A reply to a review comment (`reply/5`) works under the same rule: it adds the
  #     member's reply to the review comment, which opens it again
  #     (`Apiary.Explore.ReviewComments.reply/5`). An id the review comments do not have,
  #     or the id of a review comment of another stage or of an earlier take in, is
  #     `:not_found`: a reply goes only to a review comment on a version that a run of the
  #     take in at the stage of Run another round pushed
  #     (`Apiary.WorkItems.Explore.versions/3`), or on the round of such a run, open or
  #     closed. It queues no run. Its event,
  #     `:answered`, has what a review comment's has, and `"reply"`, the reply's position
  #     among the review comment's replies, from 1.
  #   * The open review comments go to the next run with the answers (`answer/4`), which
  #     queues it, or with `send_review_comments/3`. No page calls
  #     `send_review_comments/3`: Explore's tab sends them with `another_round/4`, and
  #     tests call it to set up a work item. Where the latest run's questions or its
  #     proposal wait, for a scope among the stage's approvers, with at least one review
  #     comment open on a proposal of the take in (else `:not_waiting`; one left open in
  #     an earlier take in does not count), it queues the take in's next run as an
  #     answer does, at any count of runs. It writes
  #     nothing to the questions, whose open questions stay open. Its event, `:answered`,
  #     has the take in, the attempt, the count and the ids of the open review comments
  #     (`"review_comments"`).
  #   * Run another round (`another_round/4`) sends, in one move, what a member drafted on
  #     Explore's tab, where the latest run's questions or its proposal wait: the answers
  #     to the open questions (only where the questions wait) and to the decided questions
  #     of the take in, as an answer by question id gives them, and a comment on the whole
  #     proposal, written as a review comment is, open, on the newest version of the take
  #     in's proposal. It queues the take in's next run, once, at any count of runs; that
  #     run reads the answers, the comment and every other open review comment, as it
  #     reads them after an answer. It asks `work_item.answer` where answers are given,
  #     and `work_item.review_comment` for a comment, or where nothing else is given, for
  #     the open review comments alone (else `:not_approver`). With the workflow model
  #     on, an answer, a send of the review comments, Run another round and Explore
  #     again ask `gate.approve` too where the round resolves an open escalation, or runs
  #     a stage after Explore's again from its gate, and are `:not_waiting` from
  #     Explore's proposal while a later stage waits for its inputs or its workflow
  #     (`Apiary.Stages.member_round/3`, called by `Apiary.WorkItems`). A round with no answer
  #     left, once the answers that repeat a decision's option are dropped, counts as a
  #     round with no answers. With no answer, no comment and no review comment open on a
  #     proposal of the take in, it is `:not_waiting`. An answer to a decided question
  #     changes the run's decision: the question becomes answered and keeps its
  #     `decision`. An answer that is the decision's option again, with no note, changes
  #     nothing and is not written (`Apiary.Explore.Questions.same_as_decision?/3`);
  #     `answer/4` with only such answers is `:not_waiting`. Its event, `:answered`, has
  #     the take in, the attempt and the count, and: with answers, the ids of the
  #     questions answered (`"questions"`) and the comment's id (`"review_comment"`) where
  #     one is written; without answers, what a send of the review comments has, the
  #     comment among them, and with a comment, `"comment"` true and its id
  #     (`"review_comment"`), as a review comment's event has them. Unanswered questions
  #     stay open.
  #   * Run another round works at the stage the work item is in. It reads where that
  #     stage stands (`Apiary.WorkItems.Explore.member_view/2`), and opens where Explore's
  #     opens: the stage waits for answers, its proposal waits, or a stage after Explore's
  #     waits at its gate. An escalated stage takes the escalation's Run another round
  #     (`Apiary.Stages`), at Explore as at any other stage. The answers, the decided
  #     questions and the open review comments are those of the runs of the take in at
  #     that stage, by the run's `stage_id`, Explore's where its proposal waits. An answer
  #     to another stage's question returns `{:error, {:invalid, %{id => :not_open}}}`, as
  #     for a question that is not open. At Explore the open review comments are those on
  #     a proposal. Its comment is on the whole round,
  #     `on: {"run": N}`, N the number of the newest run of the take in at that stage, at
  #     Explore as at a later stage; a review comment on one output (`review_comment/4`)
  #     and today's form at the gate keep `on` an artifact version. A round comment left
  #     open goes with the next round at the stage of its run. The run it queues is the
  #     stage's next run (`Apiary.Stages.next_run/2`), with that stage and its workflow.
  #   * Today's form for a comment on the proposal (`answer/4` with a text, where the
  #     latest run's proposal waits) writes the review comment and sends the review
  #     comments, in one move: one event, as a review comment's, and the next run queued.
  #     It asks `work_item.answer`, then `work_item.review_comment` once it finds the
  #     proposal waiting.
  #   * A confirmation (`confirm/3`) works where the latest run's proposal waits, for a
  #     member among the approvers of the stage the work item is in, where the stage lists
  #     them (`work_item.confirm`, `Apiary.Access`, else `:not_approver`), and, with the
  #     workflow model on, while the stage is not escalated (else `:not_waiting`). It
  #     keeps the proposal's version (`Apiary.WorkItems.Confirmation`); the work item is
  #     then ready for Shape. Its event, `:confirmed`, has the take in and the attempt.
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
  # and its deletion tell the work items' topic alone: the Backlog shows no comment. A
  # move that `Apiary.WorkItems` runs inside the stage runner's transaction
  # (`Apiary.Stages.member_round/3`) is told again once that transaction commits
  # (`tell/1`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Dispatches, MachineTypes, Names, Organisations, PublicId}
  alias Apiary.{Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection, Feed}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Number, as: RunNumber
  alias Apiary.Runs.Run
  alias Apiary.Sources.{Item, Topic}
  alias Apiary.Sources.Comment, as: SourceComment
  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.WorkItems.{Comment, Confirmation, Explore, Finished, Number, Proposal}
  alias Apiary.WorkItems.{State, WorkItem}
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
          | :comment_too_long
          | {:taken, WorkItem.t()}
          | Ecto.Changeset.t()

  @typedoc """
  What the page sends with a take in: the owner, the first instruction and a comment on the
  ticket, under atom keys or their strings.
  """
  @type take_in_attrs :: %{
          optional(:owner_id | String.t()) => Ecto.UUID.t(),
          optional(:first_instruction | String.t()) => String.t(),
          optional(:comment | String.t()) => String.t()
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
             :ok <- MachineTypes.hold(),
             {:ok, ticket} <- hold_ticket(scope, workspace, item_id),
             :ok <- none_yet(scope, ticket),
             :ok <- open(ticket),
             {:ok, target} <- target(workspace, ticket),
             {:ok, owner_id} <- owner(scope, attrs),
             {:ok, comment} <- take_in_comment(attrs) do
          make(scope, workspace, ticket, target, owner_id, attrs, comment)
        end
      end)

    case result do
      {:ok, {work_item, told}} ->
        tell_told(told)
        {:ok, work_item}

      {:error, {:raced, ticket}} ->
        {:error, {:taken, WorkItems.as_seen(scope, by_key(ticket, false))}}

      {:error, _refusal} = refused ->
        refused
    end
  end

  # A new work item of the ticket, its event, its first run, its feed entry and its entry
  # in the trail.
  defp make(scope, workspace, ticket, target, owner_id, attrs, comment) do
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
         {:ok, _seq} <- feed(adapter, work_item, "taken_in"),
         :ok <- write_comment(scope, ticket, comment, now),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             after: %{state: :exploring},
             details: %{"take_in" => 1}
           }),
         {:ok, _run} <- Dispatches.queue(work_item, 1) do
      {:ok,
       {work_item,
        %{
          work_items: [{work_item.workspace_id, work_item.public_id}],
          tickets: [{collection.workspace_id, item.public_id}],
          queues: [work_item.workspace_id]
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
             :ok <- MachineTypes.hold(),
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
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             after: %{state: :exploring},
             details: %{"take_in" => 1, "test" => true}
           }),
         {:ok, _run} <- Dispatches.queue(work_item, 1) do
      {:ok,
       {work_item,
        %{
          work_items: [{work_item.workspace_id, work_item.public_id}],
          tickets: [],
          queues: [work_item.workspace_id]
        }}}
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
             :ok <- MachineTypes.hold(),
             {:ok, ticket} <- hold_ticket(scope, workspace, item_id),
             {:ok, ended} <- ended(scope, ticket),
             :ok <- open(ticket),
             :ok <- not_finished(scope, ended, ticket),
             {:ok, target} <- target(workspace, ticket),
             {:ok, owner_id} <- owner(scope, attrs),
             {:ok, comment} <- take_in_comment(attrs) do
          again(scope, workspace, ended, ticket, target, owner_id, attrs, comment)
        end
      end)

    case result do
      {:ok, {work_item, told}} ->
        tell_told(told)
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

  # A finished work item stays taken in until its ticket reopens, as the person sees it
  # (`Apiary.WorkItems.as_seen/2`).
  defp not_finished(scope, ended, %{item: item}) do
    if Finished.finished?(ended, item),
      do: {:error, {:taken, WorkItems.as_seen(scope, ended)}},
      else: :ok
  end

  defp again(scope, workspace, ended, ticket, target, owner_id, attrs, comment) do
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
         {:ok, _seq} <- feed_if(ended.state == :undone, adapter, work_item, "taken_in"),
         :ok <- write_comment(scope, ticket, comment, now),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"work_item.take_in", work_item, %{
             before: %{state: ended.state},
             after: %{state: :exploring},
             details: %{"again" => true, "take_in" => take_in}
           }),
         :ok <- raise_run_numbers(ended, workspace),
         {:ok, _run} <- Dispatches.queue(work_item, take_in) do
      {:ok,
       {work_item,
        %{
          work_items:
            Enum.uniq([
              {work_item.workspace_id, work_item.public_id},
              {ended.workspace_id, work_item.public_id}
            ]),
          tickets: [{collection.workspace_id, item.public_id}],
          queues: [work_item.workspace_id]
        }}}
    end
  end

  # A work item of another workspace moves to the scope's, numbered next there, right
  # after the work item is held. It leaves its place in the other workspace's process:
  # it runs under the current version of the scope's workspace
  # (`Apiary.Processes.version_for/1`).
  defp move(changeset, %WorkItem{workspace_id: workspace_id}, %Workspace{id: workspace_id}),
    do: changeset

  defp move(changeset, _ended, %Workspace{} = workspace),
    do:
      Ecto.Changeset.change(changeset,
        workspace_id: workspace.id,
        number: Number.next(workspace),
        process_version_id: nil,
        stage_id: nil,
        stage_state: nil,
        stage_round: nil,
        stage_entry: nil,
        loop_entry: nil
      )

  # The last step of a move: the next run of the work item takes a number above each run
  # it has in other workspaces (`Apiary.Runs.Number.raise_past/2`).
  defp raise_run_numbers(%WorkItem{workspace_id: workspace_id}, %Workspace{id: workspace_id}),
    do: :ok

  defp raise_run_numbers(%WorkItem{id: id}, %Workspace{} = workspace),
    do: RunNumber.raise_past(workspace, id)

  # How `work_item` had ended, for the undo of the take in again that leaves it: its
  # place in its workspace's process among the rest.
  defp before(%WorkItem{} = work_item) do
    {at, by_id} =
      case work_item.state do
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
      "target_path" => work_item.target_path,
      "workspace_id" => work_item.workspace_id,
      "process_version_id" => work_item.process_version_id,
      "stage_id" => work_item.stage_id,
      "stage_state" => work_item.stage_state && Atom.to_string(work_item.stage_state),
      "stage_round" => work_item.stage_round,
      "stage_entry" => work_item.stage_entry,
      "loop_entry" => work_item.loop_entry
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

    # The runs the undo ended while they waited have run records (`Apiary.Dispatches.Queued`):
    # the workspace's queue is told once the undo commits, so the Runs list reads them again.
    with {:ok, work_item} <- finish(result) do
      Dispatches.broadcast([work_item.workspace_id])
      {:ok, work_item}
    end
  end

  defp undone(scope, held) do
    now = DateTime.utc_now()
    before = before_of(held)
    {:ok, state} = State.next(:exploring, :undo, before && before.state)

    changes =
      case before do
        %{state: :closed} ->
          [state: state, closed_at: before.at, closed_by_id: before.by_id] ++
            taken_in_fields(before) ++ stage_fields(before, held)

        %{state: :undone} ->
          [state: state] ++ taken_in_fields(before) ++ stage_fields(before, held)

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
      when state in ["closed", "undone"] ->
        %{
          state: String.to_existing_atom(state),
          at: time(before["at"]),
          by_id: before["by_id"],
          taken_in_by_id: before["taken_in_by_id"],
          taken_in_at: time(before["taken_in_at"]),
          owner_id: before["owner_id"],
          target_system: before["target_system"],
          target_path: before["target_path"],
          stage: stage_before(before)
        }

      _first ->
        nil
    end
  end

  # The work item's place in its process as its take in again found it, and the
  # workspace it was in; nil for an event written before the place was kept.
  defp stage_before(%{"stage_id" => _id, "workspace_id" => workspace_id} = before) do
    %{
      workspace_id: workspace_id,
      process_version_id: before["process_version_id"],
      stage_id: before["stage_id"],
      stage_state: before["stage_state"] && String.to_existing_atom(before["stage_state"]),
      stage_round: before["stage_round"],
      stage_entry: before["stage_entry"],
      loop_entry: before["loop_entry"]
    }
  end

  defp stage_before(_before), do: nil

  # The place an undo puts back. An event without it changes nothing. A work item its take
  # in again moved to another workspace gets no place, as the place is of the old process.
  defp stage_fields(%{stage: %{workspace_id: workspace_id} = stage}, %WorkItem{
         workspace_id: workspace_id
       }),
       do: stage |> Map.delete(:workspace_id) |> Map.to_list()

  defp stage_fields(%{stage: %{} = stage}, _held),
    do: for({field, _value} <- Map.delete(stage, :workspace_id), do: {field, nil})

  defp stage_fields(_before, _held), do: []

  defp time(nil), do: nil

  defp time(text) when is_binary(text) do
    {:ok, at} = Ecto.Type.cast(:utc_datetime_usec, text)
    at
  end

  defp taken_in_fields(before) do
    [
      taken_in_by_id: before.taken_in_by_id,
      taken_in_at: before.taken_in_at,
      owner_id: before.owner_id,
      target_system: before.target_system,
      target_path: before.target_path
    ]
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

  @typedoc "Why an answer, a comment, a confirmation or a run of Explore again is refused."
  @type step_refusal ::
          :not_found
          | :forbidden
          | :not_live
          | :stale
          | :running
          | :used_up
          | :not_waiting
          | :not_approver
          | :store_unavailable
          | {:invalid, map | :form}
          | Ecto.Changeset.t()

  @typedoc "An answer by question id (`Apiary.WorkItems.Proposal.check_answers_by_id/2`)."
  @type answer_by_id :: %{required(String.t()) => String.t() | nil}

  # The places where no run is running, so a member may write review comments.
  @no_run [:questions, :confirm, :no_result, :lost, :cancelled, :used_up]
  # The same on a reply: the gate of a stage after Explore's too
  # (`Apiary.WorkItems.Explore.member_view/2`).
  @no_run_at_stage [:gate | @no_run]

  # A member's name in the questions and the review comments: at most 160 characters,
  # with none of the white space and the characters `$defs/line` refuses
  # (`priv/schemas/artifacts/questions.schema.json`), each run of them made one space.
  @member_name 160
  # A member's name in the questions and the review comments when nothing of it is left
  # for one line (`person_name/1`).
  @unnamed_member "unnamed member"
  @not_in_line ~r/[\s\x{0}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]+/u

  # answer/4 gives the answers to the open questions, or, with a text where the latest
  # run's proposal waits, a review comment sent at once (the moduledoc).
  @doc false
  @spec answer(Scope.t(), WorkItem.t(), pos_integer, map | String.t() | [answer_by_id]) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def answer(%Scope{} = scope, %WorkItem{} = work_item, attempt, answers) do
    step(scope, :"work_item.answer", work_item, fn held, current, now ->
      current = Explore.member_view(current, held)

      with :ok <- waiting(current, [:questions, :confirm], attempt),
           {:ok, count, given} when count > 0 <- keep_given(held, scope, current, answers, now) do
        {:ok, Map.merge(answered(held, attempt, count), given), true}
      else
        # Each answer was the option of a run's decision again: nothing to send.
        {:ok, 0, _given} -> {:error, :not_waiting}
        refused -> refused
      end
    end)
  end

  # review_comment/4 writes the scope's member's review comment `text` on the newest
  # proposal of the work item's take in, whose latest run is `attempt`, and queues no run
  # (the moduledoc).
  @doc false
  @spec review_comment(Scope.t(), WorkItem.t(), pos_integer, term) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def review_comment(%Scope{} = scope, %WorkItem{} = work_item, attempt, text) do
    step(scope, :"work_item.review_comment", work_item, fn held, current, now ->
      with :ok <- waiting(current, @no_run, attempt),
           {:ok, text} <- comment_text(text),
           {:ok, id} <- keep_comment(held, scope, current, "proposal", text, now),
           do: {:ok, comment_data(held, attempt, id), false}
    end)
  end

  # reply/5 adds the scope's member's reply `text` to the review comment `id`, which opens
  # it again, and queues no run (the moduledoc).
  @doc false
  @spec reply(Scope.t(), WorkItem.t(), pos_integer, String.t(), term) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def reply(%Scope{} = scope, %WorkItem{} = work_item, attempt, id, text) when is_binary(id) do
    step(scope, :"work_item.review_comment", work_item, fn held, current, now ->
      current = Explore.member_view(current, held)

      with :ok <- waiting(current, @no_run_at_stage, attempt),
           {:ok, text} <- comment_text(text),
           {:ok, position} <- keep_reply(held, scope, round_stage(held, current), id, text, now),
           do: {:ok, Map.put(comment_data(held, attempt, id), "reply", position), false}
    end)
  end

  # send_review_comments/3 queues the take in's next run, which reads the open review
  # comments, where the questions or the proposal of the latest run, `attempt`, wait, or
  # at the gate of a stage after Explore's (the moduledoc).
  @doc false
  @spec send_review_comments(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def send_review_comments(%Scope{} = scope, %WorkItem{} = work_item, attempt) do
    step(scope, :"work_item.review_comment", work_item, fn held, current, _now ->
      with :ok <-
             waiting(Explore.member_view(current, held), [:gate, :questions, :confirm], attempt),
           {:ok, [_ | _] = ids} <- open_review_comments(held) do
        data =
          held
          |> answered(attempt, length(ids))
          |> Map.put("review_comments", ids)

        {:ok, data, true}
      else
        {:ok, []} -> {:error, :not_waiting}
        refused -> refused
      end
    end)
  end

  @typedoc "What Run another round sends: the answers by question id and the comment."
  @type round :: %{
          optional(:answers) => [answer_by_id],
          optional(:comment) => String.t() | nil
        }

  # another_round/4 queues the take in's next run with the answers and the comment of
  # `round`, and the open review comments, in one move (the moduledoc).
  @doc false
  @spec another_round(Scope.t(), WorkItem.t(), pos_integer, round) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def another_round(%Scope{} = scope, %WorkItem{} = work_item, attempt, %{} = round) do
    answers = Map.get(round, :answers) || []
    comment = Map.get(round, :comment)
    action = if answers == [], do: :"work_item.review_comment", else: :"work_item.answer"

    step(scope, action, work_item, fn held, current, now ->
      current = Explore.member_view(current, held)
      stage = round_stage(held, current)

      with :ok <- waiting(current, [:questions, :confirm, :gate], attempt),
           {:ok, count, given} <- round_answers(held, scope, current, stage, answers, now),
           :ok <- no_answer_left(scope, held, count),
           {:ok, id} <- round_comment(held, scope, stage, comment, now) do
        round_data(held, attempt, count, given, id, stage)
      end
    end)
  end

  # The stage a round is at, `{stage_id, explore?}`: Explore's where its proposal waits,
  # wherever a gate `none` left the work item, else the work item's stage, and whether it
  # is Explore's. A run with no stage is Explore's. The stage is nil for a work item with
  # no stage, or with no Explore stage in its process: every run of the take in counts.
  defp round_stage(%WorkItem{stage_id: nil}, _current), do: {nil, true}

  defp round_stage(held, %{status: :confirm}),
    do: {Apiary.Stages.explore_stage_id(held), true}

  defp round_stage(held, _current),
    do: {held.stage_id, held.stage_id == Apiary.Stages.explore_stage_id(held)}

  defp round_answers(_held, _scope, _current, _stage, [], _now), do: {:ok, 0, %{}}

  # Where the proposal or a stage's outputs wait, the answers change the decisions of the
  # runs of the round's stage: a decided question does not hold the stage back.
  defp round_answers(held, scope, %{status: status}, stage, answers, now)
       when status in [:questions, :confirm, :gate] and is_list(answers),
       do: keep_by_id(held, scope, answers, now, round_runs(held, stage))

  defp round_answers(_held, _scope, _current, _stage, _answers, _now),
    do: {:error, :not_waiting}

  # The numbers of the registered runs of the take in at the round's stage `stage`.
  defp round_runs(held, {stage_id, explore?}) do
    Repo.all(
      from r in Run,
        join: d in DispatchRun,
        as: :dispatch,
        on: d.id == r.dispatch_run_id,
        where: d.work_item_id == ^held.id and d.take_in == ^held.take_in,
        where: ^Explore.at_stage(stage_id, explore?),
        select: r.number
    )
    |> MapSet.new()
  end

  # A round with no answer left, such as one whose answers were all a decision's option
  # again, is a round with no answers: it sends the comment or the open review comments,
  # so it asks `work_item.review_comment`, as `step/4` asks it of a round with none.
  defp no_answer_left(scope, held, 0),
    do: Access.authorize(scope, :"work_item.review_comment", held)

  defp no_answer_left(_scope, _held, _count), do: :ok

  defp round_comment(_held, _scope, _stage, nil, _now), do: {:ok, nil}

  # The comment of Run another round is on the whole round, not on one output: on the
  # newest run of the take in at the round's stage (`{"run": N}`, N its number).
  defp round_comment(held, scope, stage, text, now) do
    with :ok <- Access.authorize(scope, :"work_item.review_comment", held),
         {:ok, text} <- comment_text(text),
         number when is_integer(number) <- newest_run(held, stage) || {:error, :not_waiting},
         do: write_review_comment(held, scope, %{"run" => number}, text, now)
  end

  # The number of the newest registered run of the take in at the round's stage `stage`,
  # nil for none.
  defp newest_run(held, {stage_id, explore?}) do
    Repo.one(
      from r in Run,
        join: d in DispatchRun,
        as: :dispatch,
        on: d.id == r.dispatch_run_id,
        where: d.work_item_id == ^held.id and d.take_in == ^held.take_in,
        where: ^Explore.at_stage(stage_id, explore?),
        order_by: [desc: d.attempt],
        limit: 1,
        select: r.number
    )
  end

  # The event's data of Run another round, and the next run queued: with no answer, the
  # open review comments, the comment among them, as a send of them, and the comment as
  # a review comment's event has it.
  defp round_data(held, attempt, 0, _given, nil, stage) do
    case round_comments(held, stage) do
      {:ok, [_ | _] = ids} ->
        {:ok, Map.put(answered(held, attempt, length(ids)), "review_comments", ids), true}

      {:ok, []} ->
        {:error, :not_waiting}

      refused ->
        refused
    end
  end

  defp round_data(held, attempt, 0, _given, id, stage) do
    with {:ok, ids} <- round_comments(held, stage) do
      data = Map.merge(comment_data(held, attempt, id), %{"count" => length(ids)})
      {:ok, Map.put(data, "review_comments", ids), true}
    end
  end

  defp round_data(held, attempt, count, given, id, _stage) do
    data = Map.merge(answered(held, attempt, count), given)
    {:ok, if(id, do: Map.put(data, "review_comment", id), else: data), true}
  end

  # The ids of the open review comments a round carries, in order: those on a version
  # that a run of the take in at the round's stage `stage` pushed, at Explore's only
  # those on a proposal, and those on the round of a run of the take in at that stage.
  defp round_comments(held, {_stage_id, explore?} = stage) do
    versions = Explore.versions(held.id, held.take_in, stage)

    open_on(
      held,
      if(explore?, do: MapSet.filter(versions, &(elem(&1, 0) == "proposal")), else: versions),
      round_runs(held, stage)
    )
  end

  # One move of what a member gives Explore, in one transaction under the work item's
  # lock, asked `action` (`hold_step/4`): `give` checks and writes, and returns the
  # event's data and whether the take in's next run is queued. Every move writes the entry
  # `work_item.answer` in the trail, whichever action it asks.
  defp step(scope, action, work_item, give) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held, current} <- hold_step(scope, action, work_item, now),
             {:ok, data, queue?} <- give.(held, current, now),
             :ok <- event(held, :answered, scope, now, data),
             {:ok, _run} <- if(queue?, do: next_run(held, true), else: {:ok, nil}),
             {:ok, work_item} <- touch(held, now),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"work_item.answer", work_item, %{details: data}) do
          {:ok, {work_item, told(work_item)}}
        end
      end)

    finish(result)
  end

  # The data of an `:answered` event, and of its entry in the trail.
  defp answered(held, attempt, count),
    do: %{"take_in" => held.take_in, "attempt" => attempt, "count" => count}

  defp comment_data(held, attempt, id),
    do: Map.merge(answered(held, attempt, 1), %{"comment" => true, "review_comment" => id})

  # What the member gave, kept: the answers to the open questions, or a review comment on
  # the proposal. `{:ok, count, data}`, `data` what the event adds: the ids of the
  # questions answered, or the review comment's id and `"comment"` true.
  # The answers are checked against the runs of the take in at the current stage
  # (`round_stage/2`), so an answer at a later stage leaves Explore's questions as they are.
  defp keep_given(held, scope, %{status: :questions} = current, answers, now)
       when is_list(answers),
       do: keep_by_id(held, scope, answers, now, round_runs(held, round_stage(held, current)))

  defp keep_given(held, scope, %{status: :questions} = current, answers, now) do
    with {:ok, document} <- questions(held),
         open = open_at_stage(document, round_runs(held, round_stage(held, current))),
         questions = Enum.map(open, &Proposal.question/1),
         {:ok, checked} <- invalid(Proposal.check_answers(questions, answers)),
         given = Enum.map(checked, &option_note(&1, open)),
         {:ok, document} <-
           noted(Questions.answer(document, given, person_name(scope), now), open),
         {:ok, _version} <- push(held, scope, Questions.type_name(), Questions.file(document)) do
      {:ok, length(given), %{"questions" => Enum.map(given, &elem(&1, 0))}}
    end
  end

  defp keep_given(held, scope, %{status: :confirm} = current, text, now) do
    with :ok <- Access.authorize(scope, :"work_item.review_comment", held),
         {:ok, text} <- comment_text(text),
         {:ok, id} <- keep_comment(held, scope, current, "proposal", text, now),
         do: {:ok, 1, %{"comment" => true, "review_comment" => id}}
  end

  # The answers by question id, kept, to the open and the decided questions of the runs
  # `runs`, the numbers of registered runs. An answer that is the option of a run's
  # decision again, with no note, changes nothing and is not written
  # (`Apiary.Explore.Questions.same_as_decision?/3`); with no answer left, nothing is
  # written and the count is 0.
  defp keep_by_id(held, scope, answers, now, runs) do
    with {:ok, document} <- questions(held),
         {:ok, checked} <-
           invalid(Proposal.check_answers_by_id(answerable(document, runs), answers)) do
      given =
        Enum.reject(checked, fn {id, option, note} ->
          Questions.same_as_decision?(Questions.entry(document, id), option, note)
        end)

      write_by_id(held, scope, document, given, now)
    end
  end

  defp write_by_id(_held, _scope, _document, [], _now), do: {:ok, 0, %{}}

  defp write_by_id(held, scope, document, given, now) do
    with {:ok, document} <-
           noted_by_id(Questions.answer(document, given, person_name(scope), now)),
         {:ok, _version} <- push(held, scope, Questions.type_name(), Questions.file(document)) do
      {:ok, length(given), %{"questions" => Enum.map(given, &elem(&1, 0))}}
    end
  end

  # A new version of the review comments with the member's review comment on the newest
  # version of `type` of the take in: `{:ok, id}`.
  defp keep_comment(held, scope, current, type, text, now) do
    with version when is_integer(version) <-
           Explore.version(held.id, held.take_in, current.step.attempt, type) ||
             {:error, :not_waiting},
         do:
           write_review_comment(
             held,
             scope,
             %{"artifact" => type, "version" => version},
             text,
             now
           )
  end

  # A new version of the review comments with the member's review comment on `on`, one
  # output or the round of a run: `{:ok, id}`.
  defp write_review_comment(held, scope, on, text, now) do
    with {:ok, earlier} <- review_comments(held),
         {id, document} = ReviewComments.comment(earlier, on, text, person_name(scope), now),
         {:ok, _version} <-
           push(held, scope, ReviewComments.type_name(), ReviewComments.file(document)) do
      {:ok, id}
    end
  end

  # The open questions of the newest questions that the runs `runs` asked, in order
  # (`Apiary.Explore.Questions.open_in_take_in/2`): the questions a member may answer.
  # One left open in an earlier take in, or by another stage's runs, is not among them.
  defp open_at_stage(document, runs), do: Questions.open_in_take_in(document, runs)

  # The questions an answer by id is checked against: the questions of the document, with
  # each open or decided question that no run of `runs` asked, one of an earlier take in
  # or of another stage's runs, as one that is not open. An answer to such a question
  # returns `{:error, {:invalid, %{id => :not_open}}}`, as for a question that is not open.
  defp answerable(document, runs) do
    ids = document |> Questions.answerable_in_take_in(runs) |> MapSet.new(& &1["id"])

    Enum.map(document["questions"], fn
      %{"state" => state, "id" => id} = question when state in ["open", "decided"] ->
        if MapSet.member?(ids, id), do: question, else: Map.put(question, "state", "earlier")

      question ->
        question
    end)
  end

  # Today's form gives each answer as an option's title or the member's text
  # (`Apiary.WorkItems.Proposal.check_answers/2`): a title is the answer's `option`, with
  # no note; the member's text is its `note`, with `option` null.
  defp option_note({position, _question, text, false}, open),
    do: {Enum.at(open, position - 1)["id"], text, nil}

  defp option_note({position, _question, text, true}, open),
    do: {Enum.at(open, position - 1)["id"], nil, text}

  # An answer with no option and no note, by its position on the form.
  defp noted({:ok, document}, _open), do: {:ok, document}

  defp noted({:error, {:note_required, id}}, open) do
    position = Enum.find_index(open, &(&1["id"] == id)) + 1
    {:error, {:invalid, %{Integer.to_string(position) => :blank}}}
  end

  defp noted_by_id({:ok, document}), do: {:ok, document}

  defp noted_by_id({:error, {:note_required, id}}),
    do: {:error, {:invalid, %{id => :note_required}}}

  # The newest questions: none is `:not_waiting`, and a version that cannot be read
  # `:store_unavailable`.
  defp questions(held) do
    case Questions.current(held) do
      {:ok, {_version, document}} -> {:ok, document}
      {:ok, nil} -> {:error, :not_waiting}
      {:error, :store_unavailable} = error -> error
    end
  end

  # A new version of the review comments with the member's reply: `{:ok, position}`, the
  # reply's position among the review comment's replies.
  defp keep_reply(held, scope, stage, id, text, now) do
    with {:ok, earlier} <- review_comments(held),
         :ok <- of_stage(held, stage, earlier, id),
         {:ok, document} <-
           found(ReviewComments.reply(earlier, id, text, person_name(scope), now)),
         {:ok, _version} <-
           push(held, scope, ReviewComments.type_name(), ReviewComments.file(document)) do
      entry = Enum.find(ReviewComments.entries(document), &(&1["id"] == id))
      {:ok, length(entry["replies"])}
    end
  end

  # `:ok` where the review comment `id`, open or closed, is on a version that a run of the
  # work item's take in at the round's stage `stage` pushed, or on the round of such a
  # run; else `:not_found`, as for an id the review comments do not have.
  defp of_stage(held, stage, document, id) do
    case Enum.find(ReviewComments.entries(document), &(&1["id"] == id)) do
      %{"on" => %{"run" => run}} ->
        if MapSet.member?(round_runs(held, stage), run),
          do: :ok,
          else: {:error, :not_found}

      %{"on" => %{"artifact" => type, "version" => version}} ->
        if MapSet.member?(Explore.versions(held.id, held.take_in, stage), {type, version}),
          do: :ok,
          else: {:error, :not_found}

      _none ->
        {:error, :not_found}
    end
  end

  defp found(:error), do: {:error, :not_found}
  defp found(ok), do: ok

  # The newest review comments, `{:ok, nil}` for none; a version that cannot be read is
  # `:store_unavailable`, so a member's write never starts from no review comments and
  # drops the others.
  defp review_comments(held) do
    case ReviewComments.current(held) do
      {:ok, {_version, document}} -> {:ok, document}
      {:ok, nil} -> {:ok, nil}
      {:error, :store_unavailable} = error -> error
    end
  end

  # The ids of the open review comments of the newest version that are on a version of
  # the work item's take in, in order. A review comment left open in an earlier take in
  # is on a version of that take in, and does not count.
  defp open_review_comments(held),
    do: open_on(held, Explore.versions(held.id, held.take_in), MapSet.new())

  # The ids of the open review comments of the newest version that are on one of
  # `versions`, each a type and a number, or on the round of one of `runs`, run numbers,
  # in order.
  defp open_on(held, versions, runs) do
    with {:ok, document} <- review_comments(held) do
      {:ok,
       for(
         %{"state" => "open", "id" => id, "on" => on} <- ReviewComments.entries(document),
         on_one_of?(on, versions, runs),
         do: id
       )}
    end
  end

  defp on_one_of?(%{"run" => run}, _versions, runs), do: MapSet.member?(runs, run)

  defp on_one_of?(%{"artifact" => type, "version" => version}, versions, _runs),
    do: MapSet.member?(versions, {type, version})

  defp on_one_of?(_on, _versions, _runs), do: false

  # A new version of the work item's artifact of `type`, written by the member in the
  # work item's stage, inside the move's transaction: a member action
  # (`Apiary.Artifacts.push/5`), the one way a person writes the questions or the review
  # comments.
  defp push(held, scope, type, file) do
    case Apiary.Artifacts.push({:member_action, scope}, held, type, [file],
           stage_id: held.stage_id
         ) do
      {:ok, version} -> {:ok, version}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, :not_approver} -> {:error, :not_approver}
      {:error, :store_unavailable} -> {:error, :store_unavailable}
      {:error, _refused} -> {:error, :not_waiting}
    end
  end

  # The member as the explore input names a member (`Apiary.Dispatches.Inputs`), as the
  # questions and the review comments formats take a member's name: one line of 1 to 160
  # characters (`member.name`). Each run of white space, and of the characters a line
  # refuses, is one space; the ends are trimmed; the name is cut to 160 characters (code
  # points). A name that is then empty is `unnamed member`. So a member's write never
  # fails the format check for the name.
  defp person_name(%Scope{user: %{id: id}}) do
    name =
      id
      |> Apiary.Dispatches.Inputs.person_name()
      |> String.replace(@not_in_line, " ")
      |> String.trim()
      |> String.codepoints()
      |> Enum.take(@member_name)
      |> Enum.join()
      |> String.trim()

    if name == "", do: @unnamed_member, else: name
  end

  defp comment_text(text) do
    case Proposal.check_comment(text) do
      {:ok, text} -> {:ok, text}
      {:error, :invalid} -> {:error, {:invalid, :form}}
      {:error, error} -> {:error, {:invalid, %{comment: error}}}
    end
  end

  @doc false
  @spec confirm(Scope.t(), WorkItem.t(), pos_integer) ::
          {:ok, WorkItem.t()} | {:error, step_refusal}
  def confirm(%Scope{} = scope, %WorkItem{} = work_item, attempt) do
    result =
      Repo.transact(fn ->
        now = DateTime.utc_now()

        with {:ok, held, current} <- hold_step(scope, :"work_item.confirm", work_item, now),
             :ok <- waiting(current, [:confirm], attempt),
             :ok <- not_escalated(held),
             :ok <- keep_confirmation(held, scope, current.step, now),
             data = %{"take_in" => held.take_in, "attempt" => attempt},
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
             {:ok, run} <- next_run(held, false),
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

  # With the workflow model off, no stage runner reads the row, and the check does not apply
  # to an escalated stage left on it.
  defp not_escalated(%WorkItem{stage_state: :escalated}),
    do: if(Apiary.Stages.on?(), do: {:error, :not_waiting}, else: :ok)

  defp not_escalated(%WorkItem{}), do: :ok

  defp invalid({:ok, _checked} = ok), do: ok
  defp invalid({:error, :invalid}), do: {:error, {:invalid, :form}}
  defp invalid({:error, errors}) when is_map(errors), do: {:error, {:invalid, errors}}

  # The take in's next run (`Apiary.Dispatches.queue_next/3`), one run more at the run
  # limit when `extend?`: a take in with no run yet does not wait for a member.
  defp next_run(held, extend?) do
    case Dispatches.queue_next(held, held.take_in, extend: extend?) do
      {:ok, run} -> {:ok, run}
      {:error, :no_run} -> {:error, :not_waiting}
      {:error, _refusal} = refused -> refused
    end
  end

  defp keep_confirmation(held, scope, step, now) do
    %Confirmation{
      id: Ecto.UUID.generate(),
      organisation_id: held.organisation_id,
      workspace_id: held.workspace_id,
      work_item_id: held.id,
      take_in: held.take_in,
      attempt: step.attempt,
      result: %{
        "proposal_version" => Explore.proposal_version(held.id, held.take_in, step.attempt)
      },
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

  # The comment the page sends, its line breaks line feeds, trimmed: `{:ok, nil}` for none
  # or a blank one, `:comment_too_long` for one past the limit, and a changeset with the
  # error on `:comment` for one with a character a text of several lines may not have. A
  # text of more than four bytes for each character it may have is too long before it is
  # read any further.
  defp take_in_comment(attrs) do
    max = SourceComment.max_member_body()

    case attr(attrs, :comment) do
      nil ->
        {:ok, nil}

      text when is_binary(text) and byte_size(text) > 4 * max ->
        {:error, :comment_too_long}

      text when is_binary(text) ->
        text = if String.valid?(text), do: normal(text), else: text

        changeset =
          {%{}, %{comment: :string}}
          |> Ecto.Changeset.change(comment: text)
          |> Names.validate_characters(:comment, lines: true)

        cond do
          not changeset.valid? -> {:error, %{changeset | action: :insert}}
          text == "" -> {:ok, nil}
          length(String.codepoints(text)) > max -> {:error, :comment_too_long}
          true -> {:ok, text}
        end

      _other ->
        {:error,
         {%{}, %{comment: :string}}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:comment, "is invalid", validation: :cast)
         |> Map.put(:action, :insert)}
    end
  end

  # A text as a form returns it: its line breaks line feeds, trimmed.
  defp normal(text), do: text |> String.replace(["\r\n", "\r"], "\n") |> String.trim()

  # What the page gives under `key`, an atom, or its string, as a form's params name it.
  defp attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  # `work_item`, of the scope's workspace, asked `action` of, then held `FOR UPDATE`, read
  # again and asked again: one that moved meanwhile is not found, as is one whose id is
  # no UUID. The first answer, before the lock, keeps a person whom Access refuses from
  # holding the row; the second, of the locked row, reads the stage the work item is in
  # under its lock, for an action of a stage's approvers (`Apiary.Access`). The cost is a
  # second read of the scope.
  defp hold(scope, action, %WorkItem{id: id}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, workspace} <- workspace(scope),
         %WorkItem{} = found <- in_workspace(workspace, id, false),
         :ok <- Access.authorize(scope, action, found),
         %WorkItem{} = held <- in_workspace(workspace, id, true),
         :ok <- Access.authorize(scope, action, held) do
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

  # The person's comment on the ticket's record, written after the take in's feed entry:
  # none for none.
  defp write_comment(_scope, _ticket, nil, _now), do: :ok

  defp write_comment(%Scope{user: user}, %{item: item, adapter: adapter}, body, now) do
    %SourceComment{organisation_id: item.organisation_id, item_id: item.id, author_id: user.id}
    |> SourceComment.member_changeset(
      %{
        body: body,
        author_name: SourceComment.member_name(user.email),
        post_state: SourceComment.first_state(takes_comments(adapter))
      },
      now
    )
    |> Repo.insert()
    |> case do
      {:ok, %SourceComment{post_state: :posting} = comment} ->
        with {:ok, _seq} <- comment_entry(adapter, item, comment), do: :ok

      {:ok, %SourceComment{post_state: :kept}} ->
        :ok

      {:error, _changeset} = refused ->
        refused
    end
  end

  # The `comment` entry for the adapter to post the comment on the item.
  defp comment_entry(%Node{} = adapter, %Item{} = item, %SourceComment{} = comment) do
    Feed.append(adapter, %{
      kind: "comment",
      comment_id: comment.comment_id,
      ref: item.external_ref,
      author_name: comment.author_name,
      body: comment.body
    })
  end

  # Whether the adapter's source takes comments: the `comments` flag, set from its latest
  # start's description (`Apiary.Nodes.Node`), nil before its first start.
  defp takes_comments(%Node{comments: comments}), do: comments

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

  # tell/1 tells what a move of `work_item` changed (`told/1`) on the work items' and the
  # Backlog's topics, for a move that ran inside a caller's transaction: the caller calls
  # it once that transaction commits.
  @doc false
  @spec tell(WorkItem.t()) :: :ok
  def tell(%WorkItem{} = work_item) do
    work_item |> told() |> tell_told()
    :ok
  end

  defp finish({:ok, {work_item, told}}) do
    tell_told(told)
    {:ok, work_item}
  end

  defp finish({:error, _refusal} = refused), do: refused

  # Sent once the change commits: ids only, grouped by workspace.
  defp tell_told(told) do
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
