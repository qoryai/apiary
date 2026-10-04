defmodule ApiaryWeb.Prototype.Live do
  @moduledoc """
  The navigation prototype's one LiveView (`ApiaryWeb.Prototype`): it reads the page from
  its path (`ApiaryWeb.Prototype.page/2`) and draws it in the shell of its level. Every
  link is a `patch`, so the prototype moves without a reload and survives one on any page.

  Who reads the pages, an owner, an admin or a member, is the account menu's choice: the
  `as` parameter of the path it patches to, kept by the LiveView until a reload.
  """
  use Phoenix.LiveView

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.{NodePages, OrganisationPages, RepositoryPages}
  alias ApiaryWeb.Prototype.{SettingsPages, Shell, WorkspacePages}

  @roles %{"owner" => :owner, "admin" => :admin, "member" => :member}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, role: :admin, approved: MapSet.new())}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    role = Map.get(@roles, params["as"], socket.assigns.role)
    path = if query, do: "#{path}?#{query}", else: path
    {:noreply, assign(socket, at(Map.get(params, "path", []), params, path, role))}
  end

  @doc """
  at/4 is what the page at `segments` (the path after `/dev/prototype`), with its query
  `params`, draws for `role`: the page, its parameters, its path and its title.
  """
  def at(segments, params, path, role) do
    page =
      case P.page(segments, params) do
        {:redirect, _to} -> P.page(["acme", "shop"], params)
        page -> page
      end

    %{page: page, params: params, role: role, path: path, page_title: title(page)}
  end

  @doc "at/2 is `at/4` for a whole `path` with its query, for a test."
  def at(path, role) do
    %URI{path: "/dev/prototype" <> rest, query: query} = URI.parse(path)
    params = if query, do: URI.decode_query(query), else: %{}
    params = Map.put_new(params, "as", to_string(role))
    at(String.split(rest, "/", trim: true), params, path, role)
  end

  @impl true
  # A dialog's or a page's act: the prototype changes nothing, so it says what would
  # happen, then goes where the act lands.
  def handle_event("done", %{"to" => to} = params, socket) do
    socket = if params["say"], do: put_flash(socket, :info, params["say"]), else: socket
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("approve", %{"key" => key, "to" => to, "node" => node}, socket) do
    {:noreply,
     socket
     |> update(:approved, &MapSet.put(&1, key))
     |> put_flash(:info, "Key approved. #{node} can run from its next request.")
     |> push_patch(to: to)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{page: :not_found} = assigns) do
    ~H"""
    <Shell.shell place={:workspace} nav={nil} role={@role} path={@path} flash={@flash}>
      <ApiaryWeb.CoreComponents.empty_state title="This page is not in the prototype" icon="hero-map">
        The navigation names no page at {@path}.
        <:actions>
          <ApiaryWeb.CoreComponents.button patch={P.entry()}>Go to shop's Overview</ApiaryWeb.CoreComponents.button>
        </:actions>
      </ApiaryWeb.CoreComponents.empty_state>
    </Shell.shell>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, frame(assigns.page) |> Map.new())

    ~H"""
    <Shell.shell
      place={@place}
      nav={@nav}
      crumbs={@crumbs}
      role={@role}
      path={@path}
      width={@width}
      flash={@flash}
    >
      <.page {assigns} />
    </Shell.shell>
    """
  end

  defp page(%{page: %{level: level}} = assigns) when level in [:workspace, :run],
    do: WorkspacePages.render(assigns)

  defp page(%{page: %{level: :settings}} = assigns), do: SettingsPages.render(assigns)
  defp page(%{page: %{level: :repository}} = assigns), do: RepositoryPages.render(assigns)
  defp page(%{page: %{level: :node}} = assigns), do: NodePages.render(assigns)
  defp page(assigns), do: OrganisationPages.render(assigns)

  # Where a page sits: its place's sidebar, the entry current in it, its breadcrumb after
  # the place, and its width.
  defp frame(%{level: :workspace, page: page}) do
    {nav, crumbs} =
      case page do
        :overview -> {:overview, []}
        :runs -> {:runs, [{"Runs", nil}]}
        :network -> {:network, [{"Network access", nil}]}
        :repositories -> {:repositories, [{"Repositories", nil}]}
        :nodes -> {:nodes, [{"Nodes", nil}]}
      end

    [place: :workspace, nav: nav, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :run, run: run}) do
    [
      place: :workspace,
      nav: :runs,
      crumbs: [{run.repo, P.repo(run.repo)}, {"Run #{run.id}", nil}],
      width: "list"
    ]
  end

  defp frame(%{level: :settings, page: page} = p) do
    section = fn label -> [{"Settings", P.ws("/settings")}, {label, nil}] end

    crumbs =
      case page do
        :general -> [{"Settings", nil}]
        :people -> section.("People")
        :retention -> section.("Retention")
        :policy -> section.("Policy")
        :integrations -> section.("Integrations")
        :secrets -> section.("Secrets and variables")
        :add_integration -> integrations_crumbs("Add integration")
        :integration -> integrations_crumbs(p.integration.name)
      end

    [place: :workspace, nav: :settings, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :repository, page: page, repo: repo}) do
    nav = if repo.pinned, do: {:pin, repo.path}, else: :repositories
    head = {repo.path, P.repo(repo.path)}
    settings = {"Settings", P.repo(repo.path, "/settings")}

    crumbs =
      case page do
        :overview -> [{repo.path, nil}]
        :runs -> [head, {"Runs", nil}]
        :network -> [head, {"Network access", nil}]
        :settings_integrations -> [head, settings, {"Integrations", nil}]
        :settings_policy -> [head, settings, {"Policy", nil}]
        :settings_variables -> [head, settings, {"Variables", nil}]
      end

    [place: :workspace, nav: nav, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :node, page: page, node: node}) do
    nodes = {"Nodes", P.ws("/nodes")}
    head = {node.name, P.node(node)}
    settings = {"Settings", P.node(node, "/settings")}

    crumbs =
      case page do
        :overview -> [nodes, {node.name, nil}]
        :runs -> [nodes, head, {"Runs", nil}]
        :settings_general -> [nodes, head, settings, {"General", nil}]
        :settings_keys -> [nodes, head, settings, {"Access keys", nil}]
      end

    [place: :workspace, nav: :nodes, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :organisation, page: page}) do
    crumbs = if page == :audit_log, do: [{"Audit log", nil}], else: []
    [place: :organisation, nav: page, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :org_settings, page: page}) do
    crumbs =
      case page do
        :general -> [{"Settings", nil}]
        :people -> [{"Settings", P.org("/settings")}, {"People", nil}]
      end

    [place: :organisation, nav: :settings, crumbs: crumbs, width: "list"]
  end

  defp frame(%{level: :person, page: page}) do
    [place: :person, nav: page, crumbs: [], width: "list"]
  end

  defp integrations_crumbs(label) do
    [
      {"Settings", P.ws("/settings")},
      {"Integrations", P.ws("/settings/integrations")},
      {label, nil}
    ]
  end

  defp title(:not_found), do: "Not in the prototype"
  defp title(%{level: :run, run: run}), do: "Run #{run.id}"
  defp title(%{level: :repository, repo: repo}), do: repo.path
  defp title(%{level: :node, node: node}), do: node.name
  defp title(%{level: :settings, page: page}), do: "#{humanise(page)} · Settings"
  defp title(%{level: :org_settings, page: page}), do: "#{humanise(page)} · acme settings"
  defp title(%{page: page}), do: humanise(page)

  defp humanise(atom) do
    atom |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc false
  # The node of a page with the keys approved in this session approved.
  def with_approvals(node, approved) do
    %{
      node
      | keys:
          Enum.map(node.keys, fn key ->
            if key.id in approved,
              do: %{key | state: :approved, approved: "you, just now"},
              else: key
          end)
    }
  end
end
