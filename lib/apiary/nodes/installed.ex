defmodule Apiary.Nodes.Installed do
  # The instance's node pool and gateway: one of each at most, with no organisation and no
  # workspace, which run beside the instance, in the same Compose project or stack, and
  # reach it with a key they make themselves from a one-time code Qory Apiary writes for
  # them, as it does for the adapters installed with it (`Apiary.Adapters.Installed`):
  # `<name>/code` in `QORY_ENROLMENT_DIR`, in a folder that only that container mounts
  # (`Apiary.Adapters.Installed.CodeFile`). No person runs a command for them.
  #
  # **The settings.** `QORY_INSTALLED_POOL` is the pool's name and `QORY_INSTALLED_GATEWAY`
  # the gateway's, each a name as `Apiary.Adapters.Installed.valid_name?/1` takes it, which
  # is also its folder; unset or blank declares none. `QORY_INSTALLED_GATEWAY_URL` is the
  # gateway's address, which pools reach it at (`Apiary.Nodes.Node.validate_url/1`),
  # required with a gateway and refused without one. `boot!/1` checks them when the
  # application starts, after the adapters' setting: a malformed name or address, a name
  # that an installed adapter or the other node has, or any of them on an instance without
  # the feature `factory`, stops the boot. They are fixed while the instance runs.
  #
  # **What follows from them.** Once the instance is set up, the installer
  # (`Apiary.Adapters.Installer`) finds or makes each node declared (`install/2`, the
  # instance's `node.install`) and keeps one valid code for it while it holds no key
  # (`Apiary.AccessKeys.issue_installed_code/2`): the pool's without stored secrets, the
  # gateway's with them, since the gateway receives the runs' sealed secrets. A node no
  # longer declared stays, with its keys; its outstanding codes are cancelled and its file
  # deleted. Each holds one key at most, gets no code from a person, and enrols with a code
  # that names no maker only while it is declared (`declared?/1`). Both are always on.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, Adapters, Audit, Features, Nodes, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Installed, as: InstalledAdapters
  alias Apiary.Adapters.Installed.CodeFile
  alias Apiary.Contract.GatewayUrl
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}

  @kinds [:pool, :gateway]

  @typedoc "The nodes declared: each kind's name, and the gateway's address, nil for none."
  @type declared :: %{pool: String.t() | nil, gateway: String.t() | nil, url: String.t() | nil}

  @doc false
  # The nodes declared, as `boot!/1` fixed them. Before `boot!/1`, as under
  # `bin/apiary eval`, the settings read and checked now, but for the feature and the
  # adapters' names.
  @spec declared() :: declared
  def declared do
    case Application.fetch_env(:apiary, :installed_nodes) do
      {:ok, declared} -> declared
      :error -> parse!(settings())
    end
  end

  @doc false
  # name/1 is the name the node of `kind` is declared as, nil for none.
  @spec name(:pool | :gateway) :: String.t() | nil
  def name(kind) when kind in @kinds, do: Map.fetch!(declared(), kind)

  @doc false
  # The names declared, the pool's first.
  @spec names() :: [String.t()]
  def names, do: for(kind <- @kinds, name = name(kind), do: name)

  @doc false
  # declared?/1 says whether `node` is the instance's pool or gateway, installed as the
  # name its kind is declared as now.
  @spec declared?(Node.t() | nil) :: boolean
  def declared?(%Node{kind: kind, organisation_id: nil, workspace_id: nil, installed_as: name})
      when kind in @kinds and is_binary(name),
      do: name(kind) == name

  def declared?(_node), do: false

  @doc false
  # Reads the three settings as `config/runtime.exs` left them, checks them against
  # `adapters`, the names of the installed adapters, and fixes them for the life of the
  # node. Called at boot, after `Apiary.Adapters.Installed.boot!/0`: raises on a value
  # `parse!/1` refuses, on a name an adapter has too, and on any node declared while the
  # instance does not have the feature `factory`, so the instance does not start.
  @spec boot!([String.t()]) :: declared
  def boot!(adapters) when is_list(adapters) do
    declared = parse!(settings())

    for kind <- @kinds, name = declared[kind], name in adapters do
      raise ArgumentError, """
      environment variable #{variable(kind)} names #{name}, which QORY_INSTALLED_ADAPTERS
      lists too: each has a folder of that name.
      Give #{variable(kind)} a name that no installed adapter has.
      """
    end

    if (declared.pool || declared.gateway) && not Features.on?(:factory) do
      raise ArgumentError, """
      environment variable QORY_INSTALLED_POOL or QORY_INSTALLED_GATEWAY declares a node of
      the instance, and this instance does not have the feature they belong to:
      QORY_FEATURES leaves it out.
      Leave both unset, or turn the feature on in QORY_FEATURES.
      """
    end

    Application.put_env(:apiary, :installed_nodes, declared)
    declared
  end

  @doc false
  # The nodes a set of the three settings declares, `%{pool:, gateway:, url:}`: `{:ok,
  # declared}`, or `{:error, reason}` for a malformed name, the same name twice, an
  # address that is malformed, an address without a gateway, or a gateway without one.
  @spec parse(map) :: {:ok, declared} | {:error, String.t()}
  def parse(%{pool: pool, gateway: gateway, url: url}) do
    pool = blank(pool)
    gateway = blank(gateway)
    url = blank(url)

    cond do
      pool && not InstalledAdapters.valid_name?(pool) ->
        {:error, "QORY_INSTALLED_POOL is not valid: #{name_rule(pool)}"}

      gateway && not InstalledAdapters.valid_name?(gateway) ->
        {:error, "QORY_INSTALLED_GATEWAY is not valid: #{name_rule(gateway)}"}

      pool && pool == gateway ->
        {:error,
         "QORY_INSTALLED_POOL and QORY_INSTALLED_GATEWAY both name #{pool}: " <>
           "each has a folder of its name"}

      gateway && is_nil(url) ->
        {:error,
         "QORY_INSTALLED_GATEWAY names a gateway and QORY_INSTALLED_GATEWAY_URL is not set: " <>
           "set it to the address pools reach the gateway at, https://host or https://host:port"}

      url && is_nil(gateway) ->
        {:error,
         "QORY_INSTALLED_GATEWAY_URL is set and QORY_INSTALLED_GATEWAY is not: " <>
           "name the gateway, or leave the address unset"}

      url && not GatewayUrl.shape?(url) ->
        {:error,
         "QORY_INSTALLED_GATEWAY_URL is not valid: #{inspect(url)} is not https://, then a " <>
           "host, with a port if needed, and nothing more"}

      true ->
        {:ok, %{pool: pool, gateway: gateway, url: url}}
    end
  end

  defp name_rule(name),
    do:
      "#{inspect(name)} is not a name: a lower-case letter, then lower-case letters, digits " <>
        "and hyphens, 32 characters at most"

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp settings do
    %{
      pool: Application.get_env(:apiary, :installed_pool_setting),
      gateway: Application.get_env(:apiary, :installed_gateway_setting),
      url: Application.get_env(:apiary, :installed_gateway_url_setting)
    }
  end

  defp parse!(settings) do
    case parse(settings) do
      {:ok, declared} ->
        declared

      {:error, reason} ->
        raise ArgumentError, """
        #{reason}.
        Leave QORY_INSTALLED_POOL, QORY_INSTALLED_GATEWAY and QORY_INSTALLED_GATEWAY_URL unset
        for none, or declare them, for example:
        QORY_INSTALLED_POOL=pool
        QORY_INSTALLED_GATEWAY=gateway
        QORY_INSTALLED_GATEWAY_URL=https://gateway.example.com
        """
    end
  end

  defp variable(:pool), do: "QORY_INSTALLED_POOL"
  defp variable(:gateway), do: "QORY_INSTALLED_GATEWAY"

  @doc false
  # Makes the folder of each node declared where it is missing, as
  # `Apiary.Adapters.Installed.make_folders/0` does for the adapters. `:ok`.
  @spec make_folders() :: :ok
  def make_folders do
    for kind <- @kinds, name = name(kind) do
      case CodeFile.make_folder(name) do
        :ok -> :ok
        {:error, reason} -> Logger.error(folder_line(kind, name, reason))
      end
    end

    :ok
  end

  @doc false
  # The line that says the folder of the node of `kind` declared as `name` could not be
  # made.
  @spec folder_line(:pool | :gateway, String.t(), atom) :: String.t()
  def folder_line(kind, name, reason),
    do:
      "could not make the folder of the instance's #{noun(kind)} #{name}, " <>
        "#{CodeFile.folder(name)}: #{CodeFile.format_error(reason)}; " <>
        "trying again when its one-time code is written"

  @doc false
  # The words for a node of `kind` in a log line.
  @spec noun(:pool | :gateway) :: String.t()
  def noun(:pool), do: "node pool"
  def noun(:gateway), do: "gateway"

  @doc false
  # Asks whether `scope` may install the instance's pool and gateway (`node.install`): the
  # instance, by itself (`Apiary.Accounts.Scope.for_instance/2`), in the instance's
  # organisation, on an instance with the feature `factory`. `:ok`; `{:error, :not_found}`
  # where the feature is off; `{:error, :forbidden}` for any other scope.
  @spec authorize_install(Scope.t() | nil) :: :ok | {:error, Access.reason()}
  def authorize_install(%Scope{instance: true, organisation: %Organisation{id: id} = org} = scope)
      when is_binary(id) do
    with :ok <- Access.authorize(scope, :"node.install", org) do
      if id == Apiary.Edition.instance_organisation_id(), do: :ok, else: {:error, :forbidden}
    end
  end

  def authorize_install(_scope),
    do: if(Features.on?(:factory), do: {:error, :forbidden}, else: {:error, :not_found})

  @doc false
  # Installs the node of `kind` as it is declared: the instance, by itself
  # (`authorize_install/1`), finds the instance's node of that kind in use, or makes it,
  # with no organisation, no workspace and no maker, its name and `installed_as` the
  # declared name; a pool takes runs from any number of instances and goes through the
  # instance's gateway by default, and a gateway has the declared address. A node found
  # whose `installed_as` or address differs from the settings takes theirs, its code file
  # under the old name deleted; it leaves no entry. A new one leaves the entry
  # `node.install` by the instance, in the instance's trail, in its transaction. Made
  # beside another pass, the insert finds the conflict and reads again.
  # `{:ok, node}`; `{:error, :not_declared}` for a kind not declared; `{:error,
  # changeset}`; `{:error, :forbidden}`; `{:error, :not_found}` where the feature is off.
  @spec install(Scope.t(), :pool | :gateway) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :not_declared}
  def install(%Scope{} = scope, kind) when kind in @kinds do
    case name(kind) do
      nil ->
        {:error, :not_declared}

      name ->
        Repo.transact(fn ->
          with :ok <- authorize_install(scope), do: find_or_install(scope, kind, name, 3)
        end)
        |> case do
          {:ok, {node, old_name}} ->
            if old_name, do: _ = CodeFile.delete(old_name)
            {:ok, node}

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp find_or_install(scope, kind, name, tries) do
    case Repo.one(from n in live_query(kind), lock: "FOR UPDATE") do
      %Node{} = node ->
        follow_settings(node, name)

      nil when tries > 0 ->
        changeset =
          %Node{
            kind: kind,
            organisation_id: nil,
            workspace_id: nil,
            created_by_id: nil,
            installed_as: name
          }
          |> Node.create_changeset(Map.put(attrs(kind, name), :kind, kind))

        # A conflict with the instance's node of the kind in use, or with a node installed
        # as the same name, inserts nothing and raises nothing, so the transaction goes on:
        # read again.
        with {:ok, %Node{id: id} = node} <- Repo.insert(changeset, on_conflict: :nothing) do
          if Repo.exists?(from n in Node, where: n.id == ^id),
            do: record_install(scope, node),
            else: find_or_install(scope, kind, name, tries - 1)
        end

      nil ->
        {:error, :conflict}
    end
  end

  defp attrs(:pool, name), do: %{name: name, gateway_choice: :default, instance_limit: nil}
  defp attrs(:gateway, name), do: %{name: name, url: declared().url}

  # The node found, with the declared name and address when they differ: `{:ok, {node,
  # old_name}}`, the name its code file had before, nil when it kept it.
  defp follow_settings(%Node{} = node, name) do
    url = if node.kind == :gateway, do: declared().url, else: node.url

    if node.installed_as == name and node.url == url do
      {:ok, {node, nil}}
    else
      changes =
        if node.kind == :gateway, do: [installed_as: name, url: url], else: [installed_as: name]

      with {:ok, updated} <- node |> Ecto.Changeset.change(changes) |> Repo.update() do
        old = if node.installed_as != name, do: node.installed_as
        {:ok, {updated, old}}
      end
    end
  end

  defp record_install(scope, node) do
    with {:ok, _entry} <-
           Audit.record(Repo, scope, :"node.install", node, %{
             after: Map.take(node, [:name, :kind, :public_id, :installed_as, :url])
           }),
         do: {:ok, {node, nil}}
  end

  @doc false
  # The instance's nodes in use whose kind is not declared now: their codes are cancelled.
  @spec undeclared() :: [Node.t()]
  def undeclared do
    kinds = for kind <- @kinds, is_nil(name(kind)), do: kind

    Repo.all(
      from n in Node,
        where: n.kind in ^kinds and is_nil(n.deleted_at) and not is_nil(n.installed_as),
        where: is_nil(n.organisation_id) and is_nil(n.workspace_id),
        order_by: [asc: n.kind]
    )
  end

  @doc false
  # The query of the instance's node of `kind` in use, nil for none.
  @spec live_query(:pool | :gateway) :: Ecto.Query.t()
  def live_query(kind) when kind in @kinds do
    from n in Node,
      where: n.kind == ^kind and is_nil(n.deleted_at),
      where: is_nil(n.organisation_id) and is_nil(n.workspace_id)
  end

  ## For the instance admin

  @doc false
  # The instance's pool and gateway in use, the pool first, to an instance admin
  # (`Apiary.Adapters.authorize_instance/2`); none to anyone else.
  @spec list(Scope.t()) :: [Node.t()]
  def list(%Scope{} = scope) do
    if Adapters.authorize_instance(scope) == :ok,
      do: for(kind <- @kinds, node = Repo.one(live_query(kind)), do: node),
      else: []
  end

  @doc false
  # Subscribes an instance admin to what the instance's pool and gateway report
  # (`Apiary.Nodes.topic/1`, `"instance"`): `{:nodes_touched, "instance"}`.
  @spec subscribe(Scope.t()) :: :ok | {:error, term}
  def subscribe(%Scope{} = scope) do
    with :ok <- Adapters.authorize_instance(scope),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, Nodes.topic("instance"))
  end

  @doc false
  # The instance's pool or gateway in use by its public id, to an instance admin; nil for
  # anyone else, and for any other node.
  @spec get(Scope.t(), term) :: Node.t() | nil
  def get(%Scope{} = scope, public_id) when is_binary(public_id),
    do: Enum.find(list(scope), &(&1.public_id == public_id))

  def get(%Scope{}, _public_id), do: nil

  @doc false
  # What each of `nodes`, the instance's pool and gateway, is doing at `now`, to an
  # instance admin, as `Apiary.Nodes.activity/3` says it for a workspace's nodes; nothing
  # to anyone else.
  @spec activity(Scope.t(), [Node.t()], DateTime.t()) :: %{Ecto.UUID.t() => map}
  def activity(%Scope{} = scope, nodes, now \\ DateTime.utc_now()) do
    if Adapters.authorize_instance(scope) == :ok,
      do: Nodes.activity(:instance, nodes, now),
      else: %{}
  end

  @doc false
  # Sets the instance's pool's instance limit from `attrs` (`"instance_limit"`, nil or
  # blank for none), by an instance admin, in one transaction with the pool's row held
  # `FOR UPDATE`; the entry `node.set_limit` in the instance's organisation's trail, by
  # the person, when the limit changed. Lowering it stops none of its instances.
  # `{:ok, pool}`, `{:error, changeset}`, `{:error, :forbidden}`, or `{:error,
  # :not_found}` where the feature is off or the pool is no longer in use.
  @spec set_instance_limit(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def set_instance_limit(%Scope{} = scope, %Node{kind: :pool, id: id}, attrs)
      when is_map(attrs) do
    Repo.transact(fn ->
      with :ok <- Adapters.authorize_instance(scope),
           {:ok, recorder} <- Adapters.instance_scope(scope),
           %Node{} = current <-
             Repo.one(from n in live_query(:pool), where: n.id == ^id, lock: "FOR UPDATE") ||
               {:error, :not_found},
           {:ok, updated} <-
             current |> Node.changeset(Map.take(attrs, ["instance_limit"])) |> Repo.update(),
           :ok <- record_limit(recorder, current, updated) do
        {:ok, updated}
      end
    end)
  end

  def set_instance_limit(%Scope{}, %Node{}, _attrs), do: {:error, :not_found}

  @doc false
  # The changeset of the pool's instance limit, for the form that sets it.
  @spec change_instance_limit(Node.t(), map) :: Ecto.Changeset.t()
  def change_instance_limit(%Node{kind: :pool} = pool, attrs \\ %{}),
    do: Node.changeset(pool, Map.take(attrs, ["instance_limit"]))

  defp record_limit(scope, old, new) do
    case Audit.changed(old, new, [:instance_limit]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"node.set_limit", new, changes),
             do: :ok
    end
  end

  @doc false
  # The instance's pool in use when it takes the runs of `workspace`, which has no pool in
  # use, and the instance's gateway in use: what a workspace's Nodes page shows beside
  # the workspace's nodes. Nil for each where there is none.
  @spec serving(Workspace.t()) :: %{pool: Node.t() | nil, gateway: Node.t() | nil}
  def serving(%Workspace{id: workspace_id}) do
    pool_in_use? =
      Repo.exists?(
        from n in Node,
          where: n.workspace_id == ^workspace_id and n.kind == :pool and is_nil(n.deleted_at)
      )

    %{
      pool: if(pool_in_use?, do: nil, else: Repo.one(live_query(:pool))),
      gateway: Repo.one(live_query(:gateway))
    }
  end
end
