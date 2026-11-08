defmodule Apiary.Explore.Questions do
  # Questions reads and writes a work item's questions document: the one file of a version
  # of the standard artifact type `questions`, name `main`, in the questions format qory
  # publishes (`priv/schemas/artifacts/questions.schema.json`). One document holds every
  # question of the work item, in the order they were asked, each with its `id`, its
  # `options` (0 to 4, each with a `title`, an `explanation` and an optional boolean
  # `recommended`, true on at most one option of the question), its `state` (`open`,
  # `answered`, `decided` or `withdrawn`), the run that asked it (`asked.run`, the run's
  # number) and, once a member answered it, its `answer`: the `option` the member chose,
  # null when the member wrote the answer in `note`, and a `note`, required when `option`
  # is null; a question a run reopened keeps its earlier answers in `history`. A question
  # a run adds decided has a `decision`: the `option` the run chose, its `reason`, the
  # `run` and when (`at`). A later version keeps that `decision` unchanged in every state
  # of the question (`:decision_changed`).
  #
  # A run adds, withdraws and reopens questions by pushing a new version through the run
  # API; Qory Apiary writes the answers (`answer/4`, from `Apiary.WorkItems.Moves`). So a
  # version a run pushes keeps the members' answers, compared with the newest version, and
  # each `decision` in it matches its question (`check_run/3`), else it is refused with one
  # of these reasons:
  #
  #   * `:id_dropped`: an `id` of the newest version is missing;
  #   * `:asked_changed`: the run changed the `asked` of a question the newest version
  #     has;
  #   * `:follows_changed`: the run changed the `follows` of a question the newest
  #     version has: a question follows from the questions it followed from when it was
  #     asked;
  #   * `:order_changed`: the questions of the newest version are not the first of the
  #     version, in the newest version's order: a run adds each new question after them,
  #     so a question's `follows` keeps pointing at questions before it;
  #   * `:answer_changed`: the run added, changed or removed an `answer`;
  #   * `:history_changed`: the run changed a question's `history`, or gave a new
  #     question one;
  #   * `:reopen_not_kept`: the run reopened an answered question without moving its
  #     answer, unchanged, into the end of its `history`;
  #   * `:reopened_run`: the run reopened an answered question with a `reopened.run`
  #     other than the run's number;
  #   * `:answered_changed`: the run changed the `question`, `context` or `options` of a
  #     question that stays answered, each option's `recommended` included, so an answer
  #     keeps the question the member answered;
  #   * `:decided_changed`: the run changed the `question` or `options` of a question
  #     with a `decision`, in any state, a reopen and a withdraw included, or its
  #     `context` while it stays decided or answered, so a decision keeps the options it
  #     was chosen from: a run that learns more withdraws the question and adds a new
  #     one;
  #   * `:new_not_open`: a question the newest version does not have is neither `open`
  #     nor `decided`, or is `open` with a `decision`: a run adds a question open, or
  #     decided with its `decision`;
  #   * `:asked_run`: a question the newest version does not have has an `asked.run` other
  #     than the run's number;
  #   * `:follows_unknown`: a question the newest version does not have follows from an
  #     id that is not the id of a question before it in the version;
  #   * `:decision_option`: the `option` of the `decision` of a question the newest
  #     version does not have is not the title of one of the question's options;
  #   * `:decision_run`: the `run` of the `decision` of a question the newest version does
  #     not have is not the question's `asked.run`: only the run that asked a question
  #     records a decision on it;
  #   * `:decided_not_new`: the run changed the state of a question the newest version
  #     has to `decided`: a run records a decision only on a question it adds;
  #   * `:decision_changed`: the run changed, dropped or added the `decision` of a
  #     question the newest version has, also when it withdrew or reopened the question.
  #
  # A decision is checked against its question once, when a run adds the question. After
  # that, the question and options of a question with a decision stay as they are, and
  # its context while it stays decided or answered (`:decided_changed`); the decision
  # stays too (`:decision_changed`). The JSON Schema of the format cannot check these
  # rules.
  #
  # An absent `follows` and an empty one are the same: the question follows from none.
  #
  # A run is named by its number in the run API (`Apiary.Runs.Run`, `number`), which a
  # member sees as "Run N": `asked.run` and `reopened.run`. The numbers of one work item's
  # runs differ across its moves (`take_in_runs/2`).
  #
  # The one document spans the work item's take ins. Where Explore stands and what a
  # member may answer count only the open questions of the current take in
  # (`open_in_take_in/2`).
  #
  # Numbers compare by value, as the schema's integers do: `4.0` is `4`. Qory Apiary stores
  # each number of a version that is an integer in value as an integer
  # (`Apiary.Artifacts.push/5`), so a reader finds `4`, never `4.0`.
  #
  # The schema's checks, and each `id` once, come first, at the format check of the push
  # (`Apiary.Artifacts.Format`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Artifacts
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @type_name "questions"
  @name "main"
  @reasons [
    :id_dropped,
    :asked_changed,
    :follows_changed,
    :order_changed,
    :answer_changed,
    :history_changed,
    :reopen_not_kept,
    :reopened_run,
    :answered_changed,
    :new_not_open,
    :asked_run,
    :follows_unknown,
    :decision_option,
    :decision_run,
    :decided_not_new,
    :decision_changed,
    :decided_changed
  ]
  # What a run leaves as it is on a question that stays answered or has a decision.
  @answered_kept ~w(question context options)

  @typedoc "A questions document, decoded: a map with string keys."
  @type document :: %{optional(String.t()) => term}

  @typedoc "Why a run's version of the questions is refused."
  @type reason ::
          :id_dropped
          | :asked_changed
          | :follows_changed
          | :order_changed
          | :answer_changed
          | :history_changed
          | :reopen_not_kept
          | :reopened_run
          | :answered_changed
          | :new_not_open
          | :asked_run
          | :follows_unknown
          | :decision_option
          | :decision_run
          | :decided_not_new
          | :decision_changed
          | :decided_changed

  # type_name/0 and name/0 are the type and the name of the artifact of a work item's
  # questions.
  @doc false
  @spec type_name() :: String.t()
  def type_name, do: @type_name

  @doc false
  @spec name() :: String.t()
  def name, do: @name

  # reasons/0 is every reason `check_run/3` refuses a run's version for.
  @doc false
  @spec reasons() :: [reason]
  def reasons, do: @reasons

  ## Reading

  # newest/1 is the newest version of the work item's questions with its document,
  # `{version, document}`; nil for none, and for a version whose file cannot be read.
  @doc false
  @spec newest(WorkItem.t()) :: {Artifacts.Version.t(), document} | nil
  def newest(%WorkItem{} = work_item) do
    with %{} = version <- Artifacts.newest(work_item, @type_name, @name),
         %{} = document <- read(version) do
      {version, document}
    else
      _none -> nil
    end
  end

  # current/1 is the newest version of the work item's questions with its document, for a
  # write that builds on it: `{:ok, {version, document}}`; `{:ok, nil}` for no version;
  # and `{:error, :store_unavailable}` for a newest version whose file cannot be read as
  # a document of the format, so a write never takes it for no version and drops what
  # members wrote.
  @doc false
  @spec current(WorkItem.t()) ::
          {:ok, {Artifacts.Version.t(), document} | nil} | {:error, :store_unavailable}
  def current(%WorkItem{} = work_item) do
    case Artifacts.newest(work_item, @type_name, @name) do
      nil -> {:ok, nil}
      version -> with {:ok, document} <- loaded(version), do: {:ok, {version, document}}
    end
  end

  # loaded/1 is the document of `version`, a version of the questions, for a write:
  # `{:ok, document}`, or `{:error, :store_unavailable}` when `read/1` cannot read it.
  @doc false
  @spec loaded(map) :: {:ok, document} | {:error, :store_unavailable}
  def loaded(version) do
    case read(version) do
      %{} = document -> {:ok, document}
      nil -> {:error, :store_unavailable}
    end
  end

  # read/1 is the document of a version of the questions, nil when its file cannot be
  # read or is not one JSON object with a list of questions.
  @doc false
  @spec read(Artifacts.Version.t() | map) :: document | nil
  def read(%{files: [file | _rest]}) do
    with {:ok, source} <- Artifacts.open_file(file),
         {:ok, text} <- bytes(source),
         {:ok, %{"questions" => questions} = document} when is_list(questions) <-
           Jason.decode(text) do
      document
    else
      _other -> nil
    end
  end

  def read(_version), do: nil

  # decode/1 is the document of `text`, a file's bytes, nil for one that is not a JSON
  # object with a list of questions.
  @doc false
  @spec decode(binary) :: document | nil
  def decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"questions" => questions} = document} when is_list(questions) -> document
      _other -> nil
    end
  end

  defp bytes(path) when is_binary(path), do: File.read(path)
  defp bytes(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}

  # open/1 is the questions of `document` that wait for an answer, in its order; none for
  # nil.
  @doc false
  @spec open(document | nil) :: [map]
  def open(%{"questions" => questions}) when is_list(questions),
    do: Enum.filter(questions, &match?(%{"state" => "open"}, &1))

  def open(_document), do: []

  # open_in_take_in/2 is the open questions of `document` that belong to the current take
  # in, in its order; none for nil. A question belongs to the current take in when it is
  # open and its `asked.run`, or the `reopened.run` of the last entry of its `history`
  # that has one, is in `runs`: the numbers of the registered runs of the current take
  # in's runs of the queue (`take_in_runs/2`). A work item has one questions document
  # across its take ins, so a question left open in an earlier take in stays open in it,
  # and does not count.
  @doc false
  @spec open_in_take_in(document | nil, MapSet.t(pos_integer)) :: [map]
  def open_in_take_in(document, %MapSet{} = runs) do
    Enum.filter(open(document), fn question ->
      MapSet.member?(runs, get_in(question, ["asked", "run"])) or
        MapSet.member?(runs, reopened_run(question))
    end)
  end

  # answerable_in_take_in/2 is the questions of `document` a member may answer, in its
  # order; none for nil: the open questions of the current take in (`open_in_take_in/2`),
  # and each decided question whose `asked.run` is in `runs`, the run that added it
  # decided. A member's answer to a decided question changes the run's decision: the
  # question becomes answered, and its `decision` stays (`answer/4`).
  @doc false
  @spec answerable_in_take_in(document | nil, MapSet.t(pos_integer)) :: [map]
  def answerable_in_take_in(document, %MapSet{} = runs) do
    open = document |> open_in_take_in(runs) |> MapSet.new(& &1["id"])

    document
    |> all()
    |> Enum.filter(fn question ->
      MapSet.member?(open, question["id"]) or
        (question["state"] == "decided" and
           MapSet.member?(runs, get_in(question, ["asked", "run"])))
    end)
  end

  defp all(%{"questions" => questions}) when is_list(questions), do: questions
  defp all(_document), do: []

  # same_as_decision?/3 is true when `option`, with no `note` (nil or blank), is the
  # option of the decision of `question`, a decided question: an answer that changes
  # nothing, which `Apiary.WorkItems.Moves.answer/4` and
  # `Apiary.WorkItems.Moves.another_round/4` do not write.
  @doc false
  @spec same_as_decision?(map | nil, String.t() | nil, String.t() | nil) :: boolean
  def same_as_decision?(
        %{"state" => "decided", "decision" => %{"option" => decided}},
        option,
        note
      )
      when is_binary(option),
      do: option == decided and blank?(note)

  def same_as_decision?(_question, _option, _note), do: false

  # take_in_runs/2 is the numbers of the registered runs of the runs of the queue of take
  # in `take_in` of the work item `work_item_id`, the runs `open_in_take_in/2` counts.
  # `asked.run` and `reopened.run` are a registered run's number (`Apiary.Runs.Run`,
  # `number`), and its run of the queue has the take in. A number is unique in its
  # workspace, and the runs of a work item may be in several. A move raises the target's
  # counter past the work item's highest number (`Apiary.Runs.Number.raise_past/2`), so its
  # runs have different numbers, apart from runs of a move before the counters existed.
  @doc false
  @spec take_in_runs(Ecto.UUID.t(), pos_integer) :: MapSet.t(pos_integer)
  def take_in_runs(work_item_id, take_in) when is_integer(take_in) do
    Repo.all(
      from r in Run,
        join: d in DispatchRun,
        on: d.id == r.dispatch_run_id,
        where: d.work_item_id == ^work_item_id and d.take_in == ^take_in,
        select: r.number
    )
    |> MapSet.new()
  end

  # The `reopened.run` of the last entry of the question's history that has one, nil for
  # none.
  defp reopened_run(question) do
    question
    |> history()
    |> Enum.reverse()
    |> Enum.find_value(&(is_map(&1) && get_in(&1, ["reopened", "run"])))
  end

  # ids/1 is the ids of the questions of `document`; none for nil.
  @doc false
  @spec ids(document | nil) :: [String.t()]
  def ids(%{"questions" => questions}) when is_list(questions),
    do: for(%{"id" => id} <- questions, do: id)

  def ids(_document), do: []

  # entry/2 is the question `id` of `document`, nil for none.
  @doc false
  @spec entry(document | nil, String.t()) :: map | nil
  def entry(%{"questions" => questions}, id) when is_list(questions),
    do: Enum.find(questions, &match?(%{"id" => ^id}, &1))

  def entry(_document, _id), do: nil

  ## A run's version

  # check_run/3 checks `document`, the version a run whose number is `run_number` pushes,
  # against `newest`, the newest version's document, nil for none (the moduledoc): `:ok`,
  # or `{:error, reason}` for the first rule it breaks, the questions read in order.
  @doc false
  @spec check_run(document | nil, document, pos_integer) :: :ok | {:error, reason}
  def check_run(newest, %{"questions" => questions}, run_number) when is_list(questions) do
    earlier = (newest && newest["questions"]) || []
    given = Map.new(questions, &{&1["id"], &1})
    known = MapSet.new(earlier, & &1["id"])

    # Each question with the ids of the questions before it in the version.
    before =
      questions
      |> Enum.map_reduce(MapSet.new(), fn question, seen ->
        {{question, seen}, MapSet.put(seen, question["id"])}
      end)
      |> elem(0)

    added = Enum.reject(before, fn {question, _seen} -> MapSet.member?(known, question["id"]) end)

    with :ok <- each(earlier, &kept(&1, Map.get(given, &1["id"]), run_number)),
         :ok <- order(earlier, questions),
         :ok <- each(added, fn {question, seen} -> new(question, seen, run_number) end),
         :ok <- each(added, fn {question, _seen} -> decision(question) end),
         do: :ok
  end

  defp each(list, check) do
    Enum.reduce_while(list, :ok, fn entry, :ok ->
      case check.(entry) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  # The questions of the newest version first, in its order. Every id of the newest
  # version is in the version (`kept/3`) and each id is there once (the format check), so
  # the first ids of the version are the newest version's ids or the order changed.
  defp order(earlier, questions) do
    ids = Enum.map(earlier, & &1["id"])

    if questions |> Enum.take(length(ids)) |> Enum.map(& &1["id"]) == ids,
      do: :ok,
      else: {:error, :order_changed}
  end

  defp kept(_earlier, nil, _run_number), do: {:error, :id_dropped}

  # Who asked a question, when, and what it follows from, stay in every case.
  defp kept(earlier, given, run_number) do
    cond do
      Map.get(given, "asked") != Map.get(earlier, "asked") ->
        {:error, :asked_changed}

      follows(given) != follows(earlier) ->
        {:error, :follows_changed}

      decided_now?(earlier, given) ->
        {:error, :decided_not_new}

      Map.get(given, "decision") != Map.get(earlier, "decision") ->
        {:error, :decision_changed}

      true ->
        with :ok <- answer_kept(earlier, given, run_number), do: decision_kept(earlier, given)
    end
  end

  # A question with a decision keeps the question and the options the decision was
  # chosen from, in every state, and its context while it stays decided or answered: a
  # run that reopens an answer may add to the context what contradicts the answer.
  defp decision_kept(%{"decision" => _decision} = earlier, given) do
    keys = if stays?(earlier, given), do: @answered_kept, else: ~w(question options)

    if Map.take(given, keys) == Map.take(earlier, keys),
      do: :ok,
      else: {:error, :decided_changed}
  end

  defp decision_kept(_earlier, _given), do: :ok

  defp stays?(%{"state" => state}, %{"state" => state}) when state in ~w(decided answered),
    do: true

  defp stays?(_earlier, _given), do: false

  # A reopen: the earlier answer, unchanged, at the end of the history the question had,
  # reopened by this run.
  defp answer_kept(
         %{"state" => "answered", "answer" => answer} = earlier,
         %{"state" => "open"} = given,
         run_number
       ) do
    history = history(earlier)
    now = history(given)

    cond do
      Map.has_key?(given, "answer") -> {:error, :answer_changed}
      length(now) != length(history) + 1 -> {:error, :reopen_not_kept}
      Enum.take(now, length(history)) != history -> {:error, :history_changed}
      Map.delete(List.last(now), "reopened") != answer -> {:error, :reopen_not_kept}
      get_in(List.last(now), ["reopened", "run"]) != run_number -> {:error, :reopened_run}
      true -> :ok
    end
  end

  defp answer_kept(earlier, given, _run_number) do
    cond do
      Map.get(given, "answer") != Map.get(earlier, "answer") ->
        {:error, :answer_changed}

      history(given) != history(earlier) ->
        {:error, :history_changed}

      answered?(earlier) and answered?(given) and
          Map.take(given, @answered_kept) != Map.take(earlier, @answered_kept) ->
        {:error, :answered_changed}

      true ->
        :ok
    end
  end

  defp answered?(question), do: question["state"] == "answered"

  # A question of the newest version that the run sets to decided.
  defp decided_now?(earlier, given),
    do: given["state"] == "decided" and earlier["state"] != "decided"

  # A question a run adds open has no decision.
  defp new(%{"state" => "open", "decision" => _decision}, _before, _run_number),
    do: {:error, :new_not_open}

  defp new(%{"state" => state} = given, before, run_number) when state in ["open", "decided"] do
    cond do
      history(given) != [] -> {:error, :history_changed}
      get_in(given, ["asked", "run"]) != run_number -> {:error, :asked_run}
      not Enum.all?(follows(given), &MapSet.member?(before, &1)) -> {:error, :follows_unknown}
      true -> :ok
    end
  end

  defp new(_given, _before, _run_number), do: {:error, :new_not_open}

  # The decision of a question the run adds is on one of the question's options, by the
  # run that asked the question. The format check passed, so `decision` is an object
  # with `option` and `run`, and each option an object with `title`. Numbers compare by
  # value.
  defp decision(%{"decision" => %{} = decision} = question) do
    titles = for %{"title" => title} <- question["options"] || [], do: title

    cond do
      decision["option"] not in titles -> {:error, :decision_option}
      decision["run"] != get_in(question, ["asked", "run"]) -> {:error, :decision_run}
      true -> :ok
    end
  end

  defp decision(_question), do: :ok

  defp history(entry), do: Map.get(entry, "history") || []
  defp follows(entry), do: Map.get(entry, "follows") || []

  ## Answers

  # answer/4 is `document` with the open and the decided questions in `answers`, each
  # `{id, option, note}`, answered by the member named `by` (the explore input's form of a
  # member, `Apiary.Dispatches.Inputs.person_name/1`) at `at`, in UTC to the whole
  # second: `{:ok, document}`. `option` is the title of the option the member chose, or
  # nil for an answer of the member's own, which is then `note`; `note` is nil for none.
  # An empty `option` counts as nil, and the version has `"option": null`, as the format
  # requires. No `option` and a blank or no `note` is `{:error, {:note_required, id}}`. A
  # decided question keeps its `decision` beside the `answer`. A question that is neither
  # open nor decided, or not in `document`, is left as it is.
  @doc false
  @spec answer(
          document,
          [{String.t(), String.t() | nil, String.t() | nil}],
          String.t(),
          DateTime.t()
        ) ::
          {:ok, document} | {:error, {:note_required, String.t()}}
  def answer(%{"questions" => questions} = document, answers, by, %DateTime{} = at)
      when is_list(answers) and is_binary(by) do
    answers =
      Enum.map(answers, fn {id, option, note} ->
        {id, if(is_binary(option) and String.trim(option) == "", do: nil, else: option), note}
      end)

    case Enum.find(answers, fn {_id, option, note} -> is_nil(option) and blank?(note) end) do
      {id, _option, _note} ->
        {:error, {:note_required, id}}

      nil ->
        given = Map.new(answers, fn {id, option, note} -> {id, {option, note}} end)
        at = at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        questions =
          Enum.map(questions, fn
            %{"state" => state, "id" => id} = question
            when state in ["open", "decided"] and is_map_key(given, id) ->
              {option, note} = Map.fetch!(given, id)

              answer =
                %{"option" => option, "by" => %{"name" => by}, "at" => at}
                |> then(&if(blank?(note), do: &1, else: Map.put(&1, "note", note)))

              question |> Map.put("state", "answered") |> Map.put("answer", answer)

            question ->
              question
          end)

        {:ok, %{document | "questions" => questions}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(note) when is_binary(note), do: String.trim(note) == ""

  # words/1 is an answer as one text, as the work item pages and the notes show it: the
  # option's title, else the note; `{text, custom}`, `custom` true for an answer of the
  # member's own.
  @doc false
  @spec words(map) :: {String.t() | nil, boolean}
  def words(%{"option" => option}) when is_binary(option), do: {option, false}

  def words(%{} = answer), do: {answer["note"], true}

  # file/1 is `document` as the one file of a version of the questions.
  @doc false
  @spec file(document) :: Artifacts.file()
  def file(document),
    do: %{
      filename: @type_name <> ".json",
      content_type: "application/json",
      binary: Jason.encode!(document)
    }
end
