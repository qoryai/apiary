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
    palette_entries/1`), the pages of each Settings among them, whose label holds the text;
    all of them for no text.
  - **Targets**: the workspace's targets by `system/path` (`Apiary.Runs.search_targets/3`).
  - **Runs**: by the start of their id, a whole id or a run page's address, or by task
    (`Apiary.Runs.search_runs/3`).
  - **Places**: the organisations and workspaces the reader reaches, by name and slug.
  - **Actions**: what New offers here (`ApiaryWeb.Layouts.new_entries/1`).

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
  alias Apiary.Runs.Filters
  alias ApiaryWeb.Layouts
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
      for {%Entry{} = entry, path} <- Layouts.palette_entries(scope),
          label = go_to_label(entry),
          matches?(label, text),
          do: item(label, where(entry, scope), path, entry.icon)

    group(gettext("Go to"), items)
  end

  # A page of Settings says whose Settings it is part of.
  defp go_to_label(%Entry{section: :settings, label: label}),
    do: gettext("Settings › %{page}", page: label)

  defp go_to_label(%Entry{label: label}), do: label

  defp where(%Entry{place: :workspace}, scope), do: scope.workspace.name
  defp where(%Entry{place: :organisation}, scope), do: scope.organisation.name
  defp where(%Entry{}, _scope), do: gettext("Your account")

  defp targets(%{workspace: %{} = workspace} = scope, text) when text != "" do
    items =
      if Access.can?(scope, :"run.read", workspace) do
        for target <- Runs.search_targets(scope, text, @per_group) do
          query = Filters.target_params(target.system, target.path)

          item(
            target.path,
            target.system,
            ~p"/#{scope.organisation}/#{workspace}/runs?#{query}",
            "hero-folder-micro"
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
            "hero-play-circle-micro"
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
              "hero-squares-2x2-micro"
            ),
          else: item(organisation.name, nil, ~p"/#{organisation}", "hero-building-office-2-micro")
      end

    group(gettext("Places"), Enum.take(items, @per_group))
  end

  defp places(_scope, _text), do: group(gettext("Places"), [])

  defp place_words(organisation, nil), do: "#{organisation.name} #{organisation.slug}"

  defp place_words(organisation, workspace),
    do: "#{organisation.name} #{organisation.slug} #{workspace.name} #{workspace.slug}"

  defp actions(scope, text) do
    items =
      for %Entry{} = entry <- Layouts.new_entries(scope),
          matches?(entry.label, text),
          do: item(entry.label, nil, entry.path, entry.icon)

    group(gettext("Actions"), items)
  end

  defp matches?(_words, ""), do: true

  defp matches?(words, text),
    do: String.contains?(String.downcase(words), String.downcase(text))

  defp group(label, items), do: %{label: label, items: items}

  defp item(label, detail, href, icon),
    do: %{label: label, detail: detail, href: href, icon: icon}
end
