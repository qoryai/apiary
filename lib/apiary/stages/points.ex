defmodule Apiary.Stages.Points do
  # Points are what an escalation asks of a person (`Apiary.Stages.Escalation`), each
  # `%{"text", "action", "question"?, "fix"?}` as `verdict.schema.json` has them, and
  # `"action_in_text"?` on a point of a failed check (below): `text` states what is
  # wrong, and `action` is `answer`, with the id of an open question in `question`, or
  # `run_again`. The page adds the action's sentence. A `run_again` point
  # may have `fix`, a line that the page shows in place of the action's sentence. A run
  # writes points in its verdict, each `text` one sentence of at most 500 characters. For
  # the causes the stage runner sets itself (`round_limit`, `check_failed`, `run_stopped`,
  # `return_limit`), this module writes `run_again` points in the default locale's words
  # (`ApiaryWeb.Lingo.default_locale/0`) whatever the calling process's locale. A stopped
  # run's point has `fix`, the stop cause's fix line, where the cause has one, and the
  # point of a return limit has `fix` with the count of returns. The text of a
  # `round_limit` point with open findings is its sentence followed by the text of each
  # finding, up to the verdict's 20 points, so it is longer than one sentence. A point of
  # a failed check opens with its action, "Run another round:", and has `action_in_text`
  # set to true, so the page adds no action sentence after it.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Artifacts.Type

  @typedoc "A point of an escalation."
  @type t :: %{required(String.t()) => String.t() | true}

  # The words that open a stop cause and are written in lower case after "The run
  # stopped:", as in "The run stopped: a read-only run needs a wall".
  @lowered ~w(The A An)

  # round_limit/4 is the point of a loop that ran `ran` of its `rounds` rounds, with
  # `findings`, the text of each review finding still open, in the verdict's order. The
  # point's text has their number, then each text. Its `fix` is to read them and pick
  # Accept as it is or Run another round, or, with `accept: false` in `opts` (the stage
  # offers no Accept as it is, `Apiary.Stages.Runner.accept_offered?/3`), Run another
  # round alone. With no open finding, the point has the sentence alone and no `fix`.
  @doc false
  @spec round_limit(pos_integer, pos_integer, [String.t()], keyword) :: [t]
  def round_limit(ran, rounds, findings \\ [], opts \\ [])

  def round_limit(ran, rounds, [_ | _] = texts, opts) do
    count = length(texts)
    sentence = default(fn -> open_findings(ran, rounds, count) end)
    fix = default(fn -> findings_fix(count, Keyword.get(opts, :accept, true)) end)
    [Map.put(run_again(Enum.join([sentence | texts], " ")), "fix", fix)]
  end

  def round_limit(ran, rounds, _findings, _opts) do
    [
      run_again(
        default(fn ->
          ngettext("%{ran} of %{count} round ran.", "%{ran} of %{count} rounds ran.", rounds,
            ran: ran
          )
        end)
      )
    ]
  end

  defp findings_fix(count, true),
    do:
      ngettext(
        "Read the open finding, then pick Accept as it is or Run another round.",
        "Read the %{count} open findings, then pick Accept as it is or Run another round.",
        count
      )

  defp findings_fix(count, false),
    do:
      ngettext(
        "Read the open finding, then pick Run another round.",
        "Read the %{count} open findings, then pick Run another round.",
        count
      )

  # The sentence of the rounds that ran with `count` open findings. Its count is the
  # findings', so the word for the rounds is chosen by `rounds` here.
  defp open_findings(ran, 1, count),
    do:
      ngettext(
        "%{ran} of %{limit} round ran, and 1 review finding is still open.",
        "%{ran} of %{limit} round ran, and %{count} review findings are still open.",
        count,
        ran: ran,
        limit: 1
      )

  defp open_findings(ran, rounds, count),
    do:
      ngettext(
        "%{ran} of %{limit} rounds ran, and 1 review finding is still open.",
        "%{ran} of %{limit} rounds ran, and %{count} review findings are still open.",
        count,
        ran: ran,
        limit: rounds
      )

  # check_failed/1 is one point for each output type whose Exists check failed, with the
  # type's words (`Apiary.Artifacts.Type.words/1`): "Run another round: the run stored no
  # acceptance criteria." for `acceptance-criteria`.
  @doc false
  @spec check_failed([String.t()]) :: [t]
  def check_failed(types) do
    for type <- types do
      text =
        default(fn ->
          gettext("Run another round: the run stored no %{type}.", type: Type.words(type))
        end)

      text |> run_again() |> Map.put("action_in_text", true)
    end
  end

  # return_limit/4 is the point of an entry whose run asked for changes after `returns`
  # returns of the work item from the stage `stage` to the earlier stage `to`, the most its
  # return key allows (`Apiary.Stages.Runner`). The member's action comes first, in
  # `text`, and the count after it, in `fix`, which the page shows after the text in place
  # of "Run another round." (the user's ruling of 2026-11-16: the action, then the count
  # of returns, then the findings, which are the verdict's points after this one). The
  # action ends with "or pick Accept as it is", or, with `accept: false` in `opts` (the
  # stage offers no Accept as it is), "or move this stage back".
  @doc false
  @spec return_limit(non_neg_integer, String.t(), String.t(), keyword) :: [t]
  def return_limit(returns, stage, to, opts \\ []) do
    text = default(fn -> return_action(to, Keyword.get(opts, :accept, true)) end)

    count =
      default(fn ->
        ngettext(
          "%{stage}'s run asked for changes again after %{count} return to %{to}, the most that %{stage} allows.",
          "%{stage}'s run asked for changes again after %{count} returns to %{to}, the most that %{stage} allows.",
          returns,
          stage: stage,
          to: to
        )
      end)

    [run_again(text) |> Map.put("fix", count)]
  end

  defp return_action(to, true),
    do:
      gettext(
        "Pick Move back to return the work item to %{to} once more, or pick Accept as it is.",
        to: to
      )

  defp return_action(to, false),
    do:
      gettext(
        "Pick Move back to return the work item to %{to} once more, or move this stage back.",
        to: to
      )

  # no_verdict/0 is the point of a run outside a loop that ended with no verdict
  # (`Apiary.Stages.Runner`).
  @doc false
  @spec no_verdict() :: [t]
  def no_verdict,
    do: [run_again(default(fn -> gettext("The run stopped before its verdict.") end))]

  # run_stopped/2 is the point of a run that stopped, from its stop cause
  # (`Apiary.Stages.StopCause.parts/3`): "The run stopped:" and the cause, with its
  # leading "The run" written as "it", and the cause's fix in `fix` where it has one.
  @doc false
  @spec run_stopped(String.t(), String.t() | nil) :: [t]
  def run_stopped(cause, fix) when is_binary(cause) do
    text = default(fn -> gettext("The run stopped: %{cause}", cause: lowered(cause)) end)
    point = run_again(text)
    [if(fix, do: Map.put(point, "fix", fix), else: point)]
  end

  # The cause after "The run stopped:": "The run" becomes "it", and a sentence that opens
  # with "The", "A" or "An" opens in lower case.
  defp lowered("The run " <> rest), do: "it " <> rest

  defp lowered(cause) do
    case String.split(cause, " ", parts: 2) do
      [first, rest] when first in @lowered -> String.downcase(first) <> " " <> rest
      _other -> cause
    end
  end

  defp run_again(text), do: %{"text" => text, "action" => "run_again"}

  defp default(fun),
    do: Gettext.with_locale(ApiaryWeb.Gettext, ApiaryWeb.Lingo.default_locale(), fun)
end
