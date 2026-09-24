defmodule Apiary.Body do
  @moduledoc """
  What makes the engine one kind of factory. The engine speaks of a **target** in a
  **system**; a body names them for a domain and says which of a run's labels identify
  the target (its labelling rule). The software body (`Apiary.Body.Software`) calls a
  target a repository and its system a forge.

  Every hive has the software body for now: choosing a body is not built yet, so
  `for_hive/1` answers the same for every hive. Code that reads a run's labels for its
  target asks here and never names a label itself.
  """

  alias Apiary.Organisations.Hive

  @typedoc "A target as a run's labels name it: its system and its path in that system."
  @type target :: %{system: String.t(), path: String.t()}

  @doc """
  The target a run's labels name, by the body's labelling rule: `{:ok, %{system:, path:}}`,
  or `:none` when the labels name none, or name one that cannot be a target's
  (`Apiary.Runs.Target.label/1`). `labels` is untrusted: any map, of any values.
  """
  @callback target(labels :: map) :: {:ok, target} | :none

  @doc "The locale of the body's words on the surface, a GNU `@modifier` variant."
  @callback locale() :: String.t()

  @doc "The body of a hive, by its struct or its id: `Apiary.Body.Software` for every hive."
  @spec for_hive(%Hive{} | Ecto.UUID.t() | nil) :: module
  def for_hive(_hive), do: Apiary.Body.Software

  @doc "The target a run's labels name in the hive: `target/1` of the hive's body."
  @spec target(%Hive{} | Ecto.UUID.t() | nil, term) :: {:ok, target} | :none
  def target(hive, %{} = labels), do: for_hive(hive).target(labels)
  def target(_hive, _labels), do: :none
end
