defmodule ApiaryWeb.Narrowing do
  @moduledoc """
  A list narrowed to targets, Runs or Network access (the narrowing ruling): which targets
  its address names, read once with the address (`read/2`, from the lists'
  `handle_params/3`), before the page renders. So the narrowed line, its links, the rail's
  current target, the Filter menu's choice and the sidebar's carry name the targets rightly
  from the first render, and never the targets of the address before.

  The address names a target by the id Qory Apiary gives it (`?target=tg_…`), several by
  their ids joined by commas (`Apiary.Runs.Filters`). The read is one query, scoped to the
  workspace: an id that names no target of the workspace, another workspace's among them,
  is not among the targets it finds, and the list drops it (`drop_unknown/2`) as it drops
  any value it does not know. A target is named by its path, with its system where
  another target of the workspace has the same path. The targets of one path on two
  systems or more make one line that names each system (`shared_sentence/3`), the same on
  both lists, each system a link to the list narrowed to that system's target.

  What a reader types (`repo:acme/shop`) is the ids of the targets it names (`typed/2`). A
  name that names no target is search text the query keeps (`{:name, text}`,
  `Apiary.Runs.Filters`): the list matches nothing, no run and no destination, and its line
  names the text as typed, with no page or policy to lead to.
  """
  use ApiaryWeb, :html

  import Ecto.Query, only: [from: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Filters, Target}

  @typedoc """
  The targets a list's filters name: `for`, the ids it was read for; `targets`, the
  targets of the workspace with those ids, in their order, each with `shared`, whether
  another target of the workspace has its path.
  """
  @type t :: %{
          for: [String.t()],
          targets: [%{target: Target.t(), shared: boolean}]
        }

  @doc """
  read/2 is what the filters' target names among the workspace's targets (`t:t/0`): one
  read, scoped to the workspace. Nil for no target, or `:none`.
  """
  @spec read(Scope.t(), Filters.target()) :: t | nil
  def read(%Scope{organisation: organisation, workspace: workspace}, [_ | _] = ids) do
    found =
      Repo.all(
        from t in Target,
          where:
            t.organisation_id == ^organisation.id and t.workspace_id == ^workspace.id and
              t.public_id in ^ids,
          select: %{
            target: t,
            shared:
              fragment(
                "EXISTS (SELECT 1 FROM targets o WHERE o.workspace_id = ? AND o.path = ? AND o.id <> ?)",
                t.workspace_id,
                t.path,
                t.id
              )
          }
      )
      |> Map.new(&{&1.target.public_id, &1})

    %{for: ids, targets: for(id <- ids, found = found[id], do: found)}
  end

  def read(%Scope{}, _target), do: nil

  @doc """
  drop_unknown/2 is the filters without the ids the read found no target for, and with
  `target` among what was dropped when there were any, as the parse drops a value it does
  not know: the list's address is then written again without them, and the page says the
  link was not read in full.
  """
  @spec drop_unknown(Filters.t(), t | nil) :: Filters.t()
  def drop_unknown(%Filters{target: [_ | _] = ids} = filters, %{for: ids, targets: targets}) do
    known = Enum.map(targets, & &1.target.public_id)

    if known == ids,
      do: filters,
      else: %{
        filters
        | target: if(known != [], do: known),
          dropped: Enum.uniq(filters.dropped ++ ["target"])
      }
  end

  def drop_unknown(%Filters{} = filters, _narrowing), do: filters

  @doc """
  one/1 is the one target the filters name, nil for none or several.
  """
  @spec one(t | nil) :: Target.t() | nil
  def one(%{targets: [%{target: target}]}), do: target
  def one(_narrowing), do: nil

  @doc """
  path/1 is the path the narrowed line names: the one target's, or the path every target
  named is on; nil for none, or for targets on different paths, which no line names.
  """
  @spec path(t | nil) :: String.t() | nil
  def path(%{targets: [%{target: %{path: path}} | _] = targets}) do
    if Enum.all?(targets, &(&1.target.path == path)), do: path
  end

  def path(_narrowing), do: nil

  @doc """
  chosen/2 is what the rail marks: the targets named, as their rail entries
  (`%{public_id:, system:, path:}`), none for a typed name that names no target, `:none`
  for the runs with none, nil for every target.
  """
  @spec chosen(t | nil, Filters.target()) :: [map] | :none | nil
  def chosen(_narrowing, :none), do: :none
  def chosen(_narrowing, {:name, _name}), do: []

  def chosen(%{targets: [_ | _] = targets}, [_ | _]),
    do:
      for(%{target: t} <- targets, do: %{public_id: t.public_id, system: t.system, path: t.path})

  def chosen(_narrowing, _target), do: nil

  @doc """
  shared_alone?/1 says whether the filters name two targets or more on one path: no one
  target, and the line names each system.
  """
  @spec shared_alone?(t | nil) :: boolean
  def shared_alone?(%{targets: [_, _ | _]} = narrowing), do: is_binary(path(narrowing))
  def shared_alone?(_narrowing), do: false

  @doc """
  shared?/1 says whether the narrowed path is on two systems or more: the system is
  written only then.
  """
  @spec shared?(t | nil) :: boolean
  def shared?(%{targets: [_, _ | _]} = narrowing), do: shared_alone?(narrowing)
  def shared?(%{targets: [%{shared: shared}]}), do: shared
  def shared?(_narrowing), do: false

  @doc """
  The system the line writes before the path: the one target's, where another system
  has its path; none otherwise.
  """
  @spec shown_system(t | nil) :: String.t() | nil
  def shown_system(%{targets: [%{target: target, shared: true}]}), do: target.system
  def shown_system(_narrowing), do: nil

  @doc """
  The paths the targets named are on and that another system shares, for the page's
  names: what `Apiary.Runs.shared_paths/2` gives, known from the read at once.
  """
  @spec shared_paths(t | nil) :: [String.t()]
  def shared_paths(%{targets: targets}),
    do: for(%{shared: true, target: t} <- targets, uniq: true, do: t.path)

  def shared_paths(_narrowing), do: []

  @doc """
  text/2 is the filters' target as the query and the Filter menu write it: `none`; the
  path every target named is on; else each target's name, its system before its path only
  where another system has the path, joined by commas.
  """
  @spec text(t | nil, Filters.target()) :: String.t() | nil
  def text(_narrowing, :none), do: "none"
  def text(_narrowing, {:name, name}), do: name

  def text(%{targets: [_ | _] = targets} = narrowing, [_ | _]) do
    if shared_alone?(narrowing),
      do: path(narrowing),
      else: Enum.map_join(targets, ",", &name/1)
  end

  def text(_narrowing, target), do: Filters.target_value(target)

  defp name(%{target: target, shared: true}), do: "#{target.system}/#{target.path}"
  defp name(%{target: target}), do: target.path

  @doc """
  carried/2 is what the sidebar's Runs and Network access carry on a list narrowed to the
  targets of one path, or to a typed name (`ApiaryWeb.Layouts.app/1`'s `narrowed`): the
  filters' target, which the carried links write as the list does
  (`Apiary.Runs.Filters.target_params/1`), and the name the line gives it. Nil for no
  target, for `:none` and for targets on different paths.
  """
  @spec carried(t | nil, Filters.target()) :: map | nil
  def carried(_narrowing, {:name, name} = target),
    do: %{target: target, system: nil, path: name}

  def carried(narrowing, [_ | _] = target) do
    case path(narrowing) do
      nil -> nil
      path -> %{target: target, system: shown_system(narrowing), path: path}
    end
  end

  def carried(_narrowing, _target), do: nil

  @doc """
  typed/2 is the ids of the targets a typed `repo:` or `target:` names: the ids given, or
  the target of a name (`Apiary.Runs.resolve_target/2`); nil for a name that names none.
  """
  @spec typed(Scope.t(), String.t()) :: [String.t()] | nil
  def typed(%Scope{} = scope, text) do
    Filters.ids(text) || Runs.resolve_target(scope, text)
  end

  @doc """
  shared_sentence/3 is the line of a list narrowed to the targets of one path on two
  systems or more: "Showing acme/shop only, on git.example and code.example.", the systems in
  their order, one sentence on Runs and on Network access, each system a link (`id` and
  its system) to the same list narrowed to that system's target (`link`, a function of
  its ids, `[tg_…]`).
  """
  @spec shared_sentence(t, String.t(), (Filters.target() -> String.t())) :: term
  def shared_sentence(%{targets: targets} = narrowing, id, link) do
    links =
      for %{target: target} <- Enum.sort_by(targets, & &1.target.system),
          do:
            system_link(%{
              id: "#{id}-on-#{dom_token({target.system, target.path})}",
              system: target.system,
              to: link.([target.public_id])
            })

    {before, [last]} = Enum.split(links, -1)

    # The count is the systems before the last: one is "a and b", more is "a, b, and c".
    rich_ngettext(
      "Showing %{name} only, on %{first} and %{last}.",
      "Showing %{name} only, on %{list}, and %{last}.",
      length(before),
      name: name_of_path(%{path: path(narrowing)}),
      first: List.first(before),
      list: Enum.intersperse(before, ", "),
      last: last
    )
  end

  defp name_of_path(assigns) do
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
