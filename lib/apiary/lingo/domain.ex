defmodule Apiary.Lingo.Domain do
  @moduledoc """
  What makes the engine one kind of work. The engine speaks of a **target** in a
  **system**; a domain names them for one kind of work and says which of a run's labels
  identify the target (its labelling rule). The software domain
  (`Apiary.Lingo.Domain.Software`) calls a target a repository and its system a forge.

  A workspace has its domain, stored by name in `workspaces.domain` and chosen when it is
  created; every member of the workspace reads the same words. `domains/0` is the registry
  of the domains there are, by name; `for_workspace/1` reads a workspace's through it.
  The software domain is the only one and the default: a workspace is created with it,
  and a render outside any workspace reads it. Whether a workspace may change its domain
  later is not decided, and nothing changes it. Code that reads a run's labels for its
  target asks here and never names a label itself.
  """

  alias Apiary.Organisations.Workspace

  # Every domain there is, by the name a workspace stores. A new domain is a module here
  # and a catalogue per language (`docs/lingo.md`), never a migration. The tests register
  # one more of their own (`config/test.exs`), so they see a workspace's domain read
  # through the registry and not assumed.
  @domains Map.merge(
             %{"software" => Apiary.Lingo.Domain.Software},
             Application.compile_env(:apiary, [__MODULE__, :test_domains], %{})
           )
  @default Apiary.Lingo.Domain.Software

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

  @doc """
  The domain's name: what a workspace of the domain stores, and the GNU `@modifier` of its
  locales (`software` of `en@software`).
  """
  @callback name() :: String.t()

  @doc "The domains there are, by name."
  @spec domains() :: %{String.t() => module}
  def domains, do: @domains

  @doc "The names of the domains there are, sorted: what a workspace's domain may be."
  @spec names() :: [String.t()]
  def names, do: @domains |> Map.keys() |> Enum.sort()

  @doc """
  The default domain, `Apiary.Lingo.Domain.Software`: a new workspace's, and the one read
  outside any workspace.
  """
  @spec default() :: module
  def default, do: @default

  @doc """
  The domain of a workspace, through `domains/0`, by the name its struct carries: the
  caller loads the workspace, and nothing here reads the database. Without a workspace,
  or for one whose stored name no domain has any more, it is `default/0`.
  """
  @spec for_workspace(%Workspace{} | nil) :: module
  def for_workspace(%Workspace{domain: name}), do: Map.get(@domains, name, @default)
  def for_workspace(nil), do: @default

  @doc "The target a run's labels name in the workspace: `target/1` of the workspace's domain."
  @spec target(%Workspace{} | nil, term) :: {:ok, target} | :none
  def target(workspace, %{} = labels), do: for_workspace(workspace).target(labels)
  def target(_workspace, _labels), do: :none

  @doc "The labels that name a target in the workspace: `target_labels/0` of its domain."
  @spec target_labels(%Workspace{} | nil) :: [String.t()]
  def target_labels(workspace), do: for_workspace(workspace).target_labels()
end
