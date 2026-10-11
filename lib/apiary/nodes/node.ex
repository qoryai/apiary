defmodule Apiary.Nodes.Node do
  @moduledoc """
  A node of a workspace: a place that runs, or a gateway. Its `kind` is `:node`, one
  permanent machine that runs one instance at a time, `:pool`, a fleet of short-lived
  instances that run up to its `instance_limit`, or any number when the limit is nil, or
  `:gateway`, which a node or a pool may record as its choice of gateway
  (`Apiary.Gateways`). The kind is chosen when the node is made
  (`create_changeset/2`) and never changes: `changeset/2` does not cast it, and the
  database refuses an update that changes it.

  `public_id` is the node's name in a URL, `/:org/:workspace/nodes/:public_id`: `nd_` for
  a node, `np_` for a pool or `ng_` for a gateway, then sixteen lowercase Crockford base32
  characters, made once with the node (`Apiary.PublicId`). A path built with
  `~p"/\#{organisation}/\#{workspace}/nodes/\#{node}"` uses it.

  A gateway has an address, `url` (`validate_url/1`), no instance limit, and may be its
  workspace's default gateway (`default_gateway`, which `Apiary.Nodes` sets, never a
  changeset). A node or a pool has neither, and records a choice of gateway
  (`gateway_choice`, `t:choice/0`): `:direct`, `:default`, its workspace's default
  gateway, or `:named`, the gateway `gateway_id` names. The field's default is `:direct`;
  `Apiary.Nodes.create_node/2` starts a new one on `:default` when a default gateway
  resolves for its workspace, unless it is given a choice. A choice of `:named` whose `gateway_id` is nil names a gateway that is
  gone, purged with its workspace or organisation.

  A node is deleted softly: `deleted_at` and `deleted_by_id` are set
  (`Apiary.Nodes.delete_node/2`), it leaves every page, and its name is free again.
  `instance_limit_refused` and `instance_limit_refused_at` (the starts refused at the
  instance limit), and `instance_ids_over_bound` and `instance_ids_over_bound_at` (the
  instances not recorded past the bound of new ones a day), are written outside any
  changeset.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "A node or a node pool of a workspace."
  @type t :: %__MODULE__{}

  @typedoc """
  A node's kind: one permanent machine, a pool of short-lived instances, or a gateway.
  """
  @type kind :: :node | :pool | :gateway

  @typedoc """
  A node's or a pool's choice of gateway: direct, its workspace's default gateway, or the
  gateway it names.
  """
  @type choice :: :direct | :default | :named

  @kinds [:node, :pool]
  @all_kinds [:node, :pool, :gateway]
  @choices [:direct, :default, :named]
  @max_limit 10_000
  @max_url 2048
  @prefixes %{node: "nd", pool: "np", gateway: "ng"}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "nodes" do
    field :public_id, :string
    field :name, :string
    field :kind, Ecto.Enum, values: @all_kinds
    field :instance_limit, :integer
    field :url, :string
    field :default_gateway, :boolean, default: false
    field :gateway_choice, Ecto.Enum, values: @choices, default: :direct
    field :instance_limit_refused, :integer, default: 0
    field :instance_limit_refused_at, :utc_datetime_usec
    field :instance_ids_over_bound, :integer, default: 0
    field :instance_ids_over_bound_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :deleted_by, Apiary.Accounts.User
    belongs_to :gateway, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  kinds/0 is the kinds of node a run runs on, as the nodes page lists them: a node and a
  node pool. A gateway is the third kind (`all_kinds/0`).
  """
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc "all_kinds/0 is every kind a node may be made as: a node, a node pool and a gateway."
  @spec all_kinds() :: [kind]
  def all_kinds, do: @all_kinds

  @doc "choices/0 is the choices of gateway a node or a pool may record (`t:choice/0`)."
  @spec choices() :: [choice]
  def choices, do: @choices

  @doc "max_url/0 is the longest a gateway's address may be, in characters."
  @spec max_url() :: pos_integer
  def max_url, do: @max_url

  @doc "max_limit/0 is the highest instance limit a pool may have."
  @spec max_limit() :: pos_integer
  def max_limit, do: @max_limit

  @doc """
  create_changeset/2 is the changeset of a new node: its kind, which nothing changes
  after, then its name and limit as `changeset/2` checks them, and a public id of its
  kind.
  """
  @spec create_changeset(t, map) :: Ecto.Changeset.t()
  def create_changeset(node, attrs) do
    node
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> changeset(attrs)
    |> put_public_id()
  end

  @doc """
  changeset/2 is the changeset of a node's name and, for a pool, its instance limit: the
  name 1 to 80 characters without control characters, unique among the workspace's
  nodes in use; a pool's limit empty, for none, or 1 to `max_limit/0`. A node's limit is
  1 whatever `attrs` says, and a gateway's none. A gateway's address is required and
  checked (`validate_url/1`); a node and a pool have none. A node's or a pool's choice of
  gateway (`gateway_choice`, with `gateway_id` when it is `named`) is cast, and a gateway
  stays `direct`. Whether the named gateway may serve the node, and whether a default
  resolves, are `Apiary.Nodes`'s to check. The kind is never cast.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> unique_constraint([:organisation_id, :workspace_id, :name],
      name: :nodes_live_name_index,
      error_key: :name,
      message: dgettext_noop("errors", "is already the name of a node in this workspace")
    )
    |> put_limit(attrs)
    |> put_url(attrs)
    |> put_choice(attrs)
    |> check_constraint(:url, name: :nodes_url_check)
    |> check_constraint(:gateway_choice, name: :nodes_gateway_choice_check)
    |> check_constraint(:gateway_id, name: :nodes_gateway_is_a_gateway)
    |> foreign_key_constraint(:gateway_id, name: :nodes_gateway_id_fkey)
  end

  @doc """
  default_changeset/2 marks `gateway` as its workspace's default gateway, or takes the
  mark off. The database holds a workspace to one default, a gateway in use: a mark it
  refuses is an error on `default_gateway`.
  """
  @spec default_changeset(t, boolean) :: Ecto.Changeset.t()
  def default_changeset(%__MODULE__{} = gateway, default?) when is_boolean(default?) do
    gateway
    |> change(default_gateway: default?)
    |> unique_constraint(:default_gateway, name: :nodes_default_gateway_index)
    |> check_constraint(:default_gateway, name: :nodes_default_gateway_check)
  end

  # A node runs one instance at a time; a pool runs up to its limit, or any number.
  defp put_limit(changeset, attrs) do
    case get_field(changeset, :kind) do
      :node ->
        put_change(changeset, :instance_limit, 1)

      :pool ->
        changeset
        |> cast(attrs, [:instance_limit])
        |> validate_number(:instance_limit,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: @max_limit
        )

      :gateway ->
        put_change(changeset, :instance_limit, nil)

      nil ->
        changeset
    end
  end

  # A gateway's address; a node and a pool have none.
  defp put_url(changeset, attrs) do
    case get_field(changeset, :kind) do
      :gateway ->
        changeset
        |> cast(attrs, [:url])
        |> validate_required([:url])
        |> validate_length(:url, max: @max_url)
        |> validate_url()

      _other ->
        put_change(changeset, :url, nil)
    end
  end

  # A node's or a pool's choice of gateway; a gateway is direct. The gateway a choice of
  # `named` needs is asked only when the choice or the gateway changes, so a node whose
  # gateway is gone is still renamed.
  defp put_choice(changeset, attrs) do
    case get_field(changeset, :kind) do
      :gateway ->
        changeset
        |> put_change(:gateway_choice, :direct)
        |> put_change(:gateway_id, nil)

      kind when kind in @kinds ->
        changeset
        |> cast(attrs, [:gateway_choice, :gateway_id])
        |> validate_required([:gateway_choice])
        |> put_gateway_id()

      nil ->
        changeset
    end
  end

  defp put_gateway_id(changeset) do
    cond do
      get_field(changeset, :gateway_choice) != :named ->
        put_change(changeset, :gateway_id, nil)

      changed?(changeset, :gateway_choice) or changed?(changeset, :gateway_id) ->
        validate_required(changeset, [:gateway_id])

      true ->
        changeset
    end
  end

  @doc """
  validate_url/1 checks `changeset`'s `url`, a gateway's address: `https://`, or
  `http://` to a loopback host (`localhost`, `127.0.0.0/8` or `::1`), then a host and an
  optional port, and nothing else: no user, path, query or fragment.
  """
  @spec validate_url(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case address(url) do
        :ok -> []
        {:error, message} -> [url: message]
      end
    end)
  end

  # A scheme in lower case, `://`, then the host and the port alone.
  @address ~r{\A[a-z][a-z0-9+.-]*://[^/?#@\s]+\z}

  defp address(url) do
    with true <- url =~ @address,
         {:ok, %URI{scheme: scheme, host: host, port: port}}
         when is_binary(host) and host != "" and port in 1..65_535 <- URI.new(url) do
      if scheme == "https" or (scheme == "http" and loopback?(host)),
        do: :ok,
        else:
          {:error,
           dgettext_noop("errors", "must start with https://, or http:// for a loopback host")}
    else
      _not_an_address ->
        {:error,
         dgettext_noop(
           "errors",
           "must be a scheme and a host, with a port if needed, and nothing more"
         )}
    end
  end

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, _other} -> false
      {:error, _not_an_address} -> String.downcase(host) == "localhost"
    end
  end

  defp put_public_id(changeset) do
    case get_field(changeset, :kind) do
      kind when kind in @all_kinds ->
        put_change(changeset, :public_id, Apiary.PublicId.generate(Map.fetch!(@prefixes, kind)))

      nil ->
        changeset
    end
  end
end
