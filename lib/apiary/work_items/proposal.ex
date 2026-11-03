defmodule Apiary.WorkItems.Proposal do
  # Proposal reads an Explore run's result (`Apiary.Explore.Result`) as the work item pages
  # draw it, and checks what a member gives Explore: the answers to a run's questions and
  # a comment on a run's proposal. Pure: no database.
  #
  # ## The result as the pages draw it
  #
  # `from_result/1` is the proposal of a result whose verdict is `understood`:
  # `%{message: text}`, the proposal as Markdown, nil for a result stored before the
  # proposal was Markdown, which has no `message`. `questions/1` is the questions of a
  # result whose verdict is `not_understood`, in its order, each
  # `%{question: text, options: [%{title: text, explanation: text}]}`: the question as
  # Markdown and the options the run offers, none for a question that offers none. A
  # question stored before questions had options is a text: its options are none.
  #
  # ## The checks
  #
  # Each text a member gives is held to the rule the explore contract holds the text it
  # carries to (`priv/contract/explore/v1/result.schema.json` `$defs/text`): no control
  # character but tab, line feed and carriage return, and none of the invisible ones the
  # rule lists (`:characters`), since a run is never given an input it would refuse.
  # Lengths are counted in code points, as the contract counts them. A text is read with
  # its line breaks as line feeds and without the white space around it; one empty then is
  # `:blank`.
  #
  # `check_answers(questions, answers)` checks the answers a form gives to `questions`, by
  # each question's position from 1, as text (`"1"` to `"20"`). Each question has one
  # answer: `%{"option" => title}`, the title of one of the question's options, or
  # `%{"custom" => text}`, the member's text, at most 2,000 code points, the explore
  # input's answer (`inputs.schema.json` `answers[].answer`, a `$defs/short_text`). A
  # member's text alone may also be given as a string. A member who selects no option and
  # writes no text leaves the answer `:blank`; an empty `"option"` or `"custom"` counts as
  # none. `{:ok, [{position, question, answer, custom}]}`, `question` the question's text
  # and `custom` false for an option's title; or `{:error, errors}` by position (`:blank`,
  # `{:too_long, 2000}`, `:characters`); or `{:error, :invalid}` for a form that names
  # another question, gives no text, gives both an option and a text, or an option title
  # the question does not have.
  #
  # `check_comment(text)` checks a member's comment on a proposal: `{:ok, text}`, at most
  # 2,000 code points as an answer is, the explore input's `changes[].text`; or
  # `{:error, error}` (`:blank`, `{:too_long, 2000}`, `:characters`), or
  # `{:error, :invalid}` for no text.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  # result.schema.json: `$defs/short_text` and the most `questions`.
  @max_short 2000
  @max_questions 20
  # result.schema.json `$defs/text`: the characters a text refuses.
  @refused ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u

  @typedoc "A proposal as the work item pages draw it."
  @type t :: %{message: String.t() | nil}

  @typedoc "An option a run offers for a question."
  @type option :: %{title: String.t(), explanation: String.t()}

  @typedoc "A question a run asks, as the work item pages draw it."
  @type question :: %{question: String.t(), options: [option]}

  @typedoc "What is wrong with a text a member gives."
  @type error :: :blank | :characters | {:too_long, pos_integer}

  # max_answer/0 is the most code points an answer, or a comment, has.
  @doc false
  @spec max_answer() :: pos_integer
  def max_answer, do: @max_short

  # max_questions/0 is the most questions a run asks.
  @doc false
  @spec max_questions() :: pos_integer
  def max_questions, do: @max_questions

  ## The result

  # from_result/1 is the proposal of `result`, a result whose verdict is `understood`.
  @doc false
  @spec from_result(map) :: t
  def from_result(%{"verdict" => "understood"} = result) do
    case result do
      %{"message" => message} when is_binary(message) -> %{message: message}
      _stored_before -> %{message: nil}
    end
  end

  # questions/1 is the questions of `result`, a result whose verdict is `not_understood`.
  @doc false
  @spec questions(map) :: [question]
  def questions(%{"verdict" => "not_understood", "questions" => questions})
      when is_list(questions),
      do: Enum.map(questions, &question/1)

  # question/1 is one question of a result, or of a `questions` artifact, as the pages
  # draw it: a question stored as a text offers no option.
  @doc false
  @spec question(map | String.t()) :: question
  def question(%{"question" => text} = question) when is_binary(text) do
    options =
      for %{"title" => title, "explanation" => explanation} <- List.wrap(question["options"]),
          do: %{title: title, explanation: explanation}

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

    with true <- Enum.sort(Map.keys(answers)) == Enum.sort(keys),
         checked when is_list(checked) <- check_each(questions, answers) do
      case for({key, {:error, error}} <- checked, into: %{}, do: {key, error}) do
        errors when errors == %{} ->
          {:ok, for({_key, {:ok, answer}} <- checked, do: answer)}

        errors ->
          {:error, errors}
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

      case answer(question, answers[key]) do
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
