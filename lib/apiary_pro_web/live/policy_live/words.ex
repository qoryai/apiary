defmodule ApiaryProWeb.PolicyLive.Words do
  @moduledoc """
  The words of the organisation's policy page (`ApiaryProWeb.PolicyLive.Organisation`):
  the sentences of its changes, the mode card's and the switch's, the questions and
  confirms with what each changes in every workspace, and toasts, and the counts over its
  workspaces. A change of a rule is said as the workspace's history says one
  (`ApiaryWeb.PolicyLive.Common.change_sentence/4`).
  """
  use Gettext, backend: ApiaryProWeb.Gettext

  import ApiaryWeb.RichText
  import ApiaryWeb.CoreComponents, only: [avatar: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Apiary.Policy.Change
  alias ApiaryWeb.Format
  alias ApiaryWeb.PolicyLive.Common

  @doc """
  change_sentence/3 is the sentence of a change of the organisation's policy
  (`t:ApiaryPro.OrganisationPolicy.change/0`), its author first: rich text. `who` is the
  author's address, shown as its first letter with the address as its tooltip, "Former
  member" once their account is deleted, or nil; `reader` is the reader's address. The
  history lists changes in a table, not in rows that open, so the letter is a tab stop.
  """
  @spec change_sentence(map, String.t() | nil, String.t() | nil) :: list
  def change_sentence(%{change: "floor_changed"} = change, who, reader) do
    if change.after["enforce_everywhere"],
      do:
        rich_gettext("%{who} required enforce in every workspace",
          who: {:b, subject(who, reader)}
        ),
      else:
        rich_gettext("%{who} stopped requiring enforce in every workspace",
          who: {:b, subject(who, reader)}
        )
  end

  def change_sentence(%{change: "switch_changed"} = change, who, reader) do
    if change.after["own_allows"],
      do:
        rich_gettext("%{who} turned on “Workspaces may allow more hosts”",
          who: {:b, subject(who, reader)}
        ),
      else:
        rich_gettext("%{who} turned off “Workspaces may allow more hosts”",
          who: {:b, subject(who, reader)}
        )
  end

  # The core's sentence draws its author's letter for a row that opens, with no tab stop
  # (`Common.change_sentence/4`). Its author is the one rendered part in bold, so that
  # part is put back as a letter with a tab stop.
  def change_sentence(change, who, reader) do
    %Change{
      action: change.change,
      subject: change.subject,
      before: change.before,
      after: change.after,
      target_id: nil
    }
    |> Common.change_sentence(who, nil, reader)
    |> Enum.map(fn
      {:b, %Phoenix.LiveView.Rendered{}} -> {:b, subject(who, reader)}
      piece -> piece
    end)
  end

  # The author of a change: their first letter, with the address as its tooltip
  # (`ApiaryWeb.CoreComponents.avatar/1`), or Qory Apiary for a change nobody made. The
  # letter starts the table's first column, whose box cuts what overflows it, so the
  # tooltip opens to the letter's right.
  defp subject(nil, _reader), do: qory()

  defp subject(who, reader) do
    assigns = %{email: who, reader: reader}
    ~H|<.avatar email={@email} reader={@reader} size="xs" class="tooltip-right" />|
  end

  defp qory, do: gettext("Qory Apiary")

  @doc """
  rendered/2 is the versions a change left the workspaces at, by name: "Main v14 ·
  Platform v9", or nil when no workspace's bytes changed. A workspace since purged is
  left out.
  """
  @spec rendered(map, %{Ecto.UUID.t() => String.t()}) :: String.t() | nil
  def rendered(rendered, names) when is_map(rendered) do
    rendered
    |> Enum.flat_map(fn
      {id, version} when is_integer(version) ->
        case names[id] do
          nil -> []
          name -> [{name, version}]
        end

      _none ->
        []
    end)
    |> Enum.sort()
    |> case do
      [] -> nil
      versions -> Enum.map_join(versions, " · ", fn {name, version} -> "#{name} v#{version}" end)
    end
  end

  def rendered(_rendered, _names), do: nil

  @doc "mode/1 is a mode as the Workspaces tab shows it."
  @spec mode(String.t()) :: String.t()
  def mode("enforce"), do: gettext("Enforce")
  def mode(_observe), do: gettext("Observe")

  @doc """
  allows_off/2 counts, by workspace, the allows the switch leaves out of force when it is
  off, or would when it is on: "3 in Main, 1 in Platform"; nil where there are none.
  """
  @spec allows_off([map], boolean) :: String.t() | nil
  def allows_off(summary, own_allows?) when is_list(summary) do
    summary
    |> Enum.map(&{&1.workspace.name, if(own_allows?, do: &1.own_allows, else: &1.allows_off)})
    |> Enum.filter(fn {_name, n} -> n > 0 end)
    |> case do
      [] ->
        nil

      counts ->
        Enum.map_join(counts, ", ", fn {name, n} ->
          gettext("%{number} in %{workspace}", number: Format.number(n), workspace: name)
        end)
    end
  end

  @doc """
  mode_value/1 is the mode card's value, the floor as it stands: "own" (the mode is set per
  workspace, shown as "Set per workspace") or "enforce" (enforce in every workspace). A
  screen reader hears it after "Mode:".
  """
  @spec mode_value(String.t()) :: String.t()
  def mode_value("enforce"), do: gettext("Enforce required")
  def mode_value(_own), do: gettext("Set per workspace")

  @doc "mode_option/1 is the name of one of the mode card's choices."
  @spec mode_option(String.t()) :: String.t()
  def mode_option("enforce"), do: gettext("Enforce in every workspace")
  def mode_option(_own), do: gettext("Each workspace chooses")

  @doc "mode_line/1 is the sentence under one of the mode card's choices: what it does."
  @spec mode_line(String.t()) :: String.t()
  def mode_line("enforce"),
    do:
      gettext(
        "No workspace or target may observe: a connection no rule allows is denied everywhere."
      )

  def mode_line(_own),
    do: gettext("Each workspace's mode holds, and a target's override where it has one.")

  @doc "mode_now/1 is the mode card's line where the choice picked is the mode now."
  @spec mode_now(String.t()) :: String.t()
  def mode_now("enforce"), do: gettext("Enforce is required in every workspace now.")
  def mode_now(_own), do: gettext("The mode is set per workspace now.")

  @doc """
  floor_now/2 is the mode card's sentence, the floor as it stands: on, what it holds
  everywhere and what each workspace's mode reads; off, what holds instead.
  """
  @spec floor_now(boolean, String.t()) :: String.t()
  def floor_now(true, name),
    do:
      gettext(
        "No workspace or target may observe: a connection no rule allows is denied everywhere. Their mode reads Enforce, required by %{name}.",
        name: name
      )

  def floor_now(false, _name), do: mode_line("own")

  @doc """
  only_owners/2 is who changes the organisation's policy, said to a reader who may not, in
  the mode card and where a change is refused: the owners of `operator`, where the
  operator's owners alone change the policy of its client `name`; an owner otherwise,
  where `operator` is nil.
  """
  @spec only_owners(%{name: String.t()} | nil, String.t()) :: String.t()
  def only_owners(nil, _name), do: gettext("Only an owner changes the organisation's policy.")

  def only_owners(%{name: operator}, name),
    do:
      gettext("Only owners of %{operator}, the operator of %{name}, change its policy.",
        operator: operator,
        name: name
      )

  @doc """
  owners_line/2 is the line above the settings, for a reader who may not change them:
  who changes the policy of `name`, as `only_owners/2` names them, and what it holds.
  """
  @spec owners_line(%{name: String.t()} | nil, String.t()) :: String.t()
  def owners_line(nil, name),
    do:
      gettext("Only owners of %{name} change its policy: these settings and its rules.",
        name: name
      )

  def owners_line(%{name: operator}, name),
    do:
      gettext(
        "Only owners of %{operator}, the operator of %{name}, change its policy: these settings and its rules.",
        operator: operator,
        name: name
      )

  @doc """
  switch_now/2 is the switch's sentence under it, as it stands: rich text whose
  `{:part, :counts}` is the allows it leaves out of force, or would turned off
  (`allows_off/2`); without them where `counts` is nil.
  """
  @spec switch_now(boolean, String.t() | nil) :: list
  def switch_now(true, nil),
    do:
      rich_gettext(
        "Workspace and target allows are in force beside the hosts allowed below. Turning this off would put them out of force, leaving only those hosts allowed anywhere; their denies would still hold."
      )

  def switch_now(true, _counts),
    do:
      rich_gettext(
        "Workspace and target allows are in force beside the hosts allowed below. Turning this off would put them out of force (%{counts}), leaving only those hosts allowed anywhere; their denies would still hold.",
        counts: {:part, :counts}
      )

  def switch_now(false, nil),
    do:
      rich_gettext(
        "Only the hosts allowed below are allowed anywhere. Workspace and target allows stay listed, and are not in force; their denies still hold."
      )

  def switch_now(false, _counts),
    do:
      rich_gettext(
        "Only the hosts allowed below are allowed anywhere. Workspace and target allows stay listed, and are not in force (%{counts}); their denies still hold.",
        counts: {:part, :counts}
      )

  @doc "leaves_out/1 is the confirm's count of the allows the switch would leave out of force."
  @spec leaves_out([map]) :: String.t()
  def leaves_out(summary) do
    total = summary |> Enum.map(& &1.own_allows) |> Enum.sum()

    case allows_off(summary, true) do
      nil ->
        gettext("No workspace has an allow rule now, so nothing is left out of force.")

      counts ->
        ngettext(
          "It leaves %{number} allow out of force: %{counts}.",
          "It leaves %{number} allows out of force: %{counts}.",
          total,
          number: Format.number(total),
          counts: counts
        )
    end
  end

  @doc """
  floor_preview/2 is what the floor turned to `to` changes, one sentence a workspace whose
  mode or whose targets' modes change, from the workspaces' summary: the workspaces and
  targets that set observe for themselves enforce from now on, or observe again. A
  workspace where nothing changes is left out; nil where none changes.
  """
  @spec floor_preview([map], boolean) :: [String.t()] | nil
  def floor_preview(summary, to) when is_list(summary) do
    case Enum.flat_map(summary, &floor_line(&1, to)) do
      [] -> nil
      lines -> lines
    end
  end

  defp floor_line(%{own_mode: "observe", targets_observing: 0, workspace: w}, true),
    do: [gettext("%{workspace} enforces from now on.", workspace: w.name)]

  defp floor_line(%{own_mode: "observe", targets_observing: n, workspace: w}, true),
    do: [
      ngettext(
        "%{workspace} enforces from now on, and so does %{number} target of it that set observe for itself.",
        "%{workspace} enforces from now on, and so do %{number} targets of it that set observe for themselves.",
        n,
        workspace: w.name,
        number: Format.number(n)
      )
    ]

  defp floor_line(%{own_mode: "observe", targets_observing: 0, workspace: w}, false),
    do: [gettext("%{workspace} observes again.", workspace: w.name)]

  defp floor_line(%{own_mode: "observe", targets_observing: n, workspace: w}, false),
    do: [
      ngettext(
        "%{workspace} observes again, and so does %{number} target of it that set observe for itself.",
        "%{workspace} observes again, and so do %{number} targets of it that set observe for themselves.",
        n,
        workspace: w.name,
        number: Format.number(n)
      )
    ]

  defp floor_line(%{targets_observing: 0}, _to), do: []

  defp floor_line(%{targets_observing: n, workspace: w}, true),
    do: [
      ngettext(
        "In %{workspace}, %{number} target that set observe for itself enforces from now on.",
        "In %{workspace}, %{number} targets that set observe for themselves enforce from now on.",
        n,
        workspace: w.name,
        number: Format.number(n)
      )
    ]

  defp floor_line(%{targets_observing: n, workspace: w}, false),
    do: [
      ngettext(
        "In %{workspace}, %{number} target that set observe for itself observes again.",
        "In %{workspace}, %{number} targets that set observe for themselves observe again.",
        n,
        workspace: w.name,
        number: Format.number(n)
      )
    ]

  @doc """
  floor_unchanged/1 is the floor's confirm where it changes no mode: every workspace and
  target enforces already, or none set observe for itself.
  """
  @spec floor_unchanged(boolean) :: String.t()
  def floor_unchanged(true),
    do: gettext("Every workspace and target enforces already, so no mode changes now.")

  def floor_unchanged(false),
    do:
      gettext(
        "No workspace or target set observe for itself, so each keeps enforcing; from now on one may observe."
      )

  @doc """
  puts_back/2 is the switch's confirm, turned on: the workspace allows it puts
  back in force, by workspace, but where the organisation denies the host.
  """
  @spec puts_back([map], String.t()) :: String.t()
  def puts_back(summary, name) do
    total = summary |> Enum.map(& &1.own_allows) |> Enum.sum()

    case allows_off(summary, true) do
      nil ->
        gettext("No workspace has an allow rule now, so nothing comes back into force.")

      counts ->
        ngettext(
          "It puts %{number} allow back in force: %{counts}, but where %{name} denies the host.",
          "It puts %{number} allows back in force: %{counts}, but where %{name} denies the host.",
          total,
          number: Format.number(total),
          counts: counts,
          name: name
        )
    end
  end

  @doc "versions/0 is the confirms' last sentence: what a change of a setting writes."
  @spec versions() :: String.t()
  def versions,
    do:
      gettext(
        "Each workspace whose policy this changes gets a new version of it. You can turn it back at any time."
      )

  @doc "setting_title/2 is the confirm's question of a setting turned to `to`."
  @spec setting_title(:floor | :switch, boolean) :: String.t()
  def setting_title(:floor, true), do: gettext("Require enforce in every workspace?")
  def setting_title(:floor, false), do: gettext("Stop requiring enforce in every workspace?")
  def setting_title(:switch, true), do: gettext("Let workspaces allow more hosts?")
  def setting_title(:switch, false), do: gettext("Allow only the organisation's hosts?")

  @doc "setting_effect/3 is the confirm's first sentence: what the setting does."
  @spec setting_effect(:floor | :switch, boolean, String.t()) :: String.t()
  def setting_effect(:floor, true, name),
    do:
      gettext(
        "No workspace or target may observe from now on: a connection no rule allows is denied everywhere, and their mode reads Enforce, required by %{name}.",
        name: name
      )

  def setting_effect(:floor, false, _name),
    do: gettext("Each workspace's mode holds again, and a target's override where it has one.")

  def setting_effect(:switch, true, _name),
    do: gettext("Workspace and target allows are in force again, beside the organisation's.")

  def setting_effect(:switch, false, name),
    do:
      gettext(
        "Only the hosts %{name} allows are allowed anywhere: a workspace's or a target's allows stay listed, and are not in force; their denies still hold.",
        name: name
      )

  @doc "setting_button/2 is the confirm's button."
  @spec setting_button(:floor | :switch, boolean) :: String.t()
  def setting_button(:floor, true), do: gettext("Require enforce")
  def setting_button(:floor, false), do: gettext("Stop requiring enforce")
  def setting_button(:switch, true), do: gettext("Let workspaces allow hosts")
  def setting_button(:switch, false), do: gettext("Allow only the organisation's hosts")

  @doc "setting_sentence/2 is the toast of a setting turned."
  @spec setting_sentence(:floor | :switch, boolean) :: String.t()
  def setting_sentence(:floor, true), do: gettext("Enforce is required in every workspace.")
  def setting_sentence(:floor, false), do: gettext("Enforce is no longer required.")
  def setting_sentence(:switch, true), do: gettext("Workspaces may allow more hosts.")
  def setting_sentence(:switch, false), do: gettext("Only the organisation's hosts are allowed.")

  @doc "setting_announce/2 is what the polite region says of a setting turned."
  @spec setting_announce(:floor | :switch, boolean) :: String.t()
  def setting_announce(:floor, _to), do: gettext("Floor changed.")
  def setting_announce(:switch, _to), do: gettext("Switch changed.")
end
