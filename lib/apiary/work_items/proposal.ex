defmodule Apiary.WorkItems.Proposal do
  # Proposal reads the questions of a work item as the work item pages draw them, and
  # checks what a member gives Explore: the answers to the open questions and a review
  # comment on the proposal. Pure: no database.
  #
  # ## The questions as the pages draw them
  #
  # `question/1` is one question of a questions document (`Apiary.Explore.Questions`):
  # `%{question: text, options: [%{title: text, explanation: text, recommended: boolean}]}`,
  # the question and the options the run offers, none for a question that offers none.
  # `recommended` is true only for an option whose `recommended` is true in the document.
  #
  # ## The checks
  #
  # Each text a member gives is held to the rule of the questions format's `$defs/text`
  # (`priv/schemas/artifacts/questions.schema.json`): no control character but tab, line
  # feed and carriage return, and none of the invisible ones the rule lists
  # (`:characters`), since a run is never given a text it would refuse. Lengths are
  # counted in code points, as the format counts them. A text is read with its line
  # breaks as line feeds and without the white space around it; one empty then is
  # `:blank`.
  #
  # `check_answers(questions, answers)` checks the answers a form gives to `questions`,
  # the open questions, by each question's position from 1, as text (`"1"` to `"20"`).
  # A question has at most one answer: `%{"option" => title}`, the title of one of the
  # question's options, or `%{"custom" => text}`, the member's text, at most 2,000 code
  # points, the format's `answer.text`. A member's text alone may also be given as a
  # string. A question the form leaves out, or whose answer has no option and no text, is
  # not answered; an empty `"option"` or `"custom"` counts as none. At least one question
  # is answered. `{:ok, [{position, question, answer, custom}]}`, for the questions
  # answered, `question` the question's text and `custom` false for an option's title; or
  # `{:error, errors}` by position (`{:too_long, 2000}`, `:characters`, and `:blank` for
  # every question when none is answered); or `{:error, :invalid}` for a form that names
  # another question, gives no text, gives both an option and a text, or an option title
  # the question does not have.
  #
  # `check_answers_by_id(questions, answers)` checks the answers a form gives by
  # question id: `questions` is the questions of the newest questions document, as it
  # stores them, and `answers` a list of `%{"id" => id, "option" => title | nil,
  # "note" => text | nil}`, at least one, each id once; `"option"` and `"note"` may be
  # left out. An answer has an option, a note, or both: an option with a note adds detail
  # to the option, and no option ("Give your own option") makes the note the answer, so
  # the note is required. An empty option or note, once trimmed, counts as none.
  # `{:ok, [{id, option, note}]}`, in the order given, the option as the question's title
  # and the note cleaned, nil for none (`Apiary.Explore.Questions.answer/4`); or
  # `{:error, errors}` by id: `:unknown_id` (no question has the id), `:not_open` (the
  # question is answered or closed), `:unknown_option` (no option of the question has the
  # title), `:note_required` (no option and no note), `{:too_long, 2000}` and
  # `:characters` (the note); or `{:error, :invalid}` for no list, an empty one, an entry
  # of another shape, or an id twice.
  #
  # `check_comment(text)` checks a member's review comment on a proposal, or a reply to
  # one: `{:ok, text}`, at most 2,000 code points; or `{:error, error}` (`:blank`,
  # `{:too_long, 2000}`, `:characters`), or `{:error, :invalid}` for no text.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  # questions.schema.json: `$defs/short_text`, and the most questions a form shows.
  @max_short 2000
  @max_questions 20
  # questions.schema.json `$defs/text`: the characters a text refuses.
  @refused ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u

  @typedoc "An option a run offers for a question."
  @type option :: %{title: String.t(), explanation: String.t(), recommended: boolean}

  @typedoc "A question a run asks, as the work item pages draw it."
  @type question :: %{question: String.t(), options: [option]}

  @typedoc "What is wrong with a text a member gives."
  @type error :: :blank | :characters | {:too_long, pos_integer}

  @typedoc "What is wrong with an answer a form gives by question id."
  @type by_id_error ::
          :unknown_id
          | :not_open
          | :unknown_option
          | :note_required
          | :characters
          | {:too_long, pos_integer}

  # max_answer/0 is the most code points an answer, or a comment, has.
  @doc false
  @spec max_answer() :: pos_integer
  def max_answer, do: @max_short

  # max_questions/0 is the most questions a form answers at once.
  @doc false
  @spec max_questions() :: pos_integer
  def max_questions, do: @max_questions

  ## The questions

  # question/1 is one question of a questions document as the pages draw it.
  @doc false
  @spec question(map | String.t()) :: question
  def question(%{"question" => text} = question) when is_binary(text) do
    options =
      for %{"title" => title, "explanation" => explanation} = option <-
            List.wrap(question["options"]),
          do: %{
            title: title,
            explanation: explanation,
            recommended: option["recommended"] == true
          }

    %{question: text, options: options}
  end

  def question(text) when is_binary(text), do: %{question: text, options: []}

  ## The answers

  # check_answers/2 checks the answers a form gives to `questions` (the moduledoc).
  @doc false
  @spec check_answers([question], term) ::
          {:ok, [{pos_integer, String.t(), String.t(), boolean}]}
          | {:error, %{String.t() => error} | :invalid}
  def check_answers(questions, answers) when is_list(questions) and is_map(answers) do
    keys = for position <- 1..length(questions)//1, do: Integer.to_string(position)

    with true <- Enum.all?(Map.keys(answers), &(&1 in keys)),
         checked when is_list(checked) <- check_each(questions, answers) do
      errors = for {key, {:error, error}} <- checked, error != :blank, into: %{}, do: {key, error}
      given = for {_key, {:ok, answer}} <- checked, do: answer

      cond do
        errors != %{} -> {:error, errors}
        given == [] -> {:error, Map.new(keys, &{&1, :blank})}
        true -> {:ok, given}
      end
    else
      _invalid -> {:error, :invalid}
    end
  end

  def check_answers(_questions, _answers), do: {:error, :invalid}

  defp check_each(questions, answers) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {question, position}, acc ->
      key = Integer.to_string(position)

      case answer(question, Map.get(answers, key, %{})) do
        :invalid ->
          {:halt, :invalid}

        {:ok, {answer, custom}} ->
          {:cont, [{key, {:ok, {position, question.question, answer, custom}}} | acc]}

        {:error, error} ->
          {:cont, [{key, {:error, error}} | acc]}
      end
    end)
    |> case do
      :invalid -> :invalid
      checked -> Enum.reverse(checked)
    end
  end

  # One question's answer: `{:ok, {answer, custom}}`, `{:error, error}`, or `:invalid`.
  defp answer(question, text) when is_binary(text), do: answer(question, %{"custom" => text})

  defp answer(question, %{} = given) do
    option = given["option"]
    custom = given["custom"]

    with true <- Enum.all?(Map.keys(given), &(&1 in ["option", "custom"])),
         true <- is_nil(option) or is_binary(option),
         true <- is_nil(custom) or is_binary(custom) do
      case {present(option), present(custom)} do
        {nil, nil} -> blank_or_refused(custom)
        {option, nil} -> option(question, option)
        {nil, custom} -> custom(custom)
        {_option, _custom} -> :invalid
      end
    else
      false -> :invalid
    end
  end

  defp answer(_question, _given), do: :invalid

  # A text left empty once trimmed counts as none; one that is not UTF-8, or holds a
  # refused character, is checked as given, so its refusal says why.
  defp present(nil), do: nil
  defp present(text) when byte_size(text) > 4 * @max_short, do: text

  defp present(text) do
    if String.valid?(text) and normal(text) == "", do: nil, else: text
  end

  defp blank_or_refused(nil), do: {:error, :blank}

  defp blank_or_refused(custom) do
    case text(custom, @max_short) do
      {:error, :blank} -> {:error, :blank}
      {:error, _error} = refused -> refused
    end
  end

  defp option(_question, given) when byte_size(given) > 4 * @max_short, do: :invalid

  defp option(%{options: options}, given) do
    given = if String.valid?(given), do: normal(given), else: given

    case Enum.find(options, &(normal(&1.title) == given)) do
      %{title: title} -> {:ok, {title, false}}
      nil -> :invalid
    end
  end

  defp custom(text) do
    case text(text, @max_short) do
      {:ok, text} -> {:ok, {text, true}}
      {:error, _error} = refused -> refused
    end
  end

  # check_answers_by_id/2 checks the answers a form gives by question id (the moduledoc).
  @doc false
  @spec check_answers_by_id([map], term) ::
          {:ok, [{String.t(), String.t() | nil, String.t() | nil}]}
          | {:error, %{String.t() => by_id_error} | :invalid}
  def check_answers_by_id(questions, [_ | _] = answers) when is_list(questions) do
    by_id = Map.new(questions, &{&1["id"], &1})

    with true <- Enum.all?(answers, &by_id_shape?/1),
         ids = Enum.map(answers, & &1["id"]),
         true <- length(Enum.uniq(ids)) == length(ids) do
      checked = Enum.map(answers, &by_id(&1, Map.get(by_id, &1["id"])))
      errors = for {id, {:error, error}} <- checked, into: %{}, do: {id, error}

      if errors == %{},
        do: {:ok, for({_id, {:ok, answer}} <- checked, do: answer)},
        else: {:error, errors}
    else
      false -> {:error, :invalid}
    end
  end

  def check_answers_by_id(_questions, _answers), do: {:error, :invalid}

  defp by_id_shape?(%{"id" => id} = given) when is_binary(id) do
    Enum.all?(Map.keys(given), &(&1 in ["id", "option", "note"])) and
      (is_nil(given["option"]) or is_binary(given["option"])) and
      (is_nil(given["note"]) or is_binary(given["note"]))
  end

  defp by_id_shape?(_given), do: false

  defp by_id(%{"id" => id}, nil), do: {id, {:error, :unknown_id}}

  defp by_id(%{"id" => id}, %{"state" => state}) when state != "open",
    do: {id, {:error, :not_open}}

  defp by_id(%{"id" => id} = given, question) do
    titles = for %{"title" => title} <- List.wrap(question["options"]), do: title

    with {:ok, option} <- by_id_option(present(given["option"]), titles),
         {:ok, note} <- by_id_note(present(given["note"]), option) do
      {id, {:ok, {id, option, note}}}
    else
      {:error, error} -> {id, {:error, error}}
    end
  end

  defp by_id_option(nil, _titles), do: {:ok, nil}

  defp by_id_option(given, titles) do
    given = if String.valid?(given), do: normal(given), else: given

    case Enum.find(titles, &(normal(&1) == given)) do
      nil -> {:error, :unknown_option}
      title -> {:ok, title}
    end
  end

  defp by_id_note(nil, nil), do: {:error, :note_required}
  defp by_id_note(nil, _option), do: {:ok, nil}
  defp by_id_note(note, _option), do: text(note, @max_short)

  ## A comment

  # check_comment/1 checks a member's comment on a proposal (the moduledoc).
  @doc false
  @spec check_comment(term) :: {:ok, String.t()} | {:error, error | :invalid}
  def check_comment(text) when is_binary(text), do: text(text, @max_short)
  def check_comment(_text), do: {:error, :invalid}

  # A text: valid UTF-8, its line breaks line feeds and trimmed, not empty, at most `max`
  # code points, holding no character the contract refuses. One past 4 × `max` bytes, more
  # than `max` code points hold, is refused as too long before it is cleaned or counted.
  defp text(value, max) when byte_size(value) > 4 * max, do: {:error, {:too_long, max}}

  defp text(value, max) do
    with {:ok, value} <- clean(value) do
      cond do
        value == "" -> {:error, :blank}
        code_points(value) > max -> {:error, {:too_long, max}}
        true -> {:ok, value}
      end
    end
  end

  defp clean(value) do
    if String.valid?(value) and not Regex.match?(@refused, value),
      do: {:ok, normal(value)},
      else: {:error, :characters}
  end

  # A text as a form gives it back: its line breaks line feeds, trimmed.
  defp normal(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  defp code_points(text), do: text |> String.codepoints() |> length()
end
