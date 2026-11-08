defmodule Apiary.Stages.Points do
  # Points are what an escalation asks of a person (`Apiary.Stages.Escalation`), each
  # `%{"text", "action", "question"?}` as `verdict.schema.json` has them: `text` is one
  # sentence on what is wrong, and `action` is `answer`, with the id of an open question
  # in `question`, or `run_again`. The page adds the action's sentence. A run writes them
  # in its verdict. For the causes the stage runner sets itself (`round_limit`,
  # `check_failed`, `run_stopped`), this module writes `run_again` points in the default
  # locale's words (`ApiaryWeb.Lingo.default_locale/0`) whatever the calling process's
  # locale. A stopped run's point has `fix`, the stop cause's fix line, where the cause
  # has one: the page shows it in place of the action's sentence. Only Core writes `fix`.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  @typedoc "A point of an escalation."
  @type t :: %{required(String.t()) => String.t()}

  # The words that open a stop cause and are written in lower case after "The run
  # stopped:", as in "The run stopped: a read-only run needs a wall".
  @lowered ~w(The A An)

  # round_limit/2 is the point of a loop that ran `ran` of its `rounds` rounds.
  @doc false
  @spec round_limit(pos_integer, pos_integer) :: [t]
  def round_limit(ran, rounds) do
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

  # check_failed/1 is one point for each output type whose Exists check failed.
  @doc false
  @spec check_failed([String.t()]) :: [t]
  def check_failed(types) do
    for type <- types do
      run_again(
        default(fn ->
          gettext("No %{type} was stored in this stage.", type: type)
        end)
      )
    end
  end

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
