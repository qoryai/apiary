defmodule Apiary.Nodes.Node do
  @moduledoc """
  A node of a workspace: a place that runs, or a gateway, which may live at an
  organisation instead, with no workspace (`workspace_id` nil, `Apiary.Gateways`). Its `kind` is `:node`, one
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
  level's default gateway, its workspace's or its organisation's (`default_gateway`, which `Apiary.Nodes` sets through
  `default_changeset/2`; `changeset/2` never casts it). A node or a pool has neither, and records a choice of gateway
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
  @type kind :: :node | :pool | :gateway | feature_kind()

  # The kind a feature the documentation does not differ by adds (`docs: false`): an
  # adapter. A private type, so the served docs show its name alone.
  @typep feature_kind :: :adapter

  @typedoc """
  A node's or a pool's choice of gateway: direct, its workspace's default gateway, or the
  gateway it names.
  """
  @type choice :: :direct | :default | :named

  @kinds [:node, :pool]
  @all_kinds [:node, :pool, :gateway]
  # The kinds the schema reads and writes: those of `all_kinds/0`, and an adapter, which
  # lives at its organisation and is made through `Apiary.Adapters` alone
  # (`adapter_changeset/2`).
  @schema_kinds @all_kinds ++ [:adapter]
  @choices [:direct, :default, :named]
  @max_limit 10_000
  @max_url 2048
  @max_adapter_name 64
  @prefixes %{node: "nd", pool: "np", gateway: "ng", adapter: "na"}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "nodes" do
    field :public_id, :string
    field :name, :string
    field :kind, Ecto.Enum, values: @schema_kinds
    field :instance_limit, :integer
    field :url, :string
    field :default_gateway, :boolean, default: false
    field :gateway_choice, Ecto.Enum, values: @choices, default: :direct
    field :instance_limit_refused, :integer, default: 0
    field :instance_limit_refused_at, :utc_datetime_usec
    field :instance_ids_over_bound, :integer, default: 0
    field :instance_ids_over_bound_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec
    # An adapter's alone (`nodes_adapter_check`): the address a person is sent to when they
    # connect it, and its periodic check's intervals, in seconds, as it declares them and
    # as a person sets it.
    field :connect_url, :string
    field :sync_interval, :integer
    field :sync_default_interval, :integer
    field :sync_minimum_interval, :integer
    field :sync_sends_changes, :boolean

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :deleted_by, Apiary.Accounts.User
    belongs_to :gateway, __MODULE__
    # A pool's alone (`nodes_served_by_check`): the adapter that serves it.
    belongs_to :served_by, __MODULE__

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
  nodes in use, or among the gateways in use at the organisation's level; a pool's limit empty, for none, or 1 to `max_limit/0`. A node's limit is
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
    |> unique_constraint([:organisation_id, :name],
      name: :nodes_organisation_live_name_index,
      error_key: :name,
      message: dgettext_noop("errors", "is already the name of a gateway in this organisation")
    )
    |> put_limit(attrs)
    |> put_url(attrs)
    |> put_choice(attrs)
    |> put_served_by(attrs)
    |> check_constraint(:url, name: :nodes_url_check)
    |> check_constraint(:gateway_choice, name: :nodes_gateway_choice_check)
    |> check_constraint(:gateway_id, name: :nodes_gateway_is_a_gateway)
    |> foreign_key_constraint(:gateway_id, name: :nodes_gateway_id_fkey)
    |> served_by_constraints()
  end

  # An adapter is no node a run runs on, nor a gateway: it lives at its organisation, is
  # made, renamed and deleted through `Apiary.Adapters`, and its changesets are these
  # three. Its documentation stays out of the module reference.

  @doc false
  # The changeset of an adapter's name, as it is made or renamed: 1 to 64 characters
  # without control characters, unique among the organisation's adapters in use. A new one
  # (no public id yet) is given its kind's public id, `na_`; its place, the organisation
  # with no workspace, is the caller's to set, and nothing here casts it, its kind, its
  # limit, its choice of gateway or its address.
  @spec adapter_changeset(t, map) :: Ecto.Changeset.t()
  def adapter_changeset(%__MODULE__{kind: :adapter} = adapter, attrs) do
    adapter
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @max_adapter_name)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> unique_constraint([:organisation_id, :name],
      name: :nodes_organisation_adapter_name_index,
      error_key: :name,
      message: dgettext_noop("errors", "has already been taken")
    )
    |> check_constraint(:name, name: :nodes_adapter_name_check)
    |> check_constraint(:workspace_id, name: :nodes_place_check)
    |> then(&if(is_nil(adapter.public_id), do: put_public_id(&1), else: &1))
  end

  # `https://`, an authority with no `@` and no whitespace, then nothing, or a path, a
  # query or a fragment without whitespace: as `nodes_connect_url_check` has it.
  @connect_url ~r{\Ahttps://[^/?#@[:space:]]+(?:[/?#][^[:space:]]*)?\z}u

  @doc false
  # The changeset of an adapter's connect address, `connect_url`: `https://`, an authority
  # without user information, then an optional path, query or fragment, no whitespace
  # anywhere, at most `max_url/0` characters; nil clears it. The database holds it to the
  # same (`nodes_connect_url_check`), and to adapters (`nodes_adapter_check`).
  @spec connect_url_changeset(t, map) :: Ecto.Changeset.t()
  def connect_url_changeset(%__MODULE__{kind: :adapter} = adapter, attrs) do
    adapter
    |> cast(attrs, [:connect_url])
    |> validate_length(:connect_url, max: @max_url)
    |> validate_change(:connect_url, fn :connect_url, url ->
      cond do
        not String.starts_with?(url, "https://") ->
          [connect_url: dgettext_noop("errors", "must start with https://")]

        not (url =~ @connect_url) ->
          [connect_url: dgettext_noop("errors", "has invalid format")]

        true ->
          []
      end
    end)
    |> check_constraint(:connect_url, name: :nodes_connect_url_check)
    |> check_constraint(:connect_url, name: :nodes_adapter_check)
  end

  # A pool's adapter, which a node, a gateway and an adapter never have. Whether the
  # adapter is one the pool may name, and whether the person may name one, are
  # `Apiary.Nodes`'s to check; the database refuses one that is not an adapter in use of
  # the pool's organisation.
  defp put_served_by(changeset, attrs) do
    case get_field(changeset, :kind) do
      :pool -> cast(changeset, attrs, [:served_by_id])
      nil -> changeset
      _other -> put_change(changeset, :served_by_id, nil)
    end
  end

  defp served_by_constraints(changeset) do
    changeset
    |> check_constraint(:served_by_id, name: :nodes_served_by_check)
    |> check_constraint(:served_by_id, name: :nodes_served_by_is_an_adapter)
    |> foreign_key_constraint(:served_by_id, name: :nodes_served_by_id_fkey)
  end

  @doc """
  default_changeset/2 marks `gateway` as its level's default gateway, its workspace's or
  its organisation's, or takes the mark off. The database holds a workspace, and the
  gateways at an organisation's level, to one default, a gateway in use: a mark it refuses is an
  error on `default_gateway`.
  """
  @spec default_changeset(t, boolean) :: Ecto.Changeset.t()
  def default_changeset(%__MODULE__{} = gateway, default?) when is_boolean(default?) do
    gateway
    |> change(default_gateway: default?)
    |> unique_constraint(:default_gateway, name: :nodes_default_gateway_index)
    |> unique_constraint(:default_gateway, name: :nodes_organisation_default_gateway_index)
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

      kind when kind in [:gateway, :adapter] ->
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
      kind when kind in [:gateway, :adapter] ->
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
  validate_url/1 checks `changeset`'s `url`, a gateway's address: `https://`, then a host
  and an optional port, 1 to 65535, and nothing else: no user, path, query or fragment.
  The host is a DNS name (labels of letters, digits and `-`, 1 to 63 characters each,
  neither starting nor ending with `-`, the last not all digits, 253 characters at most,
  with an optional trailing dot), an IPv4 address, or an IPv6 address in brackets. A run
  key names the gateway by it, and only over TLS (`Apiary.Runs.RunKey`). The database
  holds it to the same (`nodes_url_check`).
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

  # A scheme in lower case, `://`, then the host and the port alone: a name or an IPv4
  # address, or an IPv6 address in brackets, and a port without a leading zero.
  @address ~r{\A[a-z][a-z0-9+.-]*://(?<host>[A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])(?::[1-9][0-9]*)?\z}

  defp address(url) do
    with %{"host" => host} <- Regex.named_captures(@address, url),
         true <- host?(host),
         {:ok, %URI{scheme: scheme, port: port}} when port in 1..65_535 <- URI.new(url) do
      if scheme == "https",
        do: :ok,
        else: {:error, dgettext_noop("errors", "must start with https://")}
    else
      _not_an_address ->
        {:error,
         dgettext_noop(
           "errors",
           "must be a scheme and a host, with a port if needed, and nothing more"
         )}
    end
  end

  # An IPv6 address in brackets, an IPv4 address, or a DNS name.
  defp host?("[" <> bracketed), do: ip?(String.trim_trailing(bracketed, "]"), 8)
  defp host?(host), do: ip?(host, 4) or name?(host)

  defp ip?(host, size) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> tuple_size(address) == size
      {:error, _einval} -> false
    end
  end

  @label ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/

  # Labels joined by dots, the last not all digits (a bad IPv4 address is no name), 253
  # characters at most without the optional trailing dot.
  defp name?(host) do
    name = String.replace_suffix(host, ".", "")
    labels = String.split(name, ".")

    byte_size(name) <= 253 and Enum.all?(labels, &(&1 =~ @label)) and
      not (List.last(labels) =~ ~r/\A[0-9]+\z/)
  end

  defp put_public_id(changeset) do
    case get_field(changeset, :kind) do
      kind when kind in @schema_kinds ->
        put_change(changeset, :public_id, Apiary.PublicId.generate(Map.fetch!(@prefixes, kind)))

      nil ->
        changeset
    end
  end
end
