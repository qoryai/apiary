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

  alias Apiary.Contract.GatewayUrl
  alias Apiary.Integrations.Description

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
  # The kinds the schema reads and writes: those of `all_kinds/0`, and an adapter, which is
  # the instance's and is made through `Apiary.Adapters` alone (`adapter_changeset/2`).
  @schema_kinds @all_kinds ++ [:adapter]
  @choices [:direct, :default, :named]
  @max_limit 10_000
  @max_url 2048
  # A gateway's address, at most as the contracts' `gateway_url` allows
  # (`Apiary.Contract.GatewayUrl`).
  @max_gateway_url GatewayUrl.max_length()
  @max_adapter_name 64
  # An adapter's title, in code points: short enough that a flash naming it fits the
  # session cookie (4096 bytes) with the rest of the session.
  @max_adapter_title 100
  # An adapter's intervals, in seconds: a minute to a day (`nodes_sync_check`).
  @min_interval 60
  @max_interval 86_400
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
    # An adapter's alone (`nodes_setup_url_check`): where an instance admin is sent to set
    # it up at the system it reads from, as its latest start-up declared it; nil while it
    # declares none.
    field :setup_url, :string
    # An adapter's alone (`nodes_call_url_check`): where Qory Apiary calls it
    # (`Apiary.Adapters.Calls`), as its latest start-up declared it, and the instance id of
    # that start-up, which each call is signed for; both nil while it declares none.
    field :call_url, :string
    field :call_instance_id, :string
    # An adapter's alone (`nodes_items_check`): what its description's source role says of
    # its items, its words for one and for many, both or neither (nil for the default),
    # and whether it reports items, false for a source that reports collections and no
    # items, with no words beside it; true on every other node.
    field :item_noun_one, :string
    field :item_noun_other, :string
    field :items, :boolean, default: true
    # An adapter's alone (`nodes_targets_check`): whether its collections can have a
    # target, a place where a run's changes go, as its latest start's description's source
    # role says (`targets`): true where it says so, false where it says nothing; nil
    # before its first start and on every other node. Set at each start
    # (`source_role_changeset/2`) and never cast. A run with a work item takes its work
    # credential only from a collection of an adapter with true; a prebuild takes its
    # collection's (`Apiary.Runs.RunCredentials`).
    field :targets, :boolean
    # An adapter's alone (`nodes_collection_noun_check`): its description's source role's
    # words for one collection and for many, both or neither (nil for the default,
    # "collection" and "collections"), beside `items` false too.
    field :collection_noun_one, :string
    field :collection_noun_other, :string
    # An adapter's alone (`nodes_source_access_check`): its description's source role's
    # line on how to change, at the source, which collections it reaches; nil before its
    # first start and where its description has no source role. Set at each start from
    # the description, once its schema has checked it (`source_role_changeset/2`), and
    # never cast.
    field :source_access, :string
    # An adapter's alone (`nodes_source_guide_check`): its description's source role's
    # `guide`, the steps for setting it up and for connecting it, as the description has
    # it; nil where its description has none, and before its first start. Set at each
    # start (`source_role_changeset/2`) and never cast.
    field :source_guide, :map
    # An adapter's alone (`nodes_domains_check`): the domains its latest start's
    # description lists, each a domain's name (`Apiary.Lingo.Domain`); nil where it lists
    # none, which serves every domain, and before its first start. Set at each start
    # (`domains_changeset/2`) and never cast. A person picks among the adapters that serve
    # a workspace's domain (`Apiary.Lingo.Domain.serves?/2`).
    field :domains, {:array, :string}
    # An adapter's alone (`nodes_title_check`): its latest start's description's `title`,
    # its human name, which a page shows in place of `name` (`Apiary.Adapters.title/1`);
    # nil before its first start and where the title fails `title_changeset/2`'s check.
    # Set at each start and never cast.
    field :title, :string
    # An adapter's alone (`nodes_installed_as_check`): the name an adapter installed with
    # Qory Apiary is listed as (`Apiary.Adapters.Installed`), unique among the adapters in
    # use (`nodes_installed_as_index`); nil for one an instance admin added. Written once,
    # by `Apiary.Adapters.install/2`, and never cast from what a person or an adapter sends.
    field :installed_as, :string
    # An adapter's alone (`nodes_secret_reference_check`): where its secret is
    # (`Apiary.Secrets.Reference`), the store and the entry, both nil until the adapter
    # first stores its secrets (`Apiary.Secrets.Instance`). Never cast from what a person
    # or an adapter sends.
    field :secret_store, :string
    field :secret_entry, :string
    # An adapter's alone (`nodes_secret_names_check`): the names of the secrets it stores
    # in Qory Apiary, as its latest start-up's description lists them, sorted; nil for
    # none (`source_role_changeset/2`).
    field :secret_names, {:array, :string}
    # An adapter's alone (`nodes_source_apply_check`): the `apply` items of its latest
    # start's source role, the templates of each run's work credential from it, as the
    # description has them (`Apiary.Integrations.ApplyTemplates`), 1 to 16; nil where it
    # has none, and before its first start. `egress_hosts` is the entries of that
    # description's `egress_hosts` that are hosts, each exact, nil for none; each apply
    # host has an equal entry there. Set at each start (`source_role_changeset/2`) and
    # never cast.
    field :source_apply, {:array, :map}
    field :egress_hosts, {:array, :string}

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

  @doc "max_url/0 is the longest an adapter's connect or setup address may be, in characters."
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
    |> Apiary.Names.validate_characters(:name)
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
    |> check_constraint(:url, name: :nodes_url_check)
    |> check_constraint(:gateway_choice, name: :nodes_gateway_choice_check)
    |> check_constraint(:gateway_id, name: :nodes_gateway_is_a_gateway)
    |> foreign_key_constraint(:gateway_id, name: :nodes_gateway_id_fkey)
  end

  # An adapter is no node a run runs on, nor a gateway: it is the instance's, with no
  # organisation and no workspace, is made, renamed and deleted through `Apiary.Adapters`,
  # and its changesets are these below. Their documentation stays out of the module
  # reference.

  @doc false
  # The changeset of an adapter's name, as it is made or renamed: 1 to 64 characters
  # without control characters, unique among the instance's adapters in use. A new one
  # (no public id yet) is given its kind's public id, `na_`; its place, no organisation and
  # no workspace, is the caller's to set, and nothing here casts it, its kind, its limit,
  # its choice of gateway, its address or the name it is installed as (`installed_as`).
  @spec adapter_changeset(t, map) :: Ecto.Changeset.t()
  def adapter_changeset(%__MODULE__{kind: :adapter} = adapter, attrs) do
    adapter
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: @max_adapter_name)
    |> Apiary.Names.validate_characters(:name)
    |> unique_constraint(:name,
      name: :nodes_adapter_name_index,
      error_key: :name,
      message: dgettext_noop("errors", "has already been taken")
    )
    |> check_constraint(:name, name: :nodes_adapter_name_check)
    |> check_constraint(:workspace_id, name: :nodes_place_check)
    |> check_constraint(:installed_as, name: :nodes_installed_as_check)
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

  # `https://`, an authority with no `@` and no whitespace, then nothing, or a path or a
  # query without whitespace, and no fragment: as `nodes_setup_url_check` has it.
  @setup_url ~r{\Ahttps://[^/?#@[:space:]]+(?:[/?][^#[:space:]]*)?\z}u
  # `https://`, an authority with no `@` and no whitespace, then a path that ends with
  # `/`, with no whitespace, query or fragment: as `nodes_call_url_check` has it.
  @call_url ~r{\Ahttps://[^/?#@[:space:]]+/(?:[^?#[:space:]]*/)?\z}u
  # An adapter's instance id, as `X-Qory-Instance-Id` carries it.
  @instance_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  @doc false
  # The changeset of what an adapter declares each time it starts
  # (`Apiary.Adapters.declare/2`): its connect address (`connect_url_changeset/2`) and how
  # it pulls changes, `sync_default_interval` and `sync_minimum_interval`, whole seconds
  # from 60 to 86,400, the minimum at most the default, and `sync_sends_changes`. Each is
  # required. The database holds the intervals it has to the same range, and the minimum
  # to at most the default (`nodes_sync_check`). And where an instance admin is sent to
  # set it up, `setup_url`, which it declares only while it is not set up: as a connect
  # address is, but with no fragment, at most `max_url/0` characters; nil clears it
  # (`nodes_setup_url_check`). And where Qory Apiary calls it, `call_url`, with the
  # instance id of the start-up that declared it, `call_instance_id`, both or neither: an
  # https address with a path that ends with `/`, no query and no fragment, at most
  # `max_url/0` characters; nil clears both (`nodes_call_url_check`).
  @spec declaration_changeset(t, map) :: Ecto.Changeset.t()
  def declaration_changeset(%__MODULE__{kind: :adapter} = adapter, attrs) do
    adapter
    |> connect_url_changeset(attrs)
    |> cast(attrs, [
      :setup_url,
      :call_url,
      :call_instance_id,
      :sync_default_interval,
      :sync_minimum_interval,
      :sync_sends_changes
    ])
    |> validate_length(:setup_url, max: @max_url)
    |> validate_change(:setup_url, fn :setup_url, url ->
      cond do
        not String.starts_with?(url, "https://") ->
          [setup_url: dgettext_noop("errors", "must start with https://")]

        not (url =~ @setup_url) ->
          [setup_url: dgettext_noop("errors", "has invalid format")]

        true ->
          []
      end
    end)
    |> check_constraint(:setup_url, name: :nodes_setup_url_check)
    |> validate_length(:call_url, max: @max_url)
    |> validate_format(:call_url, @call_url)
    |> validate_format(:call_instance_id, @instance_id)
    |> validate_call_instance_id()
    |> check_constraint(:call_url, name: :nodes_call_url_check)
    |> validate_required([
      :connect_url,
      :sync_default_interval,
      :sync_minimum_interval,
      :sync_sends_changes
    ])
    |> validate_number(:sync_default_interval,
      greater_than_or_equal_to: @min_interval,
      less_than_or_equal_to: @max_interval
    )
    |> validate_number(:sync_minimum_interval,
      greater_than_or_equal_to: @min_interval,
      less_than_or_equal_to: @max_interval
    )
    |> validate_minimum_interval()
    |> check_constraint(:sync_default_interval, name: :nodes_sync_check)
  end

  # A call address comes with the instance id it is signed for, and neither without the
  # other.
  defp validate_call_instance_id(changeset) do
    case {get_field(changeset, :call_url), get_field(changeset, :call_instance_id)} do
      {nil, nil} ->
        changeset

      {url, id} when is_binary(url) and is_binary(id) ->
        changeset

      {nil, _id} ->
        add_error(changeset, :call_url, "can't be blank", validation: :required)

      {_url, nil} ->
        add_error(changeset, :call_instance_id, "can't be blank", validation: :required)
    end
  end

  defp validate_minimum_interval(changeset) do
    case get_field(changeset, :sync_default_interval) do
      default when is_integer(default) ->
        validate_number(changeset, :sync_minimum_interval, less_than_or_equal_to: default)

      _none ->
        changeset
    end
  end

  @doc false
  # The changeset of what the source role of an adapter's description says of its items
  # and its collections (`Apiary.Integrations.Description.item_noun/1`, `items?/1`,
  # `collection_noun/1` and `access/1`, which the description's schema has checked): its
  # words for one item and for many, or none, whether it reports items, whether its
  # collections can have a target (`Apiary.Integrations.Description.targets?/1`), its
  # words for one collection and for many, or none, and its line on how to change, at
  # the source, which collections it reaches, and the names of the secrets it stores in
  # Qory Apiary
  # (`Apiary.Integrations.Description.source_secrets/1`, nil for none), and the apply
  # items of its work credential with the description's exact `egress_hosts`
  # (`Apiary.Integrations.Description.source_apply/1` and `exact_egress_hosts/1`, nil for
  # none), and its guide (`Apiary.Integrations.Description.source_guide/1`, nil for none).
  # A description with no source role gives the defaults: no words, items, no targets, no
  # line, no names, no apply items and no guide. The database holds the words and items
  # to the same (`nodes_items_check`, `nodes_collection_noun_check`), and the targets,
  # the line, the names, the apply items and the guide to adapters
  # (`nodes_targets_check`, `nodes_source_access_check`, `nodes_secret_names_check`,
  # `nodes_source_apply_check`, `nodes_source_guide_check`).
  # `Apiary.Adapters.declare/2` calls it at each start, on
  # the changeset of the declaration, so the latest start's description replaces what an
  # earlier one said; given an adapter, it starts from the adapter's changeset. A change of
  # `items` changes whether the adapter's collections are linked, and whoever writes it
  # writes the feed's entries for them in the same transaction
  # (`Apiary.Adapters.Collections.relink_adapter/2`).
  @spec source_role_changeset(t | Ecto.Changeset.t(), Description.t()) ::
          Ecto.Changeset.t()
  def source_role_changeset(%__MODULE__{kind: :adapter} = adapter, description),
    do: adapter |> change() |> source_role_changeset(description)

  def source_role_changeset(
        %Ecto.Changeset{data: %__MODULE__{kind: :adapter}} = changeset,
        description
      ) do
    item_noun = Description.item_noun(description)
    collection_noun = Description.collection_noun(description)

    changeset
    |> change(
      item_noun_one: item_noun && item_noun.one,
      item_noun_other: item_noun && item_noun.other,
      items: Description.items?(description),
      targets: Description.targets?(description),
      collection_noun_one: collection_noun && collection_noun.one,
      collection_noun_other: collection_noun && collection_noun.other,
      source_access: Description.access(description),
      secret_names: Description.source_secrets(description),
      source_apply: Description.source_apply(description),
      egress_hosts: Description.exact_egress_hosts(description),
      source_guide: Description.source_guide(description)
    )
    |> check_constraint(:items, name: :nodes_items_check)
    |> check_constraint(:targets, name: :nodes_targets_check)
    |> check_constraint(:secret_names, name: :nodes_secret_names_check)
    |> check_constraint(:collection_noun_one, name: :nodes_collection_noun_check)
    |> check_constraint(:source_access, name: :nodes_source_access_check)
    |> check_constraint(:source_apply, name: :nodes_source_apply_check)
    |> check_constraint(:source_guide, name: :nodes_source_guide_check)
  end

  @doc false
  # The changeset of the domains an adapter's description lists
  # (`Apiary.Integrations.Description`, `domains`, which the description's schema has
  # checked), or nil for none. `Apiary.Adapters.declare/2` calls it at each start, on the
  # changeset of the declaration, so the latest start's description replaces what an
  # earlier one said. It changes no collection's assignment: a restart never unassigns.
  @spec domains_changeset(Ecto.Changeset.t(), Description.t()) :: Ecto.Changeset.t()
  def domains_changeset(
        %Ecto.Changeset{data: %__MODULE__{kind: :adapter}} = changeset,
        %Description{domains: domains}
      ) do
    changeset
    |> change(domains: domains)
    |> check_constraint(:domains, name: :nodes_domains_check)
  end

  @doc false
  # The changeset of the title an adapter's description gives
  # (`Apiary.Integrations.Description`, `title`), its human name for a page. The title is
  # the adapter's text, so it is kept only when it is 1 to `max_title/0` code points, not
  # blank, and holds none of the characters an adapter's name refuses
  # (`Apiary.Names.validate_characters/3`); any other title is kept as nil, and a page
  # shows the adapter's name instead. `Apiary.Adapters.declare/2` calls it at each start,
  # on the changeset of the declaration, so the latest start's title replaces what an
  # earlier one gave. The database holds it to adapters and to the same length
  # (`nodes_title_check`).
  @spec title_changeset(Ecto.Changeset.t(), Description.t()) :: Ecto.Changeset.t()
  def title_changeset(
        %Ecto.Changeset{data: %__MODULE__{kind: :adapter}} = changeset,
        %Description{title: title}
      ) do
    changeset
    |> change(title: if(shown_title?(title), do: title))
    |> check_constraint(:title, name: :nodes_title_check)
  end

  @doc false
  # max_title/0 is the most code points an adapter's title may have (`title_changeset/2`).
  @spec max_title() :: pos_integer
  def max_title, do: @max_adapter_title

  defp shown_title?(title) when is_binary(title) do
    checked =
      {%{}, %{title: :string}}
      |> change(title: title)
      |> validate_length(:title, min: 1, max: @max_adapter_title, count: :codepoints)
      |> Apiary.Names.validate_characters(:title)

    checked.valid? and String.trim(title) != ""
  end

  defp shown_title?(_title), do: false

  @doc false
  # The changeset of the interval an instance admin sets for an adapter's pull,
  # `sync_interval`, in seconds (`Apiary.Adapters.update_sync_interval/3`): one of
  # `choices`, or nil (an empty value) for the adapter's declared default.
  @spec sync_interval_changeset(t, map, [pos_integer]) :: Ecto.Changeset.t()
  def sync_interval_changeset(%__MODULE__{kind: :adapter} = adapter, attrs, choices)
      when is_list(choices) do
    adapter
    |> cast(attrs, [:sync_interval], empty_values: [""])
    |> validate_inclusion(:sync_interval, choices)
    |> check_constraint(:sync_interval, name: :nodes_sync_check)
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
        |> validate_length(:url, max: @max_gateway_url)
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
  validate_url/1 checks `changeset`'s `url`, a gateway's address, by the contracts' rule
  (`Apiary.Contract.GatewayUrl`): `https://`, then a host of DNS labels or an IPv6
  address in brackets, then an optional port, 1 to 65535, and nothing else; no user,
  percent-encoding, underscore, trailing dot, path, query or fragment. A claim answers it
  as `gateway_url`, and a run key names the gateway by it, only over TLS
  (`Apiary.Runs.RunKey`). An address of another scheme that is otherwise right is told to
  start with `https://`. The length, at most 300 characters, is checked apart.
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

  # A scheme in lower case, then `://` and the rest.
  @scheme ~r{\A[a-z][a-z0-9+.-]*://(?<rest>.*)\z}s

  defp address(url) do
    cond do
      GatewayUrl.shape?(url) ->
        :ok

      https_but_scheme?(url) ->
        {:error, dgettext_noop("errors", "must start with https://")}

      true ->
        {:error,
         dgettext_noop(
           "errors",
           "must be a scheme and a host, with a port if needed, and nothing more"
         )}
    end
  end

  defp https_but_scheme?(url) do
    case Regex.named_captures(@scheme, url) do
      %{"rest" => rest} -> GatewayUrl.shape?("https://" <> rest)
      nil -> false
    end
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
