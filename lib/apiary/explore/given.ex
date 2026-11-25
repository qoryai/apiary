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
  #   * `question` and `options`: the question's text and its options, nil for a review
  #     comment and a reply. With `reader/1` (`from_events/4`, the Explore page), an
  #     answer to a question that a run reopened after it has them as the member answered
  #     them, from the version of the questions that the move wrote (`"questions_version"`
  #     of its event), so a run that rewords a reopened question changes neither. Else,
  #     and for an event written before that number or a version that cannot be read,
  #     they come from the newest version;
  #   * `text`: the answer's, the review comment's or the reply's text; for an answer,
  #     the option's title, else the note (`Apiary.Explore.Questions.words/1`), with
  #     `custom` true for the note, and `option` and `note` as the answer has them; nil
  #     otherwise;
  #   * `by_id` and `at`: the member's account and the move's time, and `event_id`, the
  #     move's event;
  #   * `note_id`: the public id of the entry as a note that a run's push may send as
  #     `decision` (`Apiary.Stages.Notes`): for an answer, `an_…`, and for the comment of
  #     Run another round, `rc_…`, also where the round resolves an open escalation whose
  #     note stays empty, each made from the move's event and the question's or the review
  #     comment's id (`Apiary.PublicId.derive/2`); nil for every other review comment and
  #     reply. An answer keeps its id when the questions get a newer version and when its
  #     note closes. A new answer to a question that a run reopened is a new entry, of
  #     another move, with a new id; the earlier answer keeps its id and its time.
  #
  # The moves that answered a question pair with its answers by order: the first move,
  # oldest first, gave the first of the question's `history`, oldest first, and the
  # question's `answer` is the last (a run that reopens a question moves its answer to
  # the end of its `history`). A move with no answer at its place gives no entry. An
  # entry whose text no newest version has is left out. A send of the open review comments
  # alone gives nothing to read; Run another round with a comment on the whole proposal
  # (`Apiary.WorkItems.another_round/4`) gives the comment, after the move's answers.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  require Logger

  alias Apiary.Artifacts
  alias Apiary.Explore.{Questions, ReviewComments}
  alias Apiary.PublicId
  alias Apiary.WorkItems.{Explore, WorkItem}

  @typedoc "What the function of `reader/1` returns for a version's number."
  @type read :: {:ok, map} | {:unreadable, String.t(), String.t() | nil} | :none

  @typedoc "What a member gave Explore."
  @type entry :: %{
          kind: :answer | :comment | :reply,
          take_in: pos_integer,
          attempt: pos_integer,
          id: String.t(),
          question: String.t() | nil,
          options: [map] | nil,
          text: String.t(),
          custom: boolean | nil,
          option: String.t() | nil,
          note: String.t() | nil,
          by_id: Ecto.UUID.t() | nil,
          at: DateTime.t(),
          event_id: Ecto.UUID.t(),
          note_id: String.t() | nil
        }

  # all/1 is what members gave Explore on `work_item`, oldest first (the moduledoc).
  @doc false
  @spec all(WorkItem.t()) :: [entry]
  def all(%WorkItem{id: id} = work_item), do: from_events(work_item, Explore.events(id))

  # reader/1 is the function that `from_events/4` reads an earlier version of the work
  # item's questions with, by its number: `{:ok, document}`, or `{:unreadable, work
  # item's public id, version's public id}` for a version that is gone (nil) or whose
  # file cannot be read.
  @doc false
  @spec reader(WorkItem.t()) :: (integer -> read)
  def reader(%WorkItem{} = work_item) do
    fn number ->
      version = Artifacts.numbered(work_item, Questions.type_name(), Questions.name(), number)

      case version && Questions.read(version) do
        %{} = document -> {:ok, document}
        nil -> {:unreadable, work_item.public_id, version && version.public_id}
      end
    end
  end

  # from_events/2 is the same, read from `events`, the work item's events in order. It
  # reads no earlier version of the questions.
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

  # from_events/4 is the same, read from `events` and the documents of the work item's
  # newest questions and newest review comments, nil for none, which the caller read.
  # `read` reads an earlier version of the questions by its number (`reader/1`); with
  # none, every answer has the newest wording, and no earlier version is read.
  @doc false
  @spec from_events([map], map | nil, map | nil, (integer -> read)) :: [entry]
  def from_events(events, questions, comments, read \\ fn _number -> :none end)
      when is_list(events) do
    {entries, _counts} =
      events
      |> Enum.filter(&(&1.kind == :answered))
      |> Enum.flat_map_reduce(%{}, &entries(&1, questions, comments, &2))

    worded(entries, read)
  end

  # Each answer whose question a run reopened after it, with the question and its options
  # from the version the member answered (`asked_in`), each version read once. A version
  # that cannot be read leaves the newest wording, with a warning in the log that has the
  # version's number and the work item's public id, and the version's public id where the
  # version exists.
  defp worded(entries, read) do
    documents =
      entries
      |> Enum.map(&Map.get(&1, :asked_in))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> Map.new(&{&1, read.(&1)})

    for {number, {:unreadable, work_item_id, version_id}} <- documents,
        do: Logger.warning(unreadable(number, work_item_id, version_id))

    Enum.map(entries, fn entry ->
      {number, entry} = Map.pop(entry, :asked_in)

      with {:ok, document} <- documents[number],
           %{"question" => question} = asked <- Questions.entry(document, entry.id) do
        %{entry | question: question, options: asked["options"]}
      else
        _newest -> entry
      end
    end)
  end

  defp unreadable(number, work_item_id, nil),
    do:
      "A questions version is gone: answers to it show the newest wording " <>
        "number=#{number} work_item=#{work_item_id}"

  defp unreadable(number, work_item_id, version_id),
    do:
      "Restore the file of a questions version: answers to it show the newest wording " <>
        "version=#{version_id} number=#{number} work_item=#{work_item_id}"

  defp document({_version, document}), do: document
  defp document(nil), do: nil

  # The entries of one move, with `counts`, the number of earlier moves that answered
  # each question, for the next. A move of Run another round with answers and a comment
  # gives the answers, then the comment.
  defp entries(%{data: %{"questions" => ids}} = event, questions, comments, counts)
       when is_list(ids) do
    answers =
      for id <- ids,
          %{} = question <- [Questions.entry(questions, id)],
          %{} = answer <- [answer(question, Map.get(counts, id, 0))] do
        {text, custom} = Questions.words(answer)

        Map.merge(base(event, :answer, id), %{
          note_id: PublicId.derive("an", event.id <> ":" <> id),
          asked_in: asked_in(event, question, Map.get(counts, id, 0)),
          question: question["question"],
          options: question["options"],
          text: text,
          custom: custom,
          option: answer["option"],
          note: answer["note"]
        })
      end

    {answers ++ comment(event, comments),
     Enum.reduce(ids, counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))}
  end

  defp entries(event, _questions, comments, counts), do: {comment(event, comments), counts}

  # The number of the version of the questions that the move answered, where a run
  # reopened the question after the answer at `position` (the answer is in its `history`)
  # and the move's event has the number; nil otherwise.
  defp asked_in(%{data: %{"questions_version" => number}}, question, position)
       when is_integer(number),
       do: if(position < length(history(question)), do: number)

  defp asked_in(_event, _question, _position), do: nil

  defp history(question), do: question["history"] || []

  # The review comment or the reply of a move, where its event has one.
  defp comment(%{data: %{"review_comment" => id} = data} = event, comments) when is_binary(id) do
    with %{} = comment <- Enum.find(ReviewComments.entries(comments), &(&1["id"] == id)),
         {kind, text} when is_binary(text) <- comment_text(comment, data["reply"]) do
      [Map.merge(base(event, kind, id), %{text: text, note_id: round_note_id(event, kind, id)})]
    else
      _none -> []
    end
  end

  defp comment(_event, _comments), do: []

  # The id of the comment of Run another round, which its event marks with
  # `"round_comment"` true (`Apiary.WorkItems.Moves`); nil for any other review comment,
  # for a reply, and for a comment of an event written before the mark.
  defp round_note_id(%{data: %{"round_comment" => true}} = event, :comment, id),
    do: PublicId.derive("rc", event.id <> ":" <> id)

  defp round_note_id(_event, _kind, _id), do: nil

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
      options: nil,
      text: nil,
      custom: nil,
      option: nil,
      note: nil,
      by_id: event.actor_id,
      at: event.at,
      event_id: event.id,
      note_id: nil
    }
end
