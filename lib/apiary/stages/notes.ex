defmodule Apiary.Stages.Notes do
  # The people's notes on a work item that have an id (`Apiary.Stages.notes/1`): a request
  # for changes or a move at a gate (`Apiary.Stages.GateDecision`, `gd_…`), an
  # escalation that a person resolved with a note (`Apiary.Stages.Escalation`, `es_…`), a
  # member's answer to a run's question (`an_…`) and the comment of Run another round that
  # is not an escalation's note (`rc_…`). The last two are stored with no id: the id is
  # made from the member's move each time it is read (`Apiary.Explore.Given`, `note_id`).
  # A run's version may have one as its `decision`, the note that asked for it: `find/2`
  # is the check of a push, `times/2` the time of each note, as the notes have it, and
  # `writers/2` the person who wrote each. Only the two queries and `given/1` contain the
  # rule for which rows are such notes, so the notes, the check, the times and the writers
  # agree.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.{PublicId, Repo}
  alias Apiary.Explore.{Given, Questions, ReviewComments}
  alias Apiary.Stages.{Escalation, GateDecision}
  alias Apiary.WorkItems.{Explore, WorkItem, WorkItemEvent}

  # The prefixes of the ids made from a member's move (`given/1`).
  @given_prefixes ["an", "rc"]

  @typedoc "A note's id and the time the note was written."
  @type note :: %{id: String.t(), at: DateTime.t()}

  # gate_decisions/1 is the query of the work item's decisions that are notes: each
  # request for changes and each move, but a move that resolves an escalation (a move back
  # or a switch of track), which has no note: the escalation stands for it, and a move the
  # stage runner wrote (`automatic`: a return, a take in again), which no person made.
  @doc false
  @spec gate_decisions(Ecto.UUID.t()) :: Ecto.Query.t()
  def gate_decisions(work_item_id),
    do:
      from(d in GateDecision,
        where:
          d.work_item_id == ^work_item_id and d.kind in [:request_changes, :move] and
            is_nil(d.escalation_id) and not d.automatic
      )

  # escalations/1 is the query of the work item's escalations that are notes: each one a
  # person resolved with a note. The note's time is `resolved_at`.
  @doc false
  @spec escalations(Ecto.UUID.t()) :: Ecto.Query.t()
  def escalations(work_item_id),
    do:
      from(e in Escalation,
        where: e.work_item_id == ^work_item_id and not is_nil(e.resolved_at),
        where: not is_nil(e.note)
      )

  # given/1 is what members gave Explore on the work item that are notes with an id
  # (`Apiary.Explore.Given`, `note_id`): each answer to a run's question and each comment
  # of Run another round, as `%{id:, at:, by_id:}`. The
  # time is the move's, as the note's `at`. A work item that is gone has none.
  @doc false
  @spec given(Ecto.UUID.t()) :: [%{id: String.t(), at: DateTime.t(), by_id: Ecto.UUID.t() | nil}]
  def given(work_item_id) do
    case Repo.get(WorkItem, work_item_id) do
      %WorkItem{} = work_item -> with_ids(Given.all(work_item))
      nil -> []
    end
  end

  # given/1 for the check of a push of `id`: the documents are read as for a write, so a
  # newest version of the questions or of the review comments whose file cannot be read
  # is `{:error, :store_unavailable}`, never taken for a work item with no answer. The
  # files are read only where `id` is one that a move's event could make (`candidate?/2`);
  # for any other id the work item has no such note. As `given/1`, the check reads no
  # earlier version of the questions: only the Explore page reads the wording a member
  # answered (`Given.reader/1`).
  defp given_checked(work_item_id, id) do
    with true <- candidate?(work_item_id, id) || nil,
         %WorkItem{} = work_item <- Repo.get(WorkItem, work_item_id),
         {:ok, questions} <- Questions.current(work_item),
         {:ok, comments} <- ReviewComments.current(work_item) do
      events = Explore.events(work_item.id)
      {:ok, with_ids(Given.from_events(events, document(questions), document(comments)))}
    else
      nil -> {:ok, []}
      {:error, :store_unavailable} = error -> error
    end
  end

  # Whether `id` is an id that a member's move on the work item could make, from the
  # data of its `:answered` events alone (`Apiary.Explore.Given`): an `an_…` id for each
  # question the move answered, an `rc_…` id for the comment of Run another round. An id
  # that no event could make needs no file read.
  defp candidate?(work_item_id, id) do
    from(e in WorkItemEvent,
      where: e.work_item_id == ^work_item_id and e.kind == :answered,
      select: {e.id, e.data}
    )
    |> Repo.all()
    |> Enum.any?(fn {event_id, data} -> id in candidates(event_id, data) end)
  end

  defp candidates(event_id, %{} = data) do
    answers =
      for question <- List.wrap(data["questions"]),
          is_binary(question),
          do: PublicId.derive("an", event_id <> ":" <> question)

    case data do
      %{"round_comment" => true, "review_comment" => comment} when is_binary(comment) ->
        [PublicId.derive("rc", event_id <> ":" <> comment) | answers]

      _none ->
        answers
    end
  end

  defp candidates(_event_id, _data), do: []

  defp with_ids(entries),
    do:
      for(
        %{note_id: id} = entry when is_binary(id) <- entries,
        do: %{id: id, at: entry.at, by_id: entry.by_id}
      )

  defp document({_version, document}), do: document
  defp document(nil), do: nil

  # The notes of `given/1` among `ids`, read only where one of `ids` has the shape of such
  # an id, as `times/2` and `writers/2` run on every read of a work item's versions.
  defp given_among(work_item_id, ids) do
    if Enum.any?(ids, &given_id?/1),
      do: Enum.filter(given(work_item_id), &(&1.id in ids)),
      else: []
  end

  defp given_id?(id), do: Enum.any?(@given_prefixes, &PublicId.valid?(&1, id))

  # find/2 is the note of the work item with the public id `id`, or nil where `id` is no
  # such note: a malformed id, another work item's, a decision or an escalation that is
  # not a note, or an id of the shape of an answer's or a comment's that no answer or
  # comment of the work item has. For the `an_…` or `rc_…` id of an answer or a Run
  # another round comment that a member gave on the work item, a newest version of the
  # questions or of the review comments whose file cannot be read is
  # `{:error, :store_unavailable}`. A call with any other `an_…` or `rc_…` id gets nil,
  # and no file is read.
  @doc false
  @spec find(Ecto.UUID.t(), term) :: note | nil | {:error, :store_unavailable}
  def find(work_item_id, id) when is_binary(id) do
    cond do
      PublicId.valid?(GateDecision.prefix(), id) ->
        Repo.one(
          from d in gate_decisions(work_item_id),
            where: d.public_id == ^id,
            select: %{id: d.public_id, at: d.inserted_at}
        )

      PublicId.valid?(Escalation.prefix(), id) ->
        Repo.one(
          from e in escalations(work_item_id),
            where: e.public_id == ^id,
            select: %{id: e.public_id, at: e.resolved_at}
        )

      given_id?(id) ->
        with {:ok, given} <- given_checked(work_item_id, id) do
          case Enum.find(given, &(&1.id == id)) do
            %{at: at} -> %{id: id, at: at}
            nil -> nil
          end
        end

      true ->
        nil
    end
  end

  def find(_work_item_id, _id), do: nil

  # times/2 is the time of each note of the work item among `ids`, by its id; an id that
  # is no such note is left out.
  @doc false
  @spec times(Ecto.UUID.t(), [String.t() | nil]) :: %{String.t() => DateTime.t()}
  def times(work_item_id, ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        decisions =
          Repo.all(
            from d in gate_decisions(work_item_id),
              where: d.public_id in ^ids,
              select: {d.public_id, d.inserted_at}
          )

        escalations =
          Repo.all(
            from e in escalations(work_item_id),
              where: e.public_id in ^ids,
              select: {e.public_id, e.resolved_at}
          )

        given = for note <- given_among(work_item_id, ids), do: {note.id, note.at}
        Map.new(decisions ++ escalations ++ given)
    end
  end

  # writers/2 is the account id of the person who wrote each note of the work item among
  # `ids`, by its id: a request's or a move's `user_id`, an escalation's `resolved_by_id`,
  # the member who gave an answer or a comment, nil where the row has none. An id that is
  # no such note is left out.
  @doc false
  @spec writers(Ecto.UUID.t(), [String.t() | nil]) :: %{String.t() => Ecto.UUID.t() | nil}
  def writers(work_item_id, ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        decisions =
          Repo.all(
            from d in gate_decisions(work_item_id),
              where: d.public_id in ^ids,
              select: {d.public_id, d.user_id}
          )

        escalations =
          Repo.all(
            from e in escalations(work_item_id),
              where: e.public_id in ^ids,
              select: {e.public_id, e.resolved_by_id}
          )

        given = for note <- given_among(work_item_id, ids), do: {note.id, note.by_id}
        Map.new(decisions ++ escalations ++ given)
    end
  end
end
