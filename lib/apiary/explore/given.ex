defmodule Apiary.Explore.Given do
  # Given reads what members gave Explore on a work item, oldest first, for the pages and
  # the notes a run reads: each answer to a question, each review comment and each reply
  # to one. The texts are in the work item's newest questions and review comments
  # (`Apiary.Explore.Questions`, `Apiary.Explore.ReviewComments`); who gave each, when,
  # and at which run comes from the move's event, `:answered` (`Apiary.WorkItems.Moves`).
  #
  # Each entry is a map:
  #
  #   * `kind`: `:answer`, `:comment` (a review comment) or `:reply`;
  #   * `take_in` and `attempt`: the run of the take in the move named, its latest run;
  #   * `id`: the question's or the review comment's id;
  #   * `question`: the question's text, nil for a review comment and a reply;
  #   * `text`: the answer's, the review comment's or the reply's text; for an answer,
  #     the option's title, else the note (`Apiary.Explore.Questions.words/1`), with
  #     `custom` true for the note, and `option` and `note` as the answer has them; nil
  #     otherwise;
  #   * `on`: for a review comment and a reply, the version of the proposal the review
  #     comment is on, nil otherwise;
  #   * `by_id` and `at`: the member's account and the move's time, and `event_id`, the
  #     move's event.
  #
  # The moves that answered a question pair with its answers by order: the first move,
  # oldest first, gave the first of the question's `history`, oldest first, and the
  # question's `answer` is the last (a run that reopens a question moves its answer to
  # the end of its `history`). A move with no answer at its place gives no entry. An
  # entry whose text no newest version has is left out. A send of the review comments
  # gives nothing to read.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.WorkItems.{Explore, WorkItem}

  @typedoc "What a member gave Explore."
  @type entry :: %{
          kind: :answer | :comment | :reply,
          take_in: pos_integer,
          attempt: pos_integer,
          id: String.t(),
          question: String.t() | nil,
          text: String.t(),
          custom: boolean | nil,
          option: String.t() | nil,
          note: String.t() | nil,
          on: pos_integer | nil,
          by_id: Ecto.UUID.t() | nil,
          at: DateTime.t(),
          event_id: Ecto.UUID.t()
        }

  # all/1 is what members gave Explore on `work_item`, oldest first (the moduledoc).
  @doc false
  @spec all(WorkItem.t()) :: [entry]
  def all(%WorkItem{id: id} = work_item), do: from_events(work_item, Explore.events(id))

  # from_events/2 is the same, read from `events`, the work item's events in order.
  @doc false
  @spec from_events(WorkItem.t(), [map]) :: [entry]
  def from_events(%WorkItem{} = work_item, events) do
    if Enum.any?(events, &(&1.kind == :answered)) do
      from_events(
        events,
        document(Questions.newest(work_item)),
        document(ReviewComments.newest(work_item))
      )
    else
      []
    end
  end

  # from_events/3 is the same, read from `events` and the documents of the work item's
  # newest questions and newest review comments, nil for none, which the caller read.
  @doc false
  @spec from_events([map], map | nil, map | nil) :: [entry]
  def from_events(events, questions, comments) when is_list(events) do
    {entries, _counts} =
      events
      |> Enum.filter(&(&1.kind == :answered))
      |> Enum.flat_map_reduce(%{}, &entries(&1, questions, comments, &2))

    entries
  end

  defp document({_version, document}), do: document
  defp document(nil), do: nil

  # The entries of one move, with `counts`, the number of earlier moves that answered
  # each question, for the next.
  defp entries(%{data: %{"questions" => ids}} = event, questions, _comments, counts)
       when is_list(ids) do
    entries =
      for id <- ids,
          %{} = question <- [Questions.entry(questions, id)],
          %{} = answer <- [answer(question, Map.get(counts, id, 0))] do
        {text, custom} = Questions.words(answer)

        Map.merge(base(event, :answer, id), %{
          question: question["question"],
          text: text,
          custom: custom,
          option: answer["option"],
          note: answer["note"]
        })
      end

    {entries, Enum.reduce(ids, counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))}
  end

  defp entries(%{data: %{"review_comment" => id} = data} = event, _questions, comments, counts)
       when is_binary(id) do
    with %{} = comment <- Enum.find(ReviewComments.entries(comments), &(&1["id"] == id)),
         {kind, text} when is_binary(text) <- comment_text(comment, data["reply"]) do
      {[Map.merge(base(event, kind, id), %{text: text, on: get_in(comment, ["on", "version"])})],
       counts}
    else
      _none -> {[], counts}
    end
  end

  defp entries(_event, _questions, _comments, counts), do: {[], counts}

  defp comment_text(comment, position) when is_integer(position) do
    case Enum.at(comment["replies"] || [], position - 1) do
      %{"text" => text} -> {:reply, text}
      _none -> nil
    end
  end

  defp comment_text(comment, _none), do: {:comment, comment["text"]}

  # The answer at `position`, from 0, among the question's answers oldest first: its
  # history, then its answer; nil for none.
  defp answer(question, position) do
    given = (question["history"] || []) ++ List.wrap(question["answer"])
    Enum.at(given, position)
  end

  defp base(event, kind, id),
    do: %{
      kind: kind,
      take_in: event.data["take_in"],
      attempt: event.data["attempt"],
      id: id,
      question: nil,
      text: nil,
      custom: nil,
      option: nil,
      note: nil,
      on: nil,
      by_id: event.actor_id,
      at: event.at,
      event_id: event.id
    }
end
