defmodule ApiaryWeb.Nav.Entry do
  @moduledoc """
  An entry of the console's navigation, as data: a link of the sidebar, which the core and
  the edition (`c:ApiaryWeb.Edition.nav_entries/1`) each give, one of the organisation
  switcher's below the places it switches to (`c:ApiaryWeb.Edition.switcher_entries/1`),
  or a section of the settings (`ApiaryWeb.SettingsComponents`, and the edition's of the
  organisation's, `c:ApiaryWeb.Edition.settings_tabs/1`).
  `ApiaryWeb.Layouts` decides from these which to show and where they lead, and nothing
  else does.

  - `section`: where the entry goes in its scope's sidebar: `:home` (the scope's first
    entries, without a heading), `:record` or `:guard` (a workspace's groups), a section of
    the edition's (`c:ApiaryWeb.Edition.nav_sections/0`), `:foot` (Settings, at the
    sidebar's foot) or `:settings` (a page of the scope's Settings, not in the sidebar: its
    page marks Settings as the current entry). An edition's entry goes after the
    core's of its section. A section of the settings is in `:main` or `:edition`. Nil
    outside the sidebar.
  - `key`: names the entry. A page passes it as its `nav` to be marked the current one,
    and it gives the DOM id: `nav-<key>` in the sidebar, `organisation-menu-<key>` in the
    switcher, `settings-tab-<key>` in the list of a page of settings.
  - `label`: its words, translated by whoever gives the entry.
  - `icon`: a heroicon's name, as `<.icon>` takes it.
  - `path`: where it leads: a path, or a function of the organisation and the workspace
    that returns one; the workspace is nil for an organisation's entry where the reader
    reaches none yet.
  - `place`: the scope the page belongs to, which decides the sidebar it shows:
    `:workspace` for a page of a workspace, which has no entry while the reader reaches
    none; `:organisation` for a page of the organisation, which opens without one;
    `:person` for a person's own page (`/users/…`).
  - `action`: the `Apiary.Access` action the page is for, asked with `can?/3` of the
    workspace, or of the organisation without one; nil for an entry every member has. A
    feature that is off takes its actions with it, and so its entries.
  - `count`: the key of the counts (`ApiaryWeb.UserAuth.nav_counts/1`) whose number shows
    beside the entry, or nil.
  - `filter`: nil, or a function of the scope and the counts for an entry that is not
    there wherever its action is allowed: the entry shows only where it returns true.
  """

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}

  @enforce_keys [:key, :label, :path]
  defstruct section: nil,
            key: nil,
            label: nil,
            icon: nil,
            path: nil,
            place: :workspace,
            action: nil,
            count: nil,
            filter: nil

  @type path :: String.t() | (%Organisation{}, %Workspace{} | nil -> String.t())

  @type t :: %__MODULE__{
          section: atom | nil,
          key: atom,
          label: String.t(),
          icon: String.t() | nil,
          path: path,
          place: :workspace | :organisation | :person,
          action: atom | nil,
          count: atom | nil,
          filter: (Scope.t(), map | nil -> boolean) | nil
        }

  @doc """
  path/3 is where `entry` leads in `workspace` of `organisation`: its path, or what its
  path function returns for them.
  """
  @spec path(t, %Organisation{} | nil, %Workspace{} | nil) :: String.t()
  def path(%__MODULE__{path: path}, _organisation, _workspace) when is_binary(path), do: path

  def path(%__MODULE__{path: path}, organisation, workspace) when is_function(path, 2),
    do: path.(organisation, workspace)
end
