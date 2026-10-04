defmodule ApiaryWeb.Prototype do
  @moduledoc """
  A clickable prototype of the proposed navigation, in development only, at
  `/dev/prototype` (`ApiaryWeb.Routes.storybook_routes/0`): every level (the organisation,
  the workspace, a repository, a node or pool) with its operational pages and its own
  Settings, kept apart. One LiveView (`ApiaryWeb.Prototype.Live`) draws every page from
  its path, so a page survives a reload and every link is a `patch`.

  Nothing stands behind it: no route of the app, no context, no database. It draws
  `ApiaryWeb.Prototype.Data`. This module holds its paths, and reads a path back into the
  page it names (`page/2`).
  """

  import Kernel, except: [node: 1]

  alias ApiaryWeb.Prototype.Data

  @root "/dev/prototype"

  @doc "The prototype's entry: the workspace's Overview."
  def entry, do: ws("")

  @doc "A path under the organisation `acme`."
  def org(rest), do: "#{@root}/acme#{rest}"

  @doc "A path under the workspace `acme/shop`."
  def ws(rest), do: "#{@root}/acme/shop#{rest}"

  @doc "A path of the person's own settings."
  def person(rest), do: "#{@root}/users#{rest}"

  @doc "A path of the repository at `path` (`acme/shop`); `rest` follows `/-` (`/runs`)."
  def repo(path, rest \\ "")
  def repo(path, ""), do: ws("/targets/github.com/#{path}")
  def repo(path, rest), do: ws("/targets/github.com/#{path}/-#{rest}")

  @doc "A path of the node `node` (a map, an id or a name)."
  def node(node, rest \\ "")
  def node(%{id: id}, rest), do: ws("/nodes/#{id}#{rest}")

  def node(name, rest) when is_binary(name) do
    case Data.node_named(name) do
      %{id: id} -> ws("/nodes/#{id}#{rest}")
      nil -> ws("/nodes/#{name}#{rest}")
    end
  end

  @doc "A path of the run `id`."
  def run(id, rest \\ ""), do: ws("/runs/#{id}#{rest}")

  @doc "A path of an integration's page in workspace Settings."
  def integration(id), do: ws("/settings/integrations/#{id}")

  @doc """
  The New rule dialog's path, filled in: `host`, `path` and `repo` as Network access, a run
  or the Overview knows them, and `back`, where saving returns.
  """
  def new_rule(fields) do
    query =
      fields
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    case query do
      "" -> ws("/settings/policy/rules/new")
      q -> ws("/settings/policy/rules/new?#{q}")
    end
  end

  @doc """
  page/2 is the page at `segments`, the path after `/dev/prototype`, with the query
  `params`: a map of `level` (`:organisation`, `:workspace`, `:repository`, `:node`, `:run`,
  `:person`), `page`, the thing it is of, and the `dialog` open over it. `:not_found` for a
  path the prototype has no page for.
  """
  def page(segments, params \\ %{})

  def page([], _params), do: {:redirect, entry()}

  def page(["users", "settings"], _), do: p(:person, :profile)
  def page(["users", "settings", "preferences"], _), do: p(:person, :preferences)
  def page(["users", "organisations"], _), do: p(:person, :organisations)

  def page(["acme"], _), do: p(:organisation, :overview)
  def page(["acme", "audit-log"], _), do: p(:organisation, :audit_log)
  def page(["acme", "settings"], _), do: p(:org_settings, :general)
  def page(["acme", "settings", "people"], _), do: p(:org_settings, :people)

  def page(["acme", "settings", "people", "invite"], _),
    do: p(:org_settings, :people, dialog: :invite)

  def page(["acme", "shop" | rest], params), do: workspace(rest, params)
  def page(_segments, _params), do: :not_found

  defp workspace([], _), do: p(:workspace, :overview)
  defp workspace(["runs"], _), do: p(:workspace, :runs)

  defp workspace(["runs", id | tab], _) do
    with %{} = run <- Data.run(id),
         {:ok, tab} <- run_tab(tab) do
      p(:run, tab, run: run)
    else
      _ -> :not_found
    end
  end

  defp workspace(["network"], _), do: p(:workspace, :network)
  defp workspace(["targets"], _), do: p(:workspace, :repositories)
  defp workspace(["targets", "github.com" | rest], _), do: repository(rest)
  defp workspace(["nodes"], _), do: p(:workspace, :nodes)
  defp workspace(["nodes", "new"], _), do: p(:workspace, :nodes, dialog: :new_node)
  defp workspace(["nodes", "new-pool"], _), do: p(:workspace, :nodes, dialog: :new_pool)

  defp workspace(["nodes", id | rest], params) do
    case Data.node(id) do
      nil -> :not_found
      node -> node_page(node, rest, params)
    end
  end

  defp workspace(["settings" | rest], params), do: settings(rest, params)
  defp workspace(_rest, _), do: :not_found

  defp run_tab([]), do: {:ok, :timeline}
  defp run_tab(["terminal"]), do: {:ok, :terminal}
  defp run_tab(["network"]), do: {:ok, :network}
  defp run_tab(["details"]), do: {:ok, :details}
  defp run_tab(_), do: :error

  defp repository(rest) do
    {path, tab} = Enum.split_while(rest, &(&1 != "-"))

    with %{} = repo <- Data.repository(Enum.join(path, "/")),
         {:ok, page} <- repository_tab(Enum.drop(tab, 1)) do
      p(:repository, page, repo: repo)
    else
      _ -> :not_found
    end
  end

  defp repository_tab([]), do: {:ok, :overview}
  defp repository_tab(["runs"]), do: {:ok, :runs}
  defp repository_tab(["network"]), do: {:ok, :network}
  defp repository_tab(["settings"]), do: {:ok, :settings_integrations}
  defp repository_tab(["settings", "policy"]), do: {:ok, :settings_policy}
  defp repository_tab(["settings", "variables"]), do: {:ok, :settings_variables}
  defp repository_tab(_), do: :error

  defp node_page(node, [], _), do: p(:node, :overview, node: node)
  defp node_page(node, ["clear"], _), do: p(:node, :overview, node: node, dialog: :clear)
  defp node_page(node, ["runs"], _), do: p(:node, :runs, node: node)
  defp node_page(node, ["settings"], _), do: p(:node, :settings_general, node: node)

  defp node_page(node, ["settings", "delete"], _),
    do: p(:node, :settings_general, node: node, dialog: :delete)

  defp node_page(node, ["settings", "keys"], _), do: p(:node, :settings_keys, node: node)

  defp node_page(node, ["settings", "keys", "new"], _),
    do: p(:node, :settings_keys, node: node, dialog: :enrol)

  defp node_page(node, ["settings", "keys", key_id, act], _)
       when act in ["approve", "reject", "revoke"] do
    case Enum.find(node.keys, &(&1.id == key_id)) do
      nil -> :not_found
      key -> p(:node, :settings_keys, node: node, key: key, dialog: String.to_atom(act))
    end
  end

  defp node_page(_node, _rest, _), do: :not_found

  defp settings([], _), do: p(:settings, :general)
  defp settings(["delete"], _), do: p(:settings, :general, dialog: :delete_workspace)
  defp settings(["people"], _), do: p(:settings, :people)
  defp settings(["retention"], _), do: p(:settings, :retention)
  defp settings(["policy"], _), do: p(:settings, :policy, view: :rules)
  defp settings(["policy", "repositories"], _), do: p(:settings, :policy, view: :repositories)
  defp settings(["policy", "history"], _), do: p(:settings, :policy, view: :history)
  defp settings(["policy", "document"], _), do: p(:settings, :policy, view: :document)

  defp settings(["policy", "rules", "new"], params),
    do: p(:settings, :policy, view: :rules, dialog: :new_rule, rule: rule_fields(params))

  defp settings(["integrations"], _), do: p(:settings, :integrations)
  defp settings(["integrations", "add"], _), do: p(:settings, :add_integration)

  defp settings(["integrations", id], _) do
    case Data.integration(id) do
      nil -> :not_found
      integration -> p(:settings, :integration, integration: integration)
    end
  end

  defp settings(["secrets"], _), do: p(:settings, :secrets, view: :secrets)
  defp settings(["variables"], _), do: p(:settings, :secrets, view: :variables)

  defp settings(["secrets", "new"], _),
    do: p(:settings, :secrets, view: :secrets, dialog: :new_secret)

  defp settings(["variables", "new"], _),
    do: p(:settings, :secrets, view: :variables, dialog: :new_variable)

  defp settings(_rest, _), do: :not_found

  # What the New rule dialog is filled in with, from the link that opened it.
  defp rule_fields(params) do
    %{
      host: params["host"],
      path: params["path"],
      repo: params["repo"],
      action: if(params["action"] == "deny", do: "deny", else: "allow"),
      back: safe_back(params["back"])
    }
  end

  # Only a path of the prototype's may be returned to.
  defp safe_back("/dev/prototype/" <> _ = back), do: back
  defp safe_back(_), do: nil

  defp p(level, page, extra \\ []) do
    Map.merge(%{level: level, page: page, dialog: nil}, Map.new(extra))
  end

  @doc """
  The paths of every page and dialog of the prototype, for the test that renders each and
  follows its links.
  """
  def paths do
    nodes = Data.nodes()

    [
      entry(),
      ws("/runs"),
      ws("/network"),
      ws("/targets"),
      ws("/nodes"),
      ws("/nodes/new"),
      ws("/nodes/new-pool"),
      ws("/settings"),
      ws("/settings/delete"),
      ws("/settings/people"),
      ws("/settings/retention"),
      ws("/settings/policy"),
      ws("/settings/policy/repositories"),
      ws("/settings/policy/history"),
      ws("/settings/policy/document"),
      new_rule(
        host: "registry.example.com",
        path: "/npm/*",
        repo: "acme/shop",
        back: ws("/network")
      ),
      ws("/settings/integrations"),
      ws("/settings/integrations/add"),
      ws("/settings/secrets"),
      ws("/settings/secrets/new"),
      ws("/settings/variables"),
      ws("/settings/variables/new"),
      org(""),
      org("/audit-log"),
      org("/settings"),
      org("/settings/people"),
      org("/settings/people/invite"),
      person("/settings"),
      person("/settings/preferences"),
      person("/organisations")
    ] ++
      Enum.map(Data.integrations(), &integration(&1.id)) ++
      Enum.flat_map(
        Data.runs(),
        &[run(&1.id), run(&1.id, "/terminal"), run(&1.id, "/network"), run(&1.id, "/details")]
      ) ++
      Enum.flat_map(Data.repositories(), fn r ->
        [
          repo(r.path),
          repo(r.path, "/runs"),
          repo(r.path, "/network"),
          repo(r.path, "/settings"),
          repo(r.path, "/settings/policy"),
          repo(r.path, "/settings/variables")
        ]
      end) ++
      Enum.flat_map(nodes, fn n ->
        [
          node(n),
          node(n, "/clear"),
          node(n, "/runs"),
          node(n, "/settings"),
          node(n, "/settings/delete"),
          node(n, "/settings/keys"),
          node(n, "/settings/keys/new")
        ] ++
          for key <- n.keys,
              act <- ~w(approve reject revoke),
              do: node(n, "/settings/keys/#{key.id}/#{act}")
      end)
  end
end
