defmodule Apiary.Kinds.Placeholders do
  @moduledoc """
  Placeholders answers whether a variable name may carry a connection's placeholder: the
  variable the enclosure gets set to the placeholder value, so that an agent's client has
  something to send, which the gateway, or a tool, replaces.

  The contract refuses such a name, `placeholder_conflict`, when it is Forager's own
  (`QORY_*`), on the built-in deny list, or a name Forager, a runtime or the harness
  sets, and the server refuses the same on save, for the names it knows then: a tool
  role's `placeholders` in an integration's description, and a service declaration's
  `name`. The names Apiary knows are `Apiary.Variables.Denied`'s list and pattern, matched
  without case, and every variable a runtime of the catalogue declares or reserves
  (`Apiary.Kinds.Runtimes.variables/0`), matched exactly.
  """

  alias Apiary.Kinds.Runtimes
  alias Apiary.Variables.Denied

  @doc "conflict?/1 says whether `name` may not carry a connection's placeholder."
  @spec conflict?(String.t()) :: boolean
  def conflict?(name) when is_binary(name) do
    Denied.refused?(name) or Denied.denied?(name) or name in Runtimes.variables()
  end

  @doc "conflicts/1 is the names of `names` that may not carry a placeholder, in order."
  @spec conflicts([String.t()]) :: [String.t()]
  def conflicts(names) when is_list(names), do: Enum.filter(names, &conflict?/1)
end
