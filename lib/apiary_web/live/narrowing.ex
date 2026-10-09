defmodule ApiaryWeb.Narrowing do
  @moduledoc """
  A list narrowed to one target, Runs or Network access (the narrowing ruling): which
  target its address names, read once with the address (`read/2`, from the lists'
  `handle_params/3`), before the page renders. So the narrowed line, its links, the rail's
  current target, the Filter menu's choice and the sidebar's carry name the target rightly
  from the first render, and never the target of the address before.

  A path with its system (`?system=gitlab.com&target=acme/shop`) is that one target. A
  path alone (`?target=acme/shop`) is the one target of the workspace on that path; where
  two targets or more share the path, it is the path on each of their systems, and the
  line says so in one sentence, the same on both lists (`shared_sentence/3`), each system
  a link to the list narrowed to that system's target.

  What a reader types (`repo:acme/shop`) is written as the links write it, the system only
  where the path is shared (`typed/2`).
  """
  use ApiaryWeb, :html

  import Ecto.Query, only: [from: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Target}

  # More systems than any workspace gives one path; the sentence names each it reads.
  @max_systems 20

  @typedoc """
  The target a list's filters name: `for`, the filters' `{system, path}` it was read for;
  `target`, the one target they name (nil for a path shared and given alone, or for none);
  `systems`, the systems the path is on, in order; `shared`, whether it is on two or more.
  """
  @type t :: %{
          for: {String.t() | nil, String.t()},
          target: Target.t() | nil,
          systems: [String.t()],
          shared: boolean
        }

  @doc """
  read/2 is what the filters' target names among the workspace's targets (`t:t/0`): one
  read of the targets on its path. Nil for no target, or `:none`.
  """
  @spec read(Scope.t(), Filters.target()) :: t | nil
  def read(%Scope{} = scope, {system, path} = target) when is_binary(path) do
    on_path = targets_on(scope, path)

    found =
      case {system, on_path} do
        {system, on_path} when is_binary(system) -> Enum.find(on_path, &(&1.system == system))
        {nil, [one]} -> one
        _none_or_several -> nil
      end

    %{
      for: target,
      target: found,
      systems: Enum.map(on_path, & &1.system),
      shared: length(on_path) > 1
    }
  end

  def read(%Scope{}, _target), do: nil

  # The workspace's targets on `path`, by their system: a read of the lists' own.
  defp targets_on(%Scope{organisation: organisation, workspace: workspace}, path) do
    Repo.all(
      from t in Target,
        where:
          t.organisation_id == ^organisation.id and t.workspace_id == ^workspace.id and
            t.path == ^path,
        order_by: [asc: t.system],
        limit: @max_systems
    )
  end

  @doc """
  chosen/2 is the target the rail marks and the Filter menu holds: the one target read,
  as its `{system, path}`, so a path given alone is its target's; else the filters' own.
  """
  @spec chosen(t | nil, Filters.target()) :: Filters.target()
  def chosen(%{target: %Target{system: system, path: path}}, _target), do: {system, path}
  def chosen(_narrowing, target), do: target

  @doc """
  shared_alone?/1 says whether the filters give a path alone that two targets or more
  share: no one target, and the line names each system.
  """
  @spec shared_alone?(t | nil) :: boolean
  def shared_alone?(%{for: {nil, _path}, target: nil, shared: true}), do: true
  def shared_alone?(_narrowing), do: false

  @doc """
  shared?/1 says whether the narrowed path is on two systems or more: the system is
  written, and carried, only then.
  """
  @spec shared?(t | nil) :: boolean
  def shared?(%{shared: shared}), do: shared
  def shared?(_narrowing), do: false

  @doc """
  The system the line writes before the path: the filters' own where the path is shared,
  or where it names no target of the workspace (the address says which it meant); none
  otherwise, as the target is addressed.
  """
  @spec shown_system(t | nil) :: String.t() | nil
  def shown_system(%{for: {system, _path}, shared: shared, target: target}),
    do: if(shared or is_nil(target), do: system)

  def shown_system(_narrowing), do: nil

  @doc """
  typed/2 is the target a typed `repo:` or `target:` names (`Apiary.Runs.resolve_target/2`),
  as the links write it: the system only where the path is shared.
  """
  @spec typed(Scope.t(), String.t()) :: {String.t() | nil, String.t()}
  def typed(%Scope{} = scope, text) do
    case Runs.resolve_target(scope, text) do
      {system, path} when is_binary(system) ->
        Filters.link_target({system, path}, Runs.shared_paths(scope, [path]))

      several_or_none ->
        several_or_none
    end
  end

  @doc """
  shared_sentence/3 is the line of a list narrowed to a path that two targets or more
  share, given alone: "Showing acme/shop only, on github.com and gitlab.com.", one
  sentence on Runs and on Network access, each system a link (`id` and its system) to the
  same list narrowed to that system's target (`link`, a function of `{system, path}`).
  """
  @spec shared_sentence(t, String.t(), (Filters.target() -> String.t())) :: term
  def shared_sentence(%{for: {_system, path}, systems: systems}, id, link) do
    links =
      for system <- systems,
          do:
            system_link(%{
              id: "#{id}-on-#{dom_token({system, path})}",
              system: system,
              to: link.({system, path})
            })

    {before, [last]} = Enum.split(links, -1)

    # The count is the systems before the last: one is "a and b", more is "a, b, and c".
    rich_ngettext(
      "Showing %{name} only, on %{first} and %{last}.",
      "Showing %{name} only, on %{list}, and %{last}.",
      length(before),
      name: name(%{path: path}),
      first: List.first(before),
      list: Enum.intersperse(before, ", "),
      last: last
    )
  end

  defp name(assigns) do
    ~H"""
    <span class="q-narrowed-name"><.target_name path={@path} /></span>
    """
  end

  defp system_link(assigns) do
    ~H"""
    <.link id={@id} patch={@to} class="q-link font-mono">{@system}</.link>
    """
  end

  @doc """
  The way back to the page's title when a narrowed line goes while focus is in it ("Show
  all runs" took the narrowing away): a command for the line's `phx-remove`, which moves
  focus only from inside the line, so a rail's "All targets", which stays, keeps it.
  """
  @spec focus_title(String.t()) :: JS.t()
  def focus_title(line_id),
    do: JS.focus(to: "header:has(##{line_id}:focus-within) #page-header-title")
end
