defmodule Apiary.WorkItemsFixtures do
  @moduledoc "Test helpers for the work items of a workspace and their events."

  import Ecto.Query, only: [from: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.{Number, WorkItem, WorkItemEvent}

  @doc """
  A work item of the scope's workspace, taken in by the scope's person, who owns it,
  with the next number and its `taken_in` event, written in one transaction as a take in
  writes them. `attrs` overrides the snapshot: `connection_id` (else a new connection of
  the scope's organisation, `ticket_connection_fixture/1`), `item_id` (else a new ticket
  of that connection with the work item's ref, `source_item_fixture/2`), `external_ref`,
  `url`, `title`, `collection_title`, `target_system`, `target_path`, `owner_id` and
  `first_instruction`. The adapter is the connection's.
  """
  def work_item_fixture(%Scope{workspace: workspace, user: user} = scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:connection_id, fn -> ticket_connection_fixture(scope).id end)
      |> Enum.into(%{
        external_ref: "acme/shop#12",
        url: "https://forge.example.com/acme/shop/issues/12",
        title: "The checkout keeps the old price",
        collection_title: "acme/shop",
        target_system: "forge.example.com",
        target_path: "acme/shop",
        owner_id: user.id
      })

    connection = Repo.get!(Connection, attrs.connection_id)

    attrs =
      attrs
      |> Map.put(:adapter_id, connection.adapter_id)
      |> Map.put_new_lazy(:item_id, fn ->
        source_item_fixture(scope, connection: connection, external_ref: attrs.external_ref).id
      end)

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

  @doc """
  A collection of the connection, of the scope's organisation, linked to the scope's
  workspace, with a ref no other collection has, written straight to the database.
  `attrs` overrides `external_ref`, `url`, `title`, `target_system`, `target_path`,
  `workspace_id`, `backlog` and `items`.
  """
  def source_collection_fixture(%Scope{} = scope, %Connection{} = connection, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    fields =
      Enum.into(attrs, %{
        external_ref: "acme/shop-#{unique}",
        url: "https://forge.example.com/acme/shop-#{unique}",
        title: "acme/shop",
        target_system: nil,
        target_path: nil,
        workspace_id: scope.workspace && scope.workspace.id
      })

    Repo.insert!(
      struct!(
        %Collection{
          public_id: Apiary.PublicId.generate(Collection.prefix()),
          organisation_id: connection.organisation_id,
          adapter_id: connection.adapter_id,
          connection_id: connection.id,
          last_listed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        fields
      )
    )
  end

  @doc """
  `work_item`'s ticket's collection made one that can change the work item's target, as
  a code forge's collection is (`Apiary.Runs.RunCredentials.form_work/3`): its target set
  to the work item's, and its adapter's `targets` true, as a start stores it. Returns the
  collection.
  """
  def target_candidate!(%WorkItem{item_id: item_id} = work_item) when is_binary(item_id) do
    collection =
      Repo.one!(
        from c in Collection,
          join: i in Item,
          on: i.collection_id == c.id,
          where: i.id == ^item_id
      )

    {1, _rows} =
      Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
        set: [targets: true]
      )

    {1, _rows} =
      Repo.update_all(from(c in Collection, where: c.id == ^collection.id),
        set: [target_system: work_item.target_system, target_path: work_item.target_path]
      )

    Repo.get!(Collection, collection.id)
  end

  @doc """
  A ticket, an open item of a collection, as an adapter sends one, written through
  `Apiary.Sources.Item.changeset/2`. `attrs` takes `collection` (else a new one of
  `connection`, else of a new connection of the scope's organisation) and overrides any
  field of the item.
  """
  def source_item_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)

    collection =
      Map.get_lazy(attrs, :collection, fn ->
        connection = Map.get_lazy(attrs, :connection, fn -> ticket_connection_fixture(scope) end)
        source_collection_fixture(scope, connection)
      end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fields =
      attrs
      |> Map.drop([:collection, :connection])
      |> Enum.into(%{
        external_ref: "acme/shop#12",
        key: "#12",
        url: "https://forge.example.com/acme/shop/issues/12",
        title: "The checkout keeps the old price",
        body: "The basket shows the price from before the sale.",
        body_format: "markdown",
        filed_by_name: "Avery Example",
        filed_by_kind: :person,
        labels: ["bug"],
        state: :open,
        state_reason: nil,
        comment_count: 0,
        source_created_at: now,
        source_updated_at: now
      })

    %Item{
      organisation_id: collection.organisation_id,
      adapter_id: collection.adapter_id,
      collection_id: collection.id
    }
    |> Item.changeset(fields)
    |> Repo.insert!()
  end

  @doc """
  A ticket in the Backlog of the scope's workspace, which a member may take in: an open
  item of a new collection linked to that workspace, with a target, of `connection` (else
  of a new connection of the scope's organisation). `attrs` takes `connection` and
  `collection` (attrs of the collection, `source_collection_fixture/3`), and overrides any
  field of the item.
  """
  def backlog_ticket_fixture(%Scope{} = scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    connection = Map.get_lazy(attrs, :connection, fn -> ticket_connection_fixture(scope) end)
    unique = System.unique_integer([:positive])

    collection =
      source_collection_fixture(
        scope,
        connection,
        Enum.into(Map.get(attrs, :collection, %{}), %{
          target_system: "forge.example.com",
          target_path: "acme/shop-#{unique}"
        })
      )

    source_item_fixture(
      scope,
      attrs
      |> Map.drop([:connection])
      |> Map.put(:collection, collection)
      |> Map.put_new(:external_ref, "acme/shop-#{unique}#12")
    )
  end

  @doc """
  Moves `work_item`, taken in through `ticket` and `connection` in `scope`'s workspace, to
  the workspace of `there`, as a person does: its runs end, it is closed, the ticket's
  record ends and a new one comes in a collection of `there`'s workspace, and a Take in
  again there (`Apiary.WorkItems.take_in_again/3`) moves it. `%{work_item:, ticket:}`: the
  work item moved, and the ticket's record there.
  """
  def moved_work_item_fixture(%Scope{} = scope, work_item, ticket, connection, %Scope{} = there) do
    Repo.update_all(from(d in DispatchRun, where: d.work_item_id == ^work_item.id),
      set: [state: :ended, end_cause: :run_ended]
    )

    {:ok, _closed} = Apiary.WorkItems.close(scope, Repo.get!(WorkItem, work_item.id))
    ticket |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now()) |> Repo.update!()

    record =
      backlog_ticket_fixture(there, connection: connection, external_ref: ticket.external_ref)

    {:ok, moved} = Apiary.WorkItems.take_in_again(there, record.public_id)
    %{work_item: moved, ticket: record}
  end

  @doc """
  A connected connection of the scope's organisation to a new adapter of the instance,
  the kind of row a work item's ticket comes through, written straight to the database
  so that it needs no feature on (`Apiary.NodesFixtures.connection_fixture/3` goes
  through `Apiary.Adapters.connect/2`, which does).
  """
  def ticket_connection_fixture(%Scope{organisation: organisation, user: user}) do
    adapter =
      %Node{
        kind: :adapter,
        organisation_id: nil,
        workspace_id: nil,
        created_by_id: user.id,
        instance_limit: nil,
        gateway_choice: :direct
      }
      |> Node.adapter_changeset(%{name: Apiary.NodesFixtures.unique_node_name()})
      |> Repo.insert!()

    now = DateTime.utc_now()

    Repo.insert!(%Connection{
      public_id: Apiary.PublicId.generate(Connection.prefix()),
      organisation_id: organisation.id,
      adapter_id: adapter.id,
      created_by_id: user.id,
      state: :connected,
      pass_nonce: :crypto.strong_rand_bytes(16),
      pass_nonce_used_at: now,
      connected_at: now
    })
  end

  @doc """
  A run of the queue of `work_item`, of its current take in unless `take_in:` says,
  `attempt:` one past the highest of that take in unless given, of 3, written straight to
  the database, with the run registered for it where it has one. `state:` is `:ended`
  unless given (`:waiting`, `:claimed`, `:handed_over`); an ended run has `end_cause:`,
  `:run_ended` unless given. A run handed over, and one ended `run_ended`, `lost` or
  `released`, has a registered run (`registered: false` leaves it out): completed, its exit
  folded and its outcome a minute old unless `run:` changes it. `result:` is what the run
  pushed during the run (`push_result!/3`): `understood_result/1` a proposal,
  `questions_result/1` questions; nil, the default, is nothing. A run ended `run_ended` or
  `lost` is then settled as its end settles it (`Apiary.Dispatches.Settle.settle_locked/1`,
  unless `settle: false`). A run ended for a cause its handover gives
  (`variables_invalid`, `ticket_gone`, `inputs_invalid`, `target_access_gone`) has the
  outcome `:error`, as the handover writes it. Returns
  `%{dispatch_run: dispatch_run, run: run_or_nil}`.
  """
  def explore_run_fixture(%WorkItem{} = work_item, opts \\ []) do
    take_in = Keyword.get(opts, :take_in, work_item.take_in)
    state = Keyword.get(opts, :state, :ended)
    end_cause = if state == :ended, do: Keyword.get(opts, :end_cause, :run_ended)

    attempt =
      Keyword.get_lazy(opts, :attempt, fn ->
        highest =
          Repo.one(
            from d in DispatchRun,
              where: d.work_item_id == ^work_item.id and d.take_in == ^take_in,
              select: max(d.attempt)
          )

        (highest || 0) + 1
      end)

    now = DateTime.utc_now()

    # A run that pushes a result pushes it while it is live (`Apiary.Artifacts.push/5`
    # refuses a run that ended): it is handed over until then, and ends after.
    pushes? =
      state == :ended and is_map(Keyword.get(opts, :result)) and
        Keyword.get(opts, :registered, end_cause in [:run_ended, :lost, :released])

    dispatch_run =
      %DispatchRun{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id
      }
      |> DispatchRun.queue_changeset(%{
        work_item_id: work_item.id,
        step: "explore",
        take_in: take_in,
        attempt: attempt,
        of: 3,
        queued_at: DateTime.add(now, -120, :second)
      })
      |> Ecto.Changeset.change(
        if(pushes?,
          do: [state: :handed_over, end_cause: nil],
          else: [state: state, end_cause: end_cause]
        )
      )
      |> Ecto.Changeset.change(result_outcome: unformed_outcome(end_cause))
      |> Repo.insert!()

    registered? =
      Keyword.get(
        opts,
        :registered,
        state == :handed_over or end_cause in [:run_ended, :lost, :released]
      )

    run =
      if registered? do
        defaults =
          if state == :ended,
            do: %{
              state: "completed",
              exit_state: "completed",
              started_at: DateTime.add(now, -90, :second),
              exited_at: DateTime.add(now, -60, :second),
              outcome_state: "succeeded",
              outcome_time: DateTime.add(now, -60, :second),
              outcome_received_at: DateTime.add(now, -60, :second),
              outcome_digest: :crypto.strong_rand_bytes(32)
            },
            else: %{state: "running", started_at: DateTime.add(now, -30, :second)}

        %Run{
          number:
            Apiary.RunEventsFixtures.next_run_number(
              work_item.organisation_id,
              work_item.workspace_id
            ),
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          node_run_id: dispatch_run.run_id,
          dispatch_run_id: dispatch_run.id
        }
        |> Ecto.Changeset.change(Map.merge(defaults, Map.new(Keyword.get(opts, :run, %{}))))
        |> Repo.insert!()
      end

    case {run, Keyword.get(opts, :result)} do
      {%Run{} = run, %{} = result} -> push_result!(dispatch_run, run, result)
      _none -> nil
    end

    dispatch_run =
      if pushes? do
        dispatch_run
        |> Ecto.Changeset.change(state: state, end_cause: end_cause)
        |> Repo.update!()
      else
        dispatch_run
      end

    dispatch_run =
      if state == :ended and end_cause in [:run_ended, :lost] and
           Keyword.get(opts, :settle, true) do
        {:ok, _told} =
          Repo.transact(fn -> {:ok, Apiary.Dispatches.Settle.settle_locked(dispatch_run)} end)

        Repo.get!(DispatchRun, dispatch_run.id)
      else
        dispatch_run
      end

    %{dispatch_run: dispatch_run, run: run}
  end

  @doc """
  Pushes what the run `run` of the run of the queue `dispatch_run` gave, as the run
  pushes it through the run API: for `understood_result/1`, its `message` as a version of
  the work item's proposal; for `questions_result/1`, its questions added, open, to the
  newest questions, each with the id `q<n>` and asked by the run. A question of more than
  one line keeps its first line as the question and the whole as its context.
  """
  def push_result!(%DispatchRun{} = dispatch_run, %Run{} = run, %{"verdict" => verdict} = result) do
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)

    case verdict do
      "understood" ->
        push_as_run!(dispatch_run, work_item, "proposal", %{
          filename: "proposal.md",
          content_type: "text/markdown",
          binary: result["message"] || "A proposal."
        })

      "not_understood" ->
        earlier =
          case Apiary.Explore.Questions.newest(work_item) do
            {_version, document} -> document["questions"]
            nil -> []
          end

        at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        added =
          result["questions"]
          |> Enum.with_index(length(earlier) + 1)
          |> Enum.map(fn {question, n} ->
            question_entry(question, "q#{n}", %{"run" => run.number, "at" => at})
          end)

        push_as_run!(
          dispatch_run,
          work_item,
          "questions",
          Apiary.Explore.Questions.file(%{"questions" => earlier ++ added})
        )
    end
  end

  defp question_entry(%{"question" => text} = question, id, asked) do
    entry = %{
      "id" => id,
      "question" => text |> String.trim() |> String.split("\n") |> hd(),
      "options" => question["options"] || [],
      "state" => "open",
      "asked" => asked
    }

    if String.contains?(String.trim(text), "\n"),
      do: Map.put(entry, "context", String.trim(text)),
      else: entry
  end

  @doc """
  Pushes, as the run `run` of the run of the queue `dispatch_run`, the newest review
  comments of its work item with the run's reply added to each open review comment, which
  it closes: the reply's `outcome` (`"changed"` unless given), and for `"asked"` the id of
  the question in `question`.
  """
  def reply_as_run!(
        %DispatchRun{} = dispatch_run,
        %Run{} = run,
        outcome \\ "changed",
        question \\ nil
      ) do
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    {_version, document} = Apiary.Explore.ReviewComments.newest(work_item)
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    reply =
      %{"text" => "Changed the proposal.", "by" => %{"run" => run.number}, "at" => at}
      |> Map.put("outcome", outcome)
      |> then(&if(question, do: Map.put(&1, "question", question), else: &1))

    comments =
      Enum.map(document["review_comments"], fn
        %{"state" => "open"} = comment ->
          comment
          |> Map.put("replies", (comment["replies"] || []) ++ [reply])
          |> Map.put("state", "closed")

        comment ->
          comment
      end)

    push_as_run!(
      dispatch_run,
      work_item,
      "review-comments",
      Apiary.Explore.ReviewComments.file(%{"review_comments" => comments})
    )
  end

  defp push_as_run!(dispatch_run, work_item, type, file) do
    {:ok, version} =
      Apiary.Artifacts.push({:run, dispatch_run}, work_item, type, [file],
        name: "main",
        stage_id: dispatch_run.stage_id
      )

    version
  end

  # A run its handover could not form ended with an error, as the handover writes it.
  defp unformed_outcome(cause)
       when cause in [
              :variables_invalid,
              :ticket_gone,
              :inputs_invalid,
              :target_access_gone,
              :build_failed,
              :harness_unresolved
            ],
       do: :error

  defp unformed_outcome(_cause), do: nil

  @doc "Stores a `dev.qory.runtime.result` event of `run` at `sequence`, with `data`."
  def result_event!(%Run{} = run, sequence, data) do
    Repo.insert!(%Event{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      sequence: sequence,
      node_event_id: Ecto.UUID.generate(),
      type: "dev.qory.runtime.result",
      time: DateTime.utc_now(),
      data: data,
      received_at: DateTime.utc_now()
    })
  end

  @doc "An explore result whose verdict is `understood`; `attrs` overrides its members."
  def understood_result(attrs \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "verdict" => "understood",
        "message" => """
        ## What this is

        The basket keeps the price from before the sale.

        ## How to do it

        Read the price from the catalogue each time.

        ## Alternatives

        - Clear the basket at a sale. Why not: it loses what people chose.
        """
      },
      Map.new(attrs)
    )
  end

  @doc """
  An explore result whose verdict is `not_understood`, asking `questions`: each a question
  with its options, or a text, a question that offers none.
  """
  def questions_result(questions \\ ["Which basket?", "Which sale?"]) do
    questions =
      Enum.map(questions, fn
        text when is_binary(text) -> %{"question" => text, "options" => []}
        %{} = question -> question
      end)

    %{"version" => 1, "verdict" => "not_understood", "questions" => questions}
  end
end
