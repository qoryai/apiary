defmodule ApiaryProWeb.RequestComponents do
  @moduledoc """
  The components of a policy request (`ApiaryPro.PolicyRequests`), which an operator's
  requests page (`ApiaryProWeb.ClientLive.Requests`) and a client's
  (`ApiaryProWeb.PolicyRequestLive.Index`) share: the changes a request asks for, a line
  each in the words the policy's history says a rule in, and the state of a client's
  answer.

  The lines are the core's diff lines (`ApiaryWeb.PolicyComponents.diff_line/1`) with the
  words of the policy page (`ApiaryWeb.PolicyLive.Common`), so a requested rule reads as a
  rule of the history does. What a request holds comes from an operator's form: hosts
  and paths are only ever interpolated, never `raw/1`.
  """
  use ApiaryProWeb, :html

  import ApiaryWeb.PolicyComponents, only: [diff_line: 1]

  alias ApiaryWeb.PolicyLive.Common

  @doc """
  request_changes/1 renders the changes of a policy request, a line each
  (`request_lines/1`): a rule added, or put in place of the one there, marked +, a rule
  removed marked −, and the mode.
  """
  attr :id, :string, required: true
  attr :lines, :list, required: true

  @spec request_changes(map) :: Phoenix.LiveView.Rendered.t()
  def request_changes(assigns) do
    ~H"""
    <div id={@id} class="q-dlines q-dlines-sem">
      <.diff_line :for={{kind, text} <- @lines} kind={kind}>
        <.rich text={text} />
      </.diff_line>
    </div>
    """
  end

  @doc """
  request_state/1 renders the state of a client's answer to a policy request in words
  (`CoreComponents.state_word/1`), never a pill: the state that needs the reader is lifted,
  a pending request on the client's page (`for={:client}`), a declined one on the
  operator's (`for={:operator}`); the others are muted.
  """
  attr :state, :atom, required: true, values: [:pending, :accepted, :declined, :withdrawn]
  attr :for, :atom, default: :operator, values: [:client, :operator]

  @spec request_state(map) :: Phoenix.LiveView.Rendered.t()
  def request_state(assigns) do
    ~H"""
    <.state_word :if={@state == :pending} hot={@for == :client} tone="info">
      {gettext("Pending")}
    </.state_word>
    <.state_word :if={@state == :accepted}>{gettext("Accepted")}</.state_word>
    <.state_word :if={@state == :declined} hot={@for == :operator} tone="error">
      {gettext("Declined")}
    </.state_word>
    <.state_word :if={@state == :withdrawn}>{gettext("Withdrawn")}</.state_word>
    """
  end

  @doc """
  request_lines/1 is the changes of a policy request (`Apiary.Policy.requested_changes/1`)
  in the words the history says a rule in: a rule added or put in place of the one there
  as added, a rule removed as removed, and the mode last. `[{:add | :del, rich}]`, for
  `request_changes/1`.
  """
  @spec request_lines(map) :: [{:add | :del, term}]
  def request_lines(%{"rules" => rules} = changes) when is_list(rules) do
    lines =
      for %{"change" => change, "rule" => rule} <- rules do
        case change do
          "rule_added" ->
            {:add, Common.rule_words(rule)}

          "rule_changed" ->
            {:add,
             rich_gettext("%{rule}, in place of the rule there", rule: Common.rule_words(rule))}

          "rule_removed" ->
            {:del, removed_words(rule)}
        end
      end

    case changes["mode"] do
      mode when mode in ["observe", "enforce"] -> lines ++ [{:add, Common.mode_line(mode)}]
      _none -> lines
    end
  end

  def request_lines(_changes), do: []

  defp removed_words(%{"host" => host}),
    do: rich_gettext("The rule for %{host}", host: {:code, host})

  @doc """
  request_name/1 is a request by its note's first line, cut to 60 characters: what tells
  one request from another, which may have been sent in the same minute. A note whose
  first line is blank names it "Policy request".
  """
  @spec request_name(%{note: String.t() | nil}) :: String.t()
  def request_name(%{note: note}) do
    line = note |> to_string() |> String.split("\n", parts: 2) |> hd() |> String.trim()

    cond do
      line == "" -> gettext("Policy request")
      String.length(line) > 60 -> String.slice(line, 0, 59) <> "…"
      true -> line
    end
  end

  @doc """
  first_change/1 is the first line of a request's changes (`request_lines/1`) and how
  many more there are, `{line, more}`, for a list's row; nil for a request that changes
  nothing.
  """
  @spec first_change(map) :: {{:add | :del, term}, non_neg_integer} | nil
  def first_change(changes) do
    case request_lines(changes) do
      [line | rest] -> {line, length(rest)}
      [] -> nil
    end
  end

  @doc """
  answer_tally/1 is how many of a request's answers (`%{answer: answer}` each, as
  `ApiaryPro.PolicyRequests.list_sent/1` gives them) are in each state, in the order the
  states are said: accepted, declined, pending and withdrawn, the states with none left
  out.
  """
  @spec answer_tally([%{answer: %{state: atom}}]) :: [{atom, pos_integer}]
  def answer_tally(answers) do
    counts = Enum.frequencies_by(answers, & &1.answer.state)

    for state <- [:accepted, :declined, :pending, :withdrawn],
        Map.get(counts, state, 0) > 0,
        do: {state, counts[state]}
  end
end
