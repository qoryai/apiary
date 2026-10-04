defmodule ApiaryWeb.JumpController do
  @moduledoc """
  What the palette of the top bar (Search or jump to, `ApiaryWeb.Layouts`) finds for what
  the reader typed. Not a page: JSON the `Palette` hook lists.

      GET /:org/:workspace/jump?q=<text>    on a workspace's pages
      GET /:org/jump?q=<text>               on an organisation's and a person's

  The answer is `{"groups": [{"label", "items": [{"label", "detail", "href", "icon"}]}],
  "status", "empty"}`, the groups in the order they are shown, none left empty, every word
  translated here, in the reader's language and the workspace's domain: the hook holds
  none. `status` is what a screen reader is told; `empty` is what the palette says when
  nothing matches.

  - **Go to**: the pages of the navigation the reader may open (`ApiaryWeb.Layouts.
    palette_entries/1`), every section of each Settings they open
    (`ApiaryWeb.SettingsComponents.sections/2`) and Preferences' theme and shortcuts,
    whose label or other words (members for People) hold the text; all of them for no
    text. A label says whose the page is where a workspace's and an organisation's share a
    name: Workspace overview, Organisation settings › People.
  - **Actions** also hold, for what is typed, the deletions the reader may take, each at
    its confirm's path.
  - **Targets**: the workspace's targets by `system/path` (`Apiary.Runs.search_targets/3`).
  - **Runs**: by the start of their id, a whole id or a run page's address, or by task
    (`Apiary.Runs.search_runs/3`).
  - **Places**: the organisations and workspaces the reader reaches, by name and slug.
  - **Actions**: what New offers here (`ApiaryWeb.Layouts.new_entries/2`), on a
    workspace's page or an organisation's.

  Scoped like the pages: the pipeline resolves the organisation and workspace of the path
  for a member and answers `404` for anybody else. On an organisation's path the answer is
  the organisation's and the person's, never a workspace's, though the scope carries the
  one opened last. Targets and runs are listed only to a reader of the record
  (`run.read`). The palette belongs to the console's record, `observability`, which every
  instance has. What a runner reported (a path, a task) is text in
  the JSON and the hook writes it as text.
  """
  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :observability

  alias Apiary.{Access, Organisations, Runs}
  alias ApiaryWeb.{Layouts, SettingsComponents}
  alias ApiaryWeb.Nav.Entry

  @per_group 8
  @max_text 200

  def show(conn, params) do
    scope = in_path(conn.assigns.current_scope, conn.path_params)
    text = params |> Map.get("q", "") |> text()

    groups =
      [
        go_to(scope, text),
        targets(scope, text),
        runs(scope, text),
        places(scope, text),
        actions(scope, text)
      ]
      |> Enum.reject(&(&1.items == []))

    count = groups |> Enum.map(&length(&1.items)) |> Enum.sum()

    json(conn, %{
      groups: groups,
      status:
        ngettext("%{number} result", "%{number} results", count,
          number: ApiaryWeb.Format.number(count)
        ),
      empty: gettext("Nothing matches “%{text}”.", text: text)
    })
  end

  defp in_path(scope, %{"workspace" => _slug}), do: scope
  defp in_path(scope, _params), do: %{scope | workspace: nil}

  defp text(value) when is_binary(value) do
    value = String.trim(value)
    if String.valid?(value), do: String.slice(value, 0, @max_text), else: ""
  end

  defp text(_value), do: ""

  defp go_to(scope, text) do
    items =
      for {%Entry{} = entry, path} <- destinations(scope),
          label = go_to_label(entry),
          matches?(label <> " " <> also(entry), text),
          do: item(label, where(entry, scope), path, entry.icon)

    group(gettext("Go to"), items)
  end

  # The pages of the navigation, each Settings followed by its sections the navigation
  # does not list (a workspace's People, Runs and Secrets and variables, Workspaces) and Preferences by its own
  # parts, each once: a section is the navigation's entry where both lead to one path. A
  # scope's General is its Settings.
  defp destinations(scope) do
    entries = Layouts.palette_entries(scope)
    paths = MapSet.new(entries, fn {_entry, path} -> path end)

    Enum.flat_map(entries, fn {entry, _path} = pair ->
      [pair | after_entry(entry, scope, paths)]
    end)
  end

  defp after_entry(%Entry{section: :foot, place: place}, scope, paths)
       when place in [:workspace, :organisation] do
    for %Entry{} = section <- SettingsComponents.sections(scope, place),
        section.key not in [:general, :organisation],
        path = Entry.path(section, scope.organisation, scope.workspace),
        not MapSet.member?(paths, path),
        do: {%{section | section: :settings, place: place}, path}
  end

  defp after_entry(%Entry{key: :user_preferences}, _scope, _keys) do
    [
      {%Entry{
         key: :theme,
         label: gettext("Theme"),
         icon: "hero-swatch",
         path: nil,
         place: :person,
         section: :preferences
       }, ~p"/users/settings/preferences#theme"},
      {%Entry{
         key: :shortcuts,
         label: gettext("Keyboard shortcuts"),
         icon: "hero-command-line",
         path: nil,
         place: :person,
         section: :preferences
       }, ~p"/users/settings/preferences#keyboard"}
    ]
  end

  defp after_entry(_entry, _scope, _paths), do: []

  # Entries of the same name in two scopes say whose they are: a workspace's Overview and
  # Settings, an organisation's, and an edition's entry by its `long_label`; a
  # page of Settings names the Settings it is in.
  defp go_to_label(%Entry{long_label: label}) when is_binary(label), do: label
  defp go_to_label(%Entry{key: :overview}), do: gettext("Workspace overview")
  defp go_to_label(%Entry{key: :organisation_overview}), do: gettext("Organisation overview")
  defp go_to_label(%Entry{section: :foot, place: :workspace}), do: gettext("Workspace settings")

  defp go_to_label(%Entry{section: :foot, place: :organisation}),
    do: gettext("Organisation settings")

  defp go_to_label(%Entry{section: :settings, place: :workspace, label: label}),
    do: gettext("Workspace settings › %{page}", page: label)

  defp go_to_label(%Entry{section: :settings, place: :organisation, label: label}),
    do: gettext("Organisation settings › %{page}", page: label)

  defp go_to_label(%Entry{section: :settings, label: label}),
    do: gettext("Settings › %{page}", page: label)

  defp go_to_label(%Entry{section: :preferences, label: label}),
    do: gettext("Preferences › %{page}", page: label)

  defp go_to_label(%Entry{label: label}), do: label

  # The other words a reader may look for a page by.
  defp also(%Entry{key: key}) when key in [:members, :people],
    do: gettext("members users invitations")

  defp also(%Entry{key: :audit_log}), do: gettext("activity history")
  defp also(%Entry{key: :policy}), do: gettext("rules allow deny hosts")
  defp also(%Entry{key: :nodes}), do: gettext("machines runners instances pools")
  defp also(%Entry{key: :runs, section: :settings}), do: gettext("retention prune keep")
  defp also(%Entry{key: :secrets}), do: gettext("secret variable environment token value")
  defp also(%Entry{key: :theme}), do: gettext("dark light appearance")
  defp also(%Entry{section: :foot}), do: gettext("general name slug")
  defp also(%Entry{}), do: ""

  defp where(%Entry{place: :workspace}, scope), do: scope.workspace.name
  defp where(%Entry{place: :organisation}, scope), do: scope.organisation.name
  defp where(%Entry{}, _scope), do: gettext("Your account")

  defp targets(%{workspace: %{} = workspace} = scope, text) when text != "" do
    items =
      if Access.can?(scope, :"run.read", workspace) do
        for target <- Runs.search_targets(scope, text, @per_group) do
          item(
            target.path,
            target.system,
            ApiaryWeb.TargetComponents.target_path(scope, target.system, target.path),
            "hero-folder"
          )
        end
      else
        []
      end

    group(gettext("Targets"), items)
  end

  defp targets(_scope, _text), do: group(gettext("Targets"), [])

  defp runs(%{workspace: %{} = workspace} = scope, text) when text != "" do
    items =
      if Access.can?(scope, :"run.read", workspace) do
        for run <- Runs.search_runs(scope, text, @per_group) do
          item(
            run_label(run),
            run.target_path || ApiaryWeb.RunComponents.state_label(run.state),
            ~p"/#{scope.organisation}/#{workspace}/runs/#{run.run_id}",
            "hero-play-circle"
          )
        end
      else
        []
      end

    group(gettext("Runs"), items)
  end

  defp runs(_scope, _text), do: group(gettext("Runs"), [])

  defp run_label(%{task: task, run_id: run_id}) when is_binary(task) and task != "",
    do: "#{ApiaryWeb.RunComponents.short_id(run_id)} · #{task}"

  defp run_label(%{run_id: run_id}), do: ApiaryWeb.RunComponents.short_id(run_id)

  defp places(%{user: user}, text) when text != "" do
    items =
      for place <- Organisations.list_places(user),
          workspace <- if(place.workspaces == [], do: [nil], else: place.workspaces),
          matches?(place_words(place.organisation, workspace), text) do
        organisation = place.organisation

        if workspace,
          do:
            item(
              "#{organisation.name} / #{workspace.name}",
              nil,
              ~p"/#{organisation}/#{workspace}",
              "hero-squares-2x2"
            ),
          else: item(organisation.name, nil, ~p"/#{organisation}", "hero-building-office-2")
      end

    group(gettext("Places"), Enum.take(items, @per_group))
  end

  defp places(_scope, _text), do: group(gettext("Places"), [])

  defp place_words(organisation, nil), do: "#{organisation.name} #{organisation.slug}"

  defp place_words(organisation, workspace),
    do: "#{organisation.name} #{organisation.slug} #{workspace.name} #{workspace.slug}"

  defp actions(scope, text) do
    place = if scope.workspace, do: :workspace, else: :organisation

    items =
      for %Entry{} = entry <- Layouts.new_entries(scope, place) ++ danger(scope, text),
          matches?(entry.label, text),
          do: item(entry.label, nil, entry.path, entry.icon)

    group(gettext("Actions"), items)
  end

  # The deletions, only for what is typed: each opens its confirm over its danger zone,
  # for a reader who may take it.
  defp danger(_scope, ""), do: []

  defp danger(scope, _text) do
    workspace =
      scope.workspace && Access.can?(scope, :"workspace.delete", scope.workspace) &&
        %Entry{
          key: :delete_workspace,
          label: gettext("Delete workspace %{name}…", name: scope.workspace.name),
          icon: "hero-trash",
          path: ~p"/#{scope.organisation}/#{scope.workspace}/settings/danger"
        }

    organisation =
      Access.can?(scope, :"organisation.delete", scope.organisation) &&
        %Entry{
          key: :delete_organisation,
          label: gettext("Delete organisation %{name}…", name: scope.organisation.name),
          icon: "hero-trash",
          path: ~p"/#{scope.organisation}/settings/danger"
        }

    account = %Entry{
      key: :delete_account,
      label: gettext("Delete your account…"),
      icon: "hero-trash",
      path: ~p"/users/settings/delete"
    }

    Enum.filter([workspace, organisation, account], & &1)
  end

  defp matches?(_words, ""), do: true

  defp matches?(words, text),
    do: String.contains?(String.downcase(words), String.downcase(text))

  defp group(label, items), do: %{label: label, items: items}

  defp item(label, detail, href, icon),
    do: %{label: label, detail: detail, href: href, icon: icon}
end
