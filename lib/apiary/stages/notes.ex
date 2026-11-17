defmodule Apiary.Stages.Notes do
  # The people's notes on a work item that have an id (`Apiary.Stages.notes/1`): a request
  # for changes or a move at a gate (`Apiary.Stages.GateDecision`, `gd_…`) and an
  # escalation that a person resolved with a note (`Apiary.Stages.Escalation`, `es_…`).
  # A run's version may have one as its `decision`, the note that asked for it (vault
  # 0261, 624 (a)): `find/2` is the check of a push, and `times/2` the time of each note,
  # as the notes have it. The two queries are the one place that says which rows are such
  # notes, so the notes, the check and the times agree.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.{PublicId, Repo}
  alias Apiary.Stages.{Escalation, GateDecision}

  @typedoc "A note's id and the time the note was written."
  @type note :: %{id: String.t(), at: DateTime.t()}

  # gate_decisions/1 is the query of the work item's decisions that are notes: each
  # request for changes and each move.
  @doc false
  @spec gate_decisions(Ecto.UUID.t()) :: Ecto.Query.t()
  def gate_decisions(work_item_id),
    do:
      from(d in GateDecision,
        where: d.work_item_id == ^work_item_id and d.kind in [:request_changes, :move]
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

  # find/2 is the note of the work item with the public id `id`, or nil where `id` is no
  # such note: a malformed id, another work item's, or a decision or an escalation that is
  # not a note.
  @doc false
  @spec find(Ecto.UUID.t(), term) :: note | nil
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

        Map.new(decisions ++ escalations)
    end
  end
end
