defmodule Apiary.Policy.Activity do
  @moduledoc """
  What the recorded connections say about the rules: see `Apiary.Policy.uncovered/2`,
  `denied_summary/2` and `rule_activity/3`.
  """

  @cap 20_000

  @doc "The most connections one answer reads; beyond it the answer is `:unavailable`."
  def cap, do: @cap

  @doc false
  def uncovered(_scope, _since), do: :unavailable

  @doc false
  def denied_summary(_scope, _since), do: :unavailable

  @doc false
  def rule_activity(_scope, _repository_id, _since), do: :unavailable
end
