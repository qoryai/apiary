defmodule Apiary.Lingo.Domain do
  @moduledoc """
  What makes the engine one kind of work. The engine speaks of a **target** in a
  **system**; a domain names them for one kind of work and says which of a run's labels
  identify the target (its labelling rule). The software domain
  (`Apiary.Lingo.Domain.Software`) calls a target a repository and its system a forge.

  Every workspace has the software domain for now: choosing a domain is not built yet, so
  `for_workspace/1` answers the same for every workspace. Code that reads a run's labels
  for its target asks here and never names a label itself.
  """

  alias Apiary.Organisations.Workspace

  @typedoc "A target as a run's labels name it: its system and its path in that system."
  @type target :: %{system: String.t(), path: String.t()}

  @doc """
  The target a run's labels name, by the domain's labelling rule:
  `{:ok, %{system:, path:}}`, or `:none` when the labels name none, or name one that
  cannot be a target's (`Apiary.Runs.Target.label/1`). `labels` is untrusted: any map, of
  any values.
  """
  @callback target(labels :: map) :: {:ok, target} | :none

  @doc """
  The labels that name a target by the domain's labelling rule, the system's first and
  then the path's: what a page shows first among a run's labels, and links to the target.
  """
  @callback target_labels() :: [String.t()]

  @doc "The locale of the domain's words on the surface, a GNU `@modifier` variant."
  @callback locale() :: String.t()

  @doc "The domain of a workspace, by its struct or its id: `Apiary.Lingo.Domain.Software` for every workspace."
  @spec for_workspace(%Workspace{} | Ecto.UUID.t() | nil) :: module
  def for_workspace(_workspace), do: Apiary.Lingo.Domain.Software

  @doc "The target a run's labels name in the workspace: `target/1` of the workspace's domain."
  @spec target(%Workspace{} | Ecto.UUID.t() | nil, term) :: {:ok, target} | :none
  def target(workspace, %{} = labels), do: for_workspace(workspace).target(labels)
  def target(_workspace, _labels), do: :none

  @doc "The labels that name a target in the workspace: `target_labels/0` of its domain."
  @spec target_labels(%Workspace{} | Ecto.UUID.t() | nil) :: [String.t()]
  def target_labels(workspace), do: for_workspace(workspace).target_labels()
end
