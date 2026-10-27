defmodule Apiary.WorkItems.Proposal do
  # Proposal reads an Explore run's result (`Apiary.Explore.Result`) as the work item pages
  # draw it, and checks what a member gives Explore: the answers to a run's questions and
  # the changes to a run's proposal. Pure: no database.
  #
  # ## The result as the pages draw it
  #
  # `from_result/1` is the proposal of a result whose verdict is `understood`:
  # `complexity` (`%{level: :simple | :standard | :complex, reason: text}`),
  # `understanding`, `scope_in` and `scope_out` (lists of entries), `approach` (the chosen
  # approach's summary), `alternatives` (`[%{text: summary, reason: text}]`) and
  # `knowledge` (`[%{text: text, sources: [url]}]`, empty for none). `questions/1` is the
  # questions of a result whose verdict is `not_understood`, in its order.
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
  # `check_answers(questions, answers)` checks the answers to `questions` a form gives, by
  # each question's position from 1, as text (`"1"` to `"20"`): every question answered,
  # each answer at most 2,000 code points, the explore input's answer (`inputs.schema.json`
  # `answers[].answer`, a `$defs/short_text`). `{:ok, [{position, question, answer}]}`, or
  # `{:error, errors}` by position (`:blank`, `{:too_long, 2000}`, `:characters`), or
  # `{:error, :invalid}` for a form that names another question or gives no text.
  #
  # `changes(proposal, params)` checks the edit page's form against the run's `proposal`:
  # `"complexity"` (`"level"`, one of the three levels, and `"reason"`),
  # `"understanding"`, `"scope_in"` and `"scope_out"` (one entry per line, empty lines left
  # out) and `"approach"`, each held to the result schema's bound for it: a reason and an
  # approach 1 to 2,000 code points, the understanding 1 to 20,000, 1 to 50 entries in
  # scope and 0 to 50 out of it, each 1 to 2,000. `{:ok, changes}`, the fields whose value
  # differs from the run's words, by name (`:complexity`, `:understanding`, `:scope_in`,
  # `:scope_out`, `:approach`), each with its new value in the proposal's form; or
  # `{:error, errors}` by field (`:level`, `:reason`, `:understanding`, `:scope_in`,
  # `:scope_out`, `:approach`): `:blank`, `{:too_long, limit}`, `{:line_too_long, 2000}`,
  # `{:too_many_lines, 50}` or `:characters`; or `{:error, :invalid}` for a form missing a
  # field, giving no text, or naming no level of the three. A scope differs by its
  # entries, each read as one line and trimmed, as the edit page shows and compares them;
  # any other field by its text.
  #
  # `encode/1` and `decode/1` turn changes into the JSON object a confirmation keeps
  # (`Apiary.WorkItems.Confirmation`), and back.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  # result.schema.json: `$defs/short_text` and `$defs/long_text`, the most `questions` and
  # the most entries of `scope.in` and `scope.out`.
  @max_short 2000
  @max_long 20_000
  @max_questions 20
  @max_lines 50
  # The most bytes a scope's text holds: `@max_lines` entries of `@max_short` code points,
  # four bytes each at most, each with its line break.
  @max_scope_bytes @max_lines * (4 * @max_short + 2)
  @levels ~w(simple standard complex)
  # result.schema.json `$defs/text`: the characters a text refuses.
  @refused ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u
  @fields [:complexity, :understanding, :scope_in, :scope_out, :approach]

  @typedoc "A proposal as the work item pages draw it."
  @type t :: %{
          complexity: %{level: :simple | :standard | :complex, reason: String.t()},
          understanding: String.t(),
          scope_in: [String.t()],
          scope_out: [String.t()],
          approach: String.t(),
          alternatives: [%{text: String.t(), reason: String.t()}],
          knowledge: [%{text: String.t(), sources: [String.t()]}]
        }

  @typedoc "A field of a proposal a member may change."
  @type field :: :complexity | :understanding | :scope_in | :scope_out | :approach

  @typedoc "What is wrong with a text a member gives."
  @type error ::
          :blank
          | :characters
          | {:too_long, pos_integer}
          | {:line_too_long, pos_integer}
          | {:too_many_lines, pos_integer}

  # max_answer/0 is the most code points an answer has.
  @doc false
  @spec max_answer() :: pos_integer
  def max_answer, do: @max_short

  # max_questions/0 is the most questions a run asks.
  @doc false
  @spec max_questions() :: pos_integer
  def max_questions, do: @max_questions

  # fields/0 is the fields of a proposal a member may change, in the edit page's order.
  @doc false
  @spec fields() :: [field]
  def fields, do: @fields

  ## The result

  # from_result/1 is the proposal of `result`, a result whose verdict is `understood`.
  @doc false
  @spec from_result(map) :: t
  def from_result(%{"verdict" => "understood"} = result) do
    %{"complexity" => complexity, "scope" => scope, "approach" => approach} = result

    %{
      complexity: %{level: level(complexity["level"]), reason: complexity["reason"]},
      understanding: result["understanding"],
      scope_in: scope["in"],
      scope_out: scope["out"],
      approach: approach["summary"],
      alternatives:
        Enum.map(approach["alternatives"], &%{text: &1["summary"], reason: &1["reason"]}),
      knowledge: Enum.map(result["knowledge"] || [], &%{text: &1["text"], sources: &1["sources"]})
    }
  end

  # questions/1 is the questions of `result`, a result whose verdict is `not_understood`.
  @doc false
  @spec questions(map) :: [String.t()]
  def questions(%{"verdict" => "not_understood", "questions" => questions}), do: questions

  defp level("simple"), do: :simple
  defp level("standard"), do: :standard
  defp level("complex"), do: :complex

  ## The answers

  # check_answers/2 checks the answers a form gives to `questions` (the moduledoc).
  @doc false
  @spec check_answers([String.t()], term) ::
          {:ok, [{pos_integer, String.t(), String.t()}]}
          | {:error, %{String.t() => error} | :invalid}
  def check_answers(questions, answers) when is_list(questions) and is_map(answers) do
    keys = for position <- 1..length(questions)//1, do: Integer.to_string(position)

    if Enum.sort(Map.keys(answers)) == Enum.sort(keys) and
         Enum.all?(Map.values(answers), &is_binary/1) do
      checked =
        questions
        |> Enum.with_index(1)
        |> Enum.map(fn {question, position} ->
          key = Integer.to_string(position)
          {key, position, question, text(answers[key], @max_short)}
        end)

      case for(
             {key, _position, _question, {:error, error}} <- checked,
             into: %{},
             do: {key, error}
           ) do
        errors when errors == %{} ->
          {:ok,
           for(
             {_key, position, question, {:ok, answer}} <- checked,
             do: {position, question, answer}
           )}

        errors ->
          {:error, errors}
      end
    else
      {:error, :invalid}
    end
  end

  def check_answers(_questions, _answers), do: {:error, :invalid}

  ## The changes

  # changes/2 checks the edit page's form against the run's `proposal` (the moduledoc).
  @doc false
  @spec changes(t, term) ::
          {:ok, %{optional(field) => term}} | {:error, %{atom => error} | :invalid}
  def changes(%{complexity: complexity} = proposal, %{
        "complexity" => %{"level" => level, "reason" => reason},
        "understanding" => understanding,
        "scope_in" => scope_in,
        "scope_out" => scope_out,
        "approach" => approach
      })
      when level in @levels and is_binary(reason) and is_binary(understanding) and
             is_binary(scope_in) and is_binary(scope_out) and is_binary(approach) do
    checked = %{
      reason: text(reason, @max_short),
      understanding: text(understanding, @max_long),
      scope_in: entries(scope_in, 1),
      scope_out: entries(scope_out, 0),
      approach: text(approach, @max_short)
    }

    case for({field, {:error, error}} <- checked, into: %{}, do: {field, error}) do
      errors when errors == %{} ->
        values = Map.new(checked, fn {field, {:ok, value}} -> {field, value} end)

        new = %{
          complexity: %{level: level(level), reason: values.reason},
          understanding: values.understanding,
          scope_in: values.scope_in,
          scope_out: values.scope_out,
          approach: values.approach
        }

        old = %{
          complexity: %{level: complexity.level, reason: normal(complexity.reason)},
          understanding: normal(proposal.understanding),
          scope_in: scope(proposal.scope_in),
          scope_out: scope(proposal.scope_out),
          approach: normal(proposal.approach)
        }

        {:ok, for(field <- @fields, new[field] != old[field], into: %{}, do: {field, new[field]})}

      errors ->
        {:error, errors}
    end
  end

  def changes(_proposal, _params), do: {:error, :invalid}

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

  # One entry per line, each trimmed, empty lines left out: at least `min`, at most
  # `@max_lines`, each at most `@max_short` code points. A text past `@max_scope_bytes` is
  # refused before it is cleaned, split or counted (`oversized/1`).
  defp entries(value, _min) when byte_size(value) > @max_scope_bytes,
    do: {:error, oversized(value)}

  defp entries(value, min) do
    with {:ok, value} <- clean(value) do
      lines = split(value)

      cond do
        length(lines) < min ->
          {:error, :blank}

        length(lines) > @max_lines ->
          {:error, {:too_many_lines, @max_lines}}

        Enum.any?(lines, &(byte_size(&1) > 4 * @max_short or code_points(&1) > @max_short)) ->
          {:error, {:line_too_long, @max_short}}

        true ->
          {:ok, lines}
      end
    end
  end

  # Why a scope past `@max_scope_bytes` is refused: more than `@max_lines` lines that are
  # not blank, counted one line break at a time and no further than one past the limit;
  # else a line past `@max_short` code points, as `@max_lines` lines within it fit in
  # `@max_scope_bytes`.
  defp oversized(value) do
    breaks = :binary.compile_pattern(["\r\n", "\r", "\n"])

    if lines(value, breaks, 0, 0) > @max_lines,
      do: {:too_many_lines, @max_lines},
      else: {:line_too_long, @max_short}
  end

  defp lines(_value, _breaks, _from, count) when count > @max_lines, do: count

  defp lines(value, breaks, from, count) do
    case :binary.match(value, breaks, scope: {from, byte_size(value) - from}) do
      {at, length} -> lines(value, breaks, at + length, count + line(value, from, at))
      :nomatch -> count + line(value, from, byte_size(value))
    end
  end

  # 1 for the bytes of `value` from `from` to `to` when they are not blank once trimmed.
  defp line(value, from, to),
    do: if(String.trim(binary_part(value, from, to - from)) == "", do: 0, else: 1)

  defp clean(value) do
    if String.valid?(value) and not Regex.match?(@refused, value),
      do: {:ok, normal(value)},
      else: {:error, :characters}
  end

  # A text as a form gives it back: its line breaks line feeds, trimmed.
  defp normal(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  defp split(text) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # A run's scope as the edit page shows it: each entry one line, its line breaks as
  # spaces, trimmed.
  defp scope(entries) do
    entries
    |> Enum.map(&String.replace(&1, ~r/\s*[\r\n]+\s*/, " "))
    |> Enum.join("\n")
    |> split()
  end

  defp code_points(text), do: text |> String.codepoints() |> length()

  ## Kept

  # encode/1 is `changes` as the JSON object a confirmation keeps.
  @doc false
  @spec encode(%{optional(field) => term}) :: map
  def encode(changes) when is_map(changes) do
    Map.new(changes, fn
      {:complexity, %{level: level, reason: reason}} ->
        {"complexity", %{"level" => Atom.to_string(level), "reason" => reason}}

      {field, value} when field in @fields ->
        {Atom.to_string(field), value}
    end)
  end

  # decode/1 is the changes a confirmation keeps, as `changes/2` gives them.
  @doc false
  @spec decode(map) :: %{optional(field) => term}
  def decode(changes) when is_map(changes) do
    for {name, value} <- changes, field = field(name), field != nil, into: %{} do
      case {field, value} do
        {:complexity, %{"level" => level, "reason" => reason}} ->
          {:complexity, %{level: level(level), reason: reason}}

        {field, value} ->
          {field, value}
      end
    end
  end

  defp field("complexity"), do: :complexity
  defp field("understanding"), do: :understanding
  defp field("scope_in"), do: :scope_in
  defp field("scope_out"), do: :scope_out
  defp field("approach"), do: :approach
  defp field(_other), do: nil
end
