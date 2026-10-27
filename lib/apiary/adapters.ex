defmodule Apiary.Adapters do
  # Adapters holds the instance's adapters: nodes of kind `:adapter` (`na_…`,
  # `Apiary.Nodes.Node`), each a separate service through which an external system reaches
  # Qory Apiary under an access key of the adapter's node. An adapter is the instance's,
  # with no organisation and no workspace, and is made, renamed and deleted here alone:
  # `Apiary.Nodes` refuses one.
  #
  # An instance admin makes, renames and deletes one (`adapter.create`, `adapter.edit`,
  # `adapter.delete`, which no role takes): each change asks `authorize_instance/2`, an
  # instance admin (`Apiary.Access.instance_admin?/1`) on an instance with the feature
  # `factory`, and, to make one, a recent sign-in, as `Apiary.InstanceConfig.save/3` asks.
  # Each leaves its entry, in its transaction, in the trail of the instance's organisation
  # (`instance_scope/1`). Its access keys are `Apiary.AccessKeys`'s: enrolled with a code
  # an instance admin makes, never made in a browser, never with stored secrets.
  #
  # The people of an organisation read the instance's adapters in use (`adapter.read`,
  # members) where they are shown the feature, and their organisation's connections to
  # them (`Apiary.Adapters.Connections`); an instance admin reads them where the feature
  # is on; anyone else reads none. An owner or an admin of an organisation connects one
  # (`adapter.connect`, `connect/2`), which makes the organisation's connection to it
  # (`Apiary.Adapters.Connection`, `ac_…`), pending until a linked return connects it, and
  # which the organisation's trail records.
  #
  # Deleting an adapter revokes its keys, cancels its codes and ends its connections, in one
  # transaction, with the adapter's row `FOR NO KEY UPDATE`: the lock order is the
  # adapter's row, then its connections (`Apiary.Adapters.Connections`).
  #
  # An adapter may also be **installed with Qory Apiary** (`Apiary.Adapters.Installed`): the
  # setting `QORY_INSTALLED_ADAPTERS` lists it by name, and the instance itself, by itself,
  # makes it (`install/2`, `adapter.install`, which only the instance's role takes) and gives
  # it its one-time codes (`Apiary.AccessKeys.issue_installed_code/2`), in the installer's
  # pass (`Apiary.Adapters.Installer`). Its node's `installed_as` is the name it is listed
  # as. Such an adapter holds one key at most, gets no code from a person, and is not
  # deleted while it is listed (`delete_adapter/2`, `{:error, :installed}`).
  #
  # An adapter that is not set up at the system it reads from declares where to set it
  # up (`setup_url`, `declare/2`). While it does and holds a key in use, an instance admin
  # starts its set-up (`setup/2`, `adapter.setup`): a new setup pass
  # (`Apiary.Adapters.SetupPass`) each time, which the trail of the instance's
  # organisation records without the pass.
  #
  # **The lock order** of every change here: the adapter's row first, then its connections,
  # then what hangs from them; its keys and codes after its row (`Apiary.AccessKeys`, which
  # takes the row `FOR UPDATE`). Nothing locks a connection, a key or a code, and then its
  # adapter.
  #
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of no organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed. It acts for an organisation only through a
  # connection (`Apiary.Adapters.Connections.connection_for_key/3`). Each time it starts it
  # declares its connect address, how it pulls and its description, of which the source
  # role's words and `items` are kept (`declare/2`, `adapter.declare`); an instance admin
  # then chooses how often it pulls among the choices that declaration
  # allows (`sync_settings/2`, `update_sync_interval/3`, `adapter.set_interval`), which
  # the adapter learns from its change feed (`Apiary.Adapters.Feed`). When it was last
  # seen is its keys' latest use (`last_seen/2`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{
    Access,
    AccessKeys,
    Accounts,
    Audit,
    Dispatches,
    Features,
    Organisations,
    PublicId,
    Repo,
    WorkItems
  }

  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}

  alias Apiary.Adapters.{
    Collection,
    Collections,
    Connection,
    ConnectPass,
    Connections,
    Feed,
    Installed,
    SetupPass,
    Wire
  }

  alias Apiary.Contract.Ed25519
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Secrets.{AdapterSealing, Instance, InstanceSecretValue, Reference}

  ## Who may

  @doc false
  # Whether the person of `scope` may change the instance's adapters, their keys and their
  # codes: `:ok` for an instance admin (`Apiary.Access.instance_admin?/1`) on an instance
  # with the feature `factory` (`Apiary.Features.on?/1`), whatever organisation the scope
  # carries and whatever that organisation shows them: an adapter is the instance's, and
  # no organisation's view of the feature says anything of it. `{:error, :not_found}`
  # where the instance does not have the feature, whoever asks; `{:error, :forbidden}` for
  # anyone else. With `sudo: true`, an instance admin who did not sign in recently
  # (`Apiary.Accounts.sudo_mode?/2`) is `{:error, :sudo}`, and signs in again first.
  @spec authorize_instance(Scope.t() | nil, keyword) ::
          :ok | {:error, :not_found | :forbidden | :sudo}
  def authorize_instance(scope, opts \\ []) do
    cond do
      not Features.on?(:factory) -> {:error, :not_found}
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      Keyword.get(opts, :sudo, false) and not signed_in_recently?(scope) -> {:error, :sudo}
      true -> :ok
    end
  end

  defp signed_in_recently?(%Scope{user: user}), do: Accounts.sudo_mode?(user)

  @doc false
  # Whether `scope` may install the adapters listed in `QORY_INSTALLED_ADAPTERS` and give
  # them their codes (`adapter.install`): the instance, by itself
  # (`Apiary.Accounts.Scope.for_instance/2`), in the instance's organisation, on an instance
  # with the feature `factory`. `:ok`; `{:error, :not_found}` where the feature is off;
  # `{:error, :forbidden}` for any other scope, the instance in another organisation among
  # them.
  @spec authorize_install(Scope.t() | nil) :: :ok | {:error, Access.reason()}
  def authorize_install(%Scope{instance: true, organisation: %Organisation{id: id} = org} = scope)
      when is_binary(id) do
    with :ok <- Access.authorize(scope, :"adapter.install", org) do
      if id == Apiary.Edition.instance_organisation_id(), do: :ok, else: {:error, :forbidden}
    end
  end

  def authorize_install(_scope),
    do: if(Features.on?(:factory), do: {:error, :forbidden}, else: {:error, :not_found})

  @doc false
  # The scope an instance admin's change of an adapter, its keys or its codes is recorded
  # with: theirs, in the instance's organisation (`Apiary.Accounts.Scope.in_organisation/2`),
  # whose trail holds the entry, as `Apiary.InstanceConfig.save/3` records a change of the
  # instance's settings. `{:error, :forbidden}` on an instance without that organisation.
  @spec instance_scope(Scope.t()) :: {:ok, Scope.t()} | {:error, :forbidden}
  def instance_scope(%Scope{} = scope) do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, Scope.in_organisation(scope, organisation)}
    else
      _none -> {:error, :forbidden}
    end
  end

  ## Reads

  @doc false
  # The instance's adapters in use, by name, to whoever may read them (`readable?/1`);
  # none to anyone else.
  @spec list_adapters(Scope.t()) :: [Node.t()]
  def list_adapters(%Scope{} = scope) do
    if readable?(scope),
      do: live_query() |> order_by([n], asc: n.name, asc: n.id) |> Repo.all(),
      else: []
  end

  @doc false
  # The instance's adapters in use, by name, with the `factory` feature, for the set-up
  # link's page (`ApiaryWeb.SetupLive`), which nobody is signed in to: its reader becomes
  # the instance admin, and its progress indicator lists the adapters they set up next.
  # None without the feature.
  @spec list_for_set_up() :: [Node.t()]
  def list_for_set_up do
    if Features.on?(:factory),
      do: live_query() |> order_by([n], asc: n.name, asc: n.id) |> Repo.all(),
      else: []
  end

  @doc false
  # The instance's adapter in use whose public id is `public_id`, with the account that
  # made it, to whoever may read it (`readable?/1`); nil for one deleted, a node of another
  # kind, none, or anyone else.
  @spec get_adapter(Scope.t(), term) :: Node.t() | nil
  def get_adapter(%Scope{} = scope, public_id) when is_binary(public_id) do
    if readable?(scope) do
      live_query()
      |> where([n], n.public_id == ^public_id)
      |> preload(:created_by)
      |> Repo.one()
    end
  end

  def get_adapter(%Scope{}, _public_id), do: nil

  @doc false
  # Whether `adapter` is configured: it declares no `setup_url`, which it declares only
  # while it is not set up; it may be connected (`connectable/1`: it declared a connect
  # address and holds an access key in use); and it is listed for organisations: one
  # installed with Qory Apiary while `QORY_INSTALLED_ADAPTERS` lists it (`listed?/1`),
  # one an instance admin added at any time. `setup/2` and `seal_app_values/4` return an
  # error for an installed adapter the list no longer has.
  @spec configured?(Node.t()) :: boolean
  def configured?(%Node{kind: :adapter, setup_url: setup_url} = adapter),
    do:
      is_nil(setup_url) and connectable(adapter) == :ok and
        (not installed?(adapter) or listed?(adapter))

  @doc false
  # The instance's adapters in use that are configured (`configured?/1`), so none that
  # `QORY_INSTALLED_ADAPTERS` no longer lists, and serve `domain`, a module of
  # `Apiary.Lingo.Domain.domains/0`, by name, as `list_adapters/1` orders them. An
  # adapter serves the domains its latest start listed, and every domain where it listed
  # none, as `Apiary.Lingo.Domain.serves?/2` has it. None where the instance does not
  # have the feature `factory`. The caller decides who may read them.
  @spec list_configured(module) :: [Node.t()]
  def list_configured(domain) when is_atom(domain) do
    if Features.on?(:factory) do
      name = domain.name()

      live_query()
      |> where([n], is_nil(n.domains) or ^name in n.domains)
      |> order_by([n], asc: n.name, asc: n.id)
      |> Repo.all()
      |> Enum.filter(&configured?/1)
    else
      []
    end
  end

  @doc false
  # The domains whose adapters the scope's organisation is offered, modules of
  # `Apiary.Lingo.Domain.domains/0`: those of its workspaces, each once, or every domain
  # (`Apiary.Lingo.Domain.choices/0`) while it has none.
  @spec offered_domains(Scope.t()) :: [module]
  def offered_domains(%Scope{} = scope) do
    case scope |> Organisations.list_workspaces() |> Enum.map(&Domain.for_workspace/1) do
      [] -> Domain.choices()
      domains -> Enum.uniq(domains)
    end
  end

  @doc false
  # Whether the scope's organisation is offered `adapter`: it is configured
  # (`configured?/1`) and serves one of `offered_domains/1`, as `list_configured/1` has
  # it. Install asks it (`connect/2`), so an adapter Add an integration does not list is
  # not installed by a request made without the page.
  @spec offered?(Scope.t(), Node.t()) :: boolean
  def offered?(%Scope{} = scope, %Node{domains: domains} = adapter) do
    configured?(adapter) and
      (is_nil(domains) or Enum.any?(offered_domains(scope), &(&1.name() in domains)))
  end

  # The instance's adapters are read by a person of an organisation who may read them
  # there (`adapter.read`, where they are shown the feature), and by an instance admin
  # where the instance has it (`authorize_instance/2`).
  defp readable?(scope),
    do:
      Access.can?(scope, :"adapter.read", scope.organisation) or
        authorize_instance(scope) == :ok

  # The instance's adapters in use: of no organisation and no workspace.
  defp live_query do
    from n in Node,
      where: is_nil(n.organisation_id) and is_nil(n.workspace_id),
      where: n.kind == :adapter and is_nil(n.deleted_at)
  end

  ## The guide

  @doc false
  # guide/2 is the steps `adapter`'s description gives for `part`, `:setup` or `:connect`
  # (`Apiary.Nodes.Node`'s `source_guide`): `%{before: line | nil, steps: [line],
  # after: line | nil}`, each line the integration's words, shown as plain text; nil where
  # it gives none for that part.
  @spec guide(Node.t(), :setup | :connect) ::
          %{before: String.t() | nil, steps: [String.t()], after: String.t() | nil} | nil
  def guide(%Node{kind: :adapter, source_guide: %{} = guide}, part)
      when part in [:setup, :connect] do
    case guide[Atom.to_string(part)] do
      %{"steps" => [_ | _] = steps} = given ->
        %{before: given["before"], steps: steps, after: given["after"]}

      _none ->
        nil
    end
  end

  def guide(%Node{kind: :adapter}, part) when part in [:setup, :connect], do: nil

  ## The words for a source's items

  @doc false
  # item_noun/1 is what `adapter` calls one of its items and many, as its description's
  # source role names them (`Apiary.Nodes.Node`'s `item_noun_one` and `item_noun_other`):
  # `%{one: one, other: other}`, lower case, shown as plain text; nil where it names none,
  # for the default, ticket (`ApiaryWeb.SourceComponents.item/1` and `items/1` say the
  # words). A page or a sentence about one item uses its source's.
  @spec item_noun(Node.t()) :: %{one: String.t(), other: String.t()} | nil
  def item_noun(%Node{kind: :adapter, item_noun_one: one, item_noun_other: other})
      when is_binary(one) and is_binary(other),
      do: %{one: one, other: other}

  def item_noun(%Node{kind: :adapter}), do: nil

  @doc false
  # items?/1 says whether `adapter` reports items: false for a source whose description
  # says `items: false`, which reports collections and no items, so none of its
  # collections is ever linked.
  @spec items?(Node.t()) :: boolean
  def items?(%Node{kind: :adapter, items: items}), do: items

  @doc false
  # shared_item_noun/1 is the words a page about the items of many sources uses, of
  # `adapters`: those of the adapters with items (`items?/1`), when every one of them names
  # the same (`item_noun/1`); nil, the default, ticket, otherwise, and when none has items.
  @spec shared_item_noun([Node.t()]) :: %{one: String.t(), other: String.t()} | nil
  def shared_item_noun(adapters) when is_list(adapters) do
    case adapters |> Enum.filter(&items?/1) |> Enum.map(&item_noun/1) |> Enum.uniq() do
      [%{} = noun] -> noun
      _none_or_several -> nil
    end
  end

  @doc false
  # workspace_item_noun/1 is `shared_item_noun/1` of the sources of the scope's workspace,
  # to a person who may read its work items (`work_item.read`): the adapters, in use, of
  # the live collections of a connected connection assigned to it. nil to anyone else.
  @spec workspace_item_noun(Scope.t()) :: %{one: String.t(), other: String.t()} | nil
  def workspace_item_noun(%Scope{} = scope) do
    if adapters = workspace_sources(scope), do: shared_item_noun(adapters)
  end

  @doc false
  # organisation_item_noun/1 is `shared_item_noun/1` of the sources of the scope's
  # organisation, to a person who may read its Activity (`audit.read`): the adapters, in
  # use, of its connected connections. nil to anyone else.
  @spec organisation_item_noun(Scope.t()) :: %{one: String.t(), other: String.t()} | nil
  def organisation_item_noun(%Scope{} = scope) do
    if adapters = organisation_sources(scope), do: shared_item_noun(adapters)
  end

  # The adapters, in use, of the live collections of a connected connection assigned to
  # the scope's workspace, to a person who may read its work items (`work_item.read`);
  # nil to anyone else.
  defp workspace_sources(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{organisation_id: organisation_id} = workspace
         } = scope
       ) do
    if Access.can?(scope, :"work_item.read", workspace) do
      live_query()
      |> join(:inner, [n], c in Collection, on: c.adapter_id == n.id)
      |> join(:inner, [n, c], k in Connection,
        on: k.id == c.connection_id and k.organisation_id == c.organisation_id
      )
      |> where(
        [n, c, k],
        c.organisation_id == ^organisation_id and c.workspace_id == ^workspace.id and
          is_nil(c.ended_at) and k.state == :connected and is_nil(k.ended_at)
      )
      |> distinct(true)
      |> Repo.all()
    end
  end

  defp workspace_sources(%Scope{}), do: nil

  # The adapters, in use, of the scope's organisation's connected connections, to a
  # person who may read its Activity (`audit.read`); nil to anyone else.
  defp organisation_sources(%Scope{organisation: %Organisation{id: organisation_id}} = scope) do
    if Access.can?(scope, :"audit.read", scope.organisation) do
      live_query()
      |> join(:inner, [n], k in Connection, on: k.adapter_id == n.id)
      |> where(
        [n, k],
        k.organisation_id == ^organisation_id and k.state == :connected and is_nil(k.ended_at)
      )
      |> distinct(true)
      |> Repo.all()
    end
  end

  defp organisation_sources(%Scope{}), do: nil

  @doc false
  # target_item_nouns/2 is, for each of `target_ids`, targets of the organisation
  # `organisation_id`, `shared_item_noun/1` of the adapters of the collections with its
  # system and path, ended ones and those of other workspaces too: what its sources call
  # its items, by target id. A target with none, or whose sources name none, has no key.
  # For the names a page reads with the entries of an audit trail it may read already
  # (`Apiary.Audit.names/2`), so it asks no access.
  @spec target_item_nouns(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          %{Ecto.UUID.t() => %{one: String.t(), other: String.t()}}
  def target_item_nouns(_organisation_id, []), do: %{}

  def target_item_nouns(organisation_id, target_ids) when is_list(target_ids) do
    from(t in Target,
      join: c in Collection,
      on:
        c.organisation_id == t.organisation_id and c.target_system == t.system and
          c.target_path == t.path,
      join: n in Node,
      on: n.id == c.adapter_id,
      where: t.organisation_id == ^organisation_id and t.id in ^target_ids,
      select: {t.id, n}
    )
    |> Repo.all()
    |> Enum.uniq_by(fn {id, adapter} -> {id, adapter.id} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {id, adapters} ->
      case shared_item_noun(adapters) do
        nil -> []
        noun -> [{id, noun}]
      end
    end)
    |> Map.new()
  end

  ## The words for a source's collections

  @doc false
  # collection_noun/1 is what `adapter` calls one of its collections and many, as its
  # description's source role names them (`Apiary.Nodes.Node`'s `collection_noun_one` and
  # `collection_noun_other`): `%{one: one, other: other}`, lower case, shown as plain
  # text; nil where it names none, for the default, "collection" and "collections".
  # An adapter with no items names its collections too.
  @spec collection_noun(Node.t()) :: %{one: String.t(), other: String.t()} | nil
  def collection_noun(%Node{
        kind: :adapter,
        collection_noun_one: one,
        collection_noun_other: other
      })
      when is_binary(one) and is_binary(other),
      do: %{one: one, other: other}

  def collection_noun(%Node{kind: :adapter}), do: nil

  @doc false
  # shared_collection_noun/1 is the words a page about the collections of many sources
  # uses, of `adapters`: those of every one of them, with items or not, since a source
  # with no items still reports collections, when each names the same
  # (`collection_noun/1`); nil, "collections", otherwise, and when there is none.
  @spec shared_collection_noun([Node.t()]) :: %{one: String.t(), other: String.t()} | nil
  def shared_collection_noun(adapters) when is_list(adapters) do
    case adapters |> Enum.map(&collection_noun/1) |> Enum.uniq() do
      [%{} = noun] -> noun
      _none_or_several -> nil
    end
  end

  @doc false
  # workspace_collection_noun/1 is `shared_collection_noun/1` of the sources of the
  # scope's workspace, as `workspace_item_noun/1` reads them, to a person who may read its
  # work items (`work_item.read`). nil to anyone else.
  @spec workspace_collection_noun(Scope.t()) :: %{one: String.t(), other: String.t()} | nil
  def workspace_collection_noun(%Scope{} = scope) do
    if adapters = workspace_sources(scope), do: shared_collection_noun(adapters)
  end

  @doc false
  # organisation_collection_noun/1 is `shared_collection_noun/1` of the sources of the
  # scope's organisation, as `organisation_item_noun/1` reads them, to a person who may
  # read its Activity (`audit.read`). nil to anyone else.
  @spec organisation_collection_noun(Scope.t()) ::
          %{one: String.t(), other: String.t()} | nil
  def organisation_collection_noun(%Scope{} = scope) do
    if adapters = organisation_sources(scope), do: shared_collection_noun(adapters)
  end

  @doc false
  # connection_nouns/2 is, for each of `public_ids`, the public ids of connections of the
  # organisation `organisation_id`, ended ones too, what the source behind it calls its
  # items and its collections: `%{item: item_noun(adapter), collection:
  # collection_noun(adapter)}`, by public id. A public id of no such connection has no
  # key. For the names a page reads with the entries of an audit trail it may read
  # already (`Apiary.Audit.names/2`), so it asks no access.
  @spec connection_nouns(Ecto.UUID.t(), [String.t()]) :: %{
          String.t() => %{
            item: %{one: String.t(), other: String.t()} | nil,
            collection: %{one: String.t(), other: String.t()} | nil
          }
        }
  def connection_nouns(_organisation_id, []), do: %{}

  def connection_nouns(organisation_id, public_ids) when is_list(public_ids) do
    from(k in Connection,
      join: n in Node,
      on: n.id == k.adapter_id,
      where: k.organisation_id == ^organisation_id and k.public_id in ^Enum.uniq(public_ids),
      select: {k.public_id, n}
    )
    |> Repo.all()
    |> Map.new(fn {public_id, adapter} ->
      {public_id, %{item: item_noun(adapter), collection: collection_noun(adapter)}}
    end)
  end

  ## Changes

  @doc false
  # The changeset of an adapter's name, for the form that makes or renames one.
  @spec change_adapter(Node.t(), map) :: Ecto.Changeset.t()
  def change_adapter(adapter \\ %Node{kind: :adapter}, attrs \\ %{})

  def change_adapter(%Node{kind: :adapter} = adapter, attrs),
    do: Node.adapter_changeset(adapter, attrs)

  @doc false
  # Makes an adapter of the instance (`adapter.create`, an instance admin after a recent
  # sign-in, `authorize_instance/2`), from `attrs`, its `name`, unique among the
  # instance's adapters in use. `{:ok, adapter}`, `{:error, changeset}`,
  # `{:error, :forbidden}`, `{:error, :sudo}`, or `{:error, :not_found}` where the feature
  # is off.
  @spec create_adapter(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :sudo}
  def create_adapter(%Scope{} = scope, attrs) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope, sudo: true),
           {:ok, recorder} <- instance_scope(scope),
           changeset =
             Node.adapter_changeset(
               %Node{
                 kind: :adapter,
                 organisation_id: nil,
                 workspace_id: nil,
                 created_by_id: scope.user.id,
                 instance_limit: nil,
                 gateway_choice: :direct
               },
               attrs
             ),
           {:ok, adapter} <- PublicId.Insert.insert(changeset),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"adapter.create", adapter, %{
               after: Map.take(adapter, [:name, :kind, :public_id])
             }) do
        {:ok, adapter}
      end
    end)
  end

  @doc false
  # Makes an adapter from `attrs`, as `create_adapter/2` does, and its first enrolment code
  # (`create_code/2`), in one transaction: `{:ok, adapter, code_row, code}`, or its error.
  @spec create_adapter_with_code(Scope.t(), map) ::
          {:ok, Node.t(), EnrolmentCode.t(), String.t()}
          | {:error, Ecto.Changeset.t() | Access.reason() | :sudo}
  def create_adapter_with_code(%Scope{} = scope, attrs) do
    Repo.transact(fn ->
      with {:ok, adapter} <- create_adapter(scope, attrs),
           {:ok, row, code} <- create_code(scope, adapter),
           do: {:ok, {adapter, row, code}}
    end)
    |> case do
      {:ok, {adapter, row, code}} -> {:ok, adapter, row, code}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # Installs the adapter listed as `name` in `QORY_INSTALLED_ADAPTERS`
  # (`Apiary.Adapters.Installed`): the instance, by itself (`authorize_install/1`,
  # `adapter.install`), finds the adapter in use installed as `name`, or makes it: no
  # organisation, no workspace, no maker, `installed_as` the name, and as its name the name,
  # else `name-2`, `name-3` and on, the first no adapter in use has. A new one leaves the
  # entry `adapter.install` by the instance, in the instance's trail, in its transaction;
  # one found leaves none. Made beside another pass, or beside a person who takes the same
  # name, the insert finds the conflict, reads again, and takes the adapter made or the
  # next name.
  # `{:ok, adapter}`; `{:error, :invalid}` for a name `Apiary.Adapters.Installed.valid_name?/1`
  # refuses; `{:error, changeset}`; `{:error, :forbidden}`; `{:error, :not_found}` where the
  # feature is off.
  @spec install(Scope.t(), String.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :invalid}
  def install(%Scope{} = scope, name) do
    if Installed.valid_name?(name) do
      Repo.transact(fn ->
        with :ok <- authorize_install(scope), do: find_or_install(scope, name, 3)
      end)
    else
      {:error, :invalid}
    end
  end

  defp find_or_install(scope, name, tries) do
    case live_query() |> where([n], n.installed_as == ^name) |> Repo.one() do
      %Node{} = adapter ->
        {:ok, adapter}

      nil when tries > 0 ->
        changeset =
          Node.adapter_changeset(
            %Node{
              kind: :adapter,
              organisation_id: nil,
              workspace_id: nil,
              created_by_id: nil,
              instance_limit: nil,
              gateway_choice: :direct,
              installed_as: name
            },
            %{name: free_name(name)}
          )

        # A conflict with an adapter in use, of the same name or installed as the same,
        # inserts nothing and raises nothing, so the transaction goes on: read again.
        with {:ok, %Node{id: id} = adapter} <- Repo.insert(changeset, on_conflict: :nothing) do
          if Repo.exists?(from n in Node, where: n.id == ^id),
            do: record_install(scope, adapter),
            else: find_or_install(scope, name, tries - 1)
        end

      nil ->
        {:error, :conflict}
    end
  end

  # `name`, else `name-2`, `name-3` and on: the first no adapter in use has.
  defp free_name(name) do
    taken =
      live_query()
      |> where([n], n.name == ^name or like(n.name, ^"#{name}-%"))
      |> select([n], n.name)
      |> Repo.all()
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> name
      n -> "#{name}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp record_install(scope, adapter) do
    with {:ok, _entry} <-
           Audit.record(Repo, scope, :"adapter.install", adapter, %{
             after: Map.take(adapter, [:name, :kind, :public_id, :installed_as])
           }),
         do: {:ok, adapter}
  end

  @doc false
  # Renames `adapter` (`adapter.edit`, an instance admin) from `attrs`, its `name`.
  # `{:ok, adapter}`, unchanged and with no entry when the name is the same;
  # `{:error, changeset}`; `{:error, :forbidden}`; or `{:error, :not_found}`.
  @spec rename_adapter(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def rename_adapter(%Scope{} = scope, %Node{} = adapter, attrs) do
    mutate(scope, adapter, fn recorder, current ->
      with {:ok, renamed} <- current |> Node.adapter_changeset(attrs) |> Repo.update(),
           :ok <- record_rename(recorder, current, renamed) do
        {:ok, renamed}
      end
    end)
  end

  defp record_rename(scope, old, new) do
    case Audit.changed(old, new, [:name]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"adapter.edit", new, changes), do: :ok
    end
  end

  @doc false
  # Starts the connection of `adapter` to the scope's organisation (`adapter.connect`,
  # owners and admins, asked of the organisation), with `adapter` as it is now, in use and
  # held `FOR SHARE`: the organisation's connection to it that has not ended, made or
  # taken, pending or connected (`Apiary.Adapters.Connections.start/3`: a connected one
  # takes the pass for an external account the person adds to it), with a new connect
  # pass for it
  # (`Apiary.Adapters.ConnectPass`), made under the connection's row lock, whose nonce and
  # expiry the connection keeps as its latest pass's; each new pass of a connection
  # expires strictly later than the one before it, and when that would take it more than
  # `Apiary.Adapters.ConnectPass.validity/0` seconds ahead, the pending connection is
  # ended and a new one made in its place too, so the connection named in `session` may
  # be a new one.
  # `{:ok, url, session}`: `url`, the address the adapter declared (`connect_url`) with
  # the pass as its query parameter `state`, where the page sends the person; `session`,
  # `{connection_public_id, nonce}`, the nonce in base64url, which the person's session
  # keeps (`ApiaryWeb.ConnectSession`), so the return comes back in their browser. The
  # entry is the organisation's, about the organisation, naming the adapter and the
  # connection, never the pass or its nonce. Once it commits, the organisation hears that
  # the connection changed (`Apiary.Adapters.Collections.broadcast_connection/1`), and,
  # first, that the one it replaced ended, when it replaced one.
  #
  # `{:error, :too_soon}` when the organisation's connected connection would need a pass
  # that expires too far ahead, as for a second press in the same second;
  # `{:error, :no_connect_url}` while the adapter declared no address; `{:error, :no_key}`
  # while it holds no access key in use; `{:error, :not_offered}` for an adapter the
  # organisation is not offered (`offered?/2`: not configured, or serving none of its
  # workspaces' domains); `{:error, :forbidden}`; `{:error, :not_found}`; none of them
  # changes anything or leaves an entry.
  @spec connect(Scope.t(), Node.t()) ::
          {:ok, String.t(), {String.t(), String.t()}}
          | {:error,
             :too_soon
             | :no_connect_url
             | :no_key
             | :not_offered
             | :invalid
             | :too_long
             | Access.reason()}
  def connect(%Scope{} = scope, %Node{id: id}) do
    result =
      Repo.transact(fn ->
        with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
             %Node{} = current <-
               live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
                 {:error, :not_found},
             :ok <- connectable(current),
             true <- offered?(scope, current) || {:error, :not_offered},
             nonce = ConnectPass.new_nonce(),
             {:ok, connection, pass, replaced} <- Connections.start(scope, current, nonce),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"adapter.connect", scope.organisation, %{
                 details:
                   current
                   |> Map.take([:name, :public_id])
                   |> Map.put(:connection_id, connection.public_id)
               }) do
          {:ok,
           {with_state(current.connect_url, pass), {connection.public_id, Ed25519.encode(nonce)},
            Enum.reject([replaced, connection], &is_nil/1)}}
        end
      end)

    case result do
      {:ok, {url, session, changed}} ->
        Enum.each(changed, &(:ok = Collections.broadcast_connection(&1)))
        {:ok, url, session}

      {:error, _reason} = error ->
        error
    end
  end

  defp connectable(%Node{connect_url: nil}), do: {:error, :no_connect_url}

  defp connectable(%Node{} = adapter),
    do: if(AccessKeys.active_key?(adapter), do: :ok, else: {:error, :no_key})

  # The connect address, or the `setup_url`, with the pass as the query parameter `state`,
  # before any fragment (a `setup_url` has none): `?state=` when the address has no
  # query, `&state=` after one. A pass is base64url and a dot, which a query carries as
  # they are.
  defp with_state(url, pass) do
    {base, fragment} =
      case String.split(url, "#", parts: 2) do
        [base, fragment] -> {base, "#" <> fragment}
        [base] -> {base, ""}
      end

    separator =
      cond do
        not String.contains?(base, "?") -> "?"
        String.ends_with?(base, ["?", "&"]) -> ""
        true -> "&"
      end

    base <> separator <> "state=" <> pass <> fragment
  end

  @doc false
  # Starts the set-up of `adapter` at the system it reads from (`adapter.setup`, an
  # instance admin, `authorize_instance/2`, with no recent sign-in asked: the pass grants
  # nothing in Qory Apiary), with `adapter` as it is now, in use and held `FOR SHARE`: a
  # new setup pass for it (`Apiary.Adapters.SetupPass`), whose nonce nothing here keeps.
  # `{:ok, url}`: the `setup_url` the adapter declared, with the pass as its query
  # parameter `state`, where the page sends the instance admin. The entry is in the trail
  # of the instance's organisation (`instance_scope/1`), about the adapter, naming it,
  # never the pass or its nonce.
  #
  # `{:error, :unlisted}` for an adapter installed with Qory Apiary whose name
  # `QORY_INSTALLED_ADAPTERS` no longer lists (`listed?/1`): it is turned off there, and
  # there is nothing to set up; `{:error, :no_setup_url}` while the adapter declares no
  # `setup_url`, which it does only while it is not set up; `{:error, :no_key}` while it
  # holds no access key in use;
  # `{:error, :forbidden}`; `{:error, :not_found}`, for an adapter deleted, or where the
  # feature is off; none of them changes anything or leaves an entry.
  @spec setup(Scope.t(), Node.t()) ::
          {:ok, String.t()}
          | {:error, :unlisted | :no_setup_url | :no_key | :invalid | Access.reason()}
  def setup(%Scope{} = scope, %Node{id: id}) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope),
           {:ok, recorder} <- instance_scope(scope),
           %Node{} = current <-
             live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
               {:error, :not_found},
           :ok <- settable(current),
           {:ok, pass} <- SetupPass.issue(current.public_id),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"adapter.setup", current, %{
               details: Map.take(current, [:name, :public_id])
             }) do
        {:ok, with_state(current.setup_url, pass)}
      end
    end)
  end

  defp settable(%Node{} = adapter) do
    cond do
      installed?(adapter) and not listed?(adapter) -> {:error, :unlisted}
      is_nil(adapter.setup_url) -> {:error, :no_setup_url}
      not AccessKeys.active_key?(adapter) -> {:error, :no_key}
      true -> :ok
    end
  end

  @doc false
  # Deletes `adapter` (`adapter.delete`, an instance admin): it leaves every page, its name
  # is free again, and its row stays for what names it. In the same transaction, under its
  # row held `FOR NO KEY UPDATE` (`mutate/3`), its keys in use are revoked and its
  # outstanding codes cancelled (`Apiary.AccessKeys.revoke_node_keys/3`, each key with
  # its entry of `access_key.revoke`), and every connection to it that has not ended ends
  # (`integration_deleted`), which the entry records (`ended_connection_ids`, their public
  # ids), and once that commits, each one's organisation hears of it
  # (`Apiary.Adapters.Connections.broadcast_ended_with/1`). After the connections, every
  # live work item whose ticket came through one of them, in every organisation, is
  # closed as a member would close it, by the instance (`Apiary.WorkItems.close_for_adapter/2`,
  # whose moduledoc gives the lock order), and its runs not yet handed over end; once that
  # commits, the workspaces whose queue changed hear of it (`Apiary.Dispatches.broadcast/1`).
  # The tickets are left as they are. The adapter's stored secret and its values are
  # deleted, and its reference to them cleared (`Apiary.Secrets.Instance`), which the
  # entry records (`app_values_deleted`). If a close fails, nothing of the deletion is kept.
  # An adapter installed with Qory Apiary whose name `QORY_INSTALLED_ADAPTERS` still lists
  # is `{:error, :installed}`, and nothing changes: the installer would make it again; once
  # the name is off the list, it is deleted as any adapter is, and its file is left as the
  # installer left it.
  # `{:ok, adapter}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()}
          | {:error, Ecto.Changeset.t() | Access.reason() | :not_live | :installed}
  def delete_adapter(%Scope{} = scope, %Node{} = adapter) do
    mutate(scope, adapter, fn recorder, current ->
      now = DateTime.utc_now()

      with :ok <- removable(current),
           {:ok, key_ids} <- AccessKeys.revoke_node_keys(recorder, current, :node_deleted),
           connection_ids = Connections.end_for_adapter(current, now),
           {:ok, workspace_ids} <- WorkItems.close_for_adapter(current, now),
           app_values_deleted = Instance.delete_app_values(Repo, current),
           {:ok, deleted} <-
             current
             |> Ecto.Changeset.change(
               deleted_at: now,
               deleted_by_id: scope.user.id,
               secret_store: nil,
               secret_entry: nil
             )
             |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, recorder, :"adapter.delete", deleted, %{
               before: %{deleted_at: nil},
               after: %{deleted_at: deleted.deleted_at},
               details:
                 deleted
                 |> Map.take([:name, :kind, :public_id])
                 |> Map.put(:revoked_key_ids, key_ids)
                 |> Map.put(:ended_connection_ids, connection_ids)
                 |> Map.put(:app_values_deleted, app_values_deleted)
             }) do
        {:ok, {deleted, workspace_ids}}
      end
    end)
    |> case do
      {:ok, {deleted, workspace_ids}} ->
        :ok = Connections.broadcast_ended_with(deleted)
        :ok = Dispatches.broadcast(workspace_ids)
        {:ok, deleted}

      {:error, _reason} = refused ->
        refused
    end
  end

  defp removable(%Node{installed_as: name}),
    do: if(Installed.listed?(name), do: {:error, :installed}, else: :ok)

  @doc false
  # listed?/1 says whether `adapter` is installed with Qory Apiary and its name
  # `QORY_INSTALLED_ADAPTERS` still lists (`Apiary.Adapters.Installed.listed?/1`): it is not
  # removed while it is.
  @spec listed?(Node.t()) :: boolean
  def listed?(%Node{kind: :adapter, installed_as: name}), do: Installed.listed?(name)

  @doc false
  # installed?/1 says whether `adapter` is installed with Qory Apiary, listed or not.
  @spec installed?(Node.t()) :: boolean
  def installed?(%Node{kind: :adapter, installed_as: name}), do: is_binary(name)

  # Asks `authorize_instance/2` of the person as they are now, then hands `fun` the scope
  # the change is recorded with (`instance_scope/1`) and the adapter as it is now, in use,
  # locked for the rest of the transaction.
  #
  # `FOR NO KEY UPDATE`, not `FOR UPDATE`: a rename and a deletion change no column a
  # reference names (`id`, `public_id`, `organisation_id`, `workspace_id`), so they need
  # not wait on, or keep out, the `FOR KEY SHARE` that Postgres takes on the adapter's row
  # to check a reference to it. It still keeps out a connect, which holds the row
  # `FOR SHARE`, and a change of the adapter's keys (`Apiary.AccessKeys`), which holds it
  # `FOR UPDATE`.
  defp mutate(scope, %Node{id: id}, fun) do
    Repo.transact(fn ->
      with :ok <- authorize_instance(scope),
           {:ok, recorder} <- instance_scope(scope),
           %Node{} = current <-
             live_query()
             |> where([n], n.id == ^id)
             |> lock("FOR NO KEY UPDATE")
             |> Repo.one() ||
               {:error, :not_found} do
        fun.(recorder, current)
      end
    end)
  end

  ## How often it pulls

  # The intervals an instance admin may choose, in seconds, one ladder for every adapter:
  # a minute, 5, 10, 15 and 30 minutes, an hour, 2, 6 and 12 hours, and a day, the
  # contract's longest (`Apiary.Adapters.Wire.interval_range/0`). An adapter's choices
  # are the steps at or above its declared minimum, and its declared default, which may
  # be off the ladder (`sync_choices/1`).
  @sync_ladder [60, 300, 600, 900, 1800, 3600, 7200, 21_600, 43_200, 86_400]

  @typedoc """
  How often an adapter pulls: the interval an instance admin chose (nil for the adapter's
  default), what the adapter declared (each nil until it first declares), and the
  intervals an instance admin may choose (none before it declares).
  """
  @type sync :: %{
          interval: pos_integer | nil,
          default: pos_integer | nil,
          minimum: pos_integer | nil,
          sends_changes: boolean | nil,
          choices: [pos_integer]
        }

  @doc false
  # How often `adapter` pulls, to an instance admin (`authorize_instance/2`), read from the
  # adapter in use now: `{:ok, sync}`, with `interval` as stored even when a later
  # declaration leaves it out of `choices` (below the minimum; the adapter raises such an
  # interval to its minimum, as the contract has it). `{:error, :forbidden}` for anyone
  # else, `{:error, :not_found}` where the feature is off or the adapter is deleted.
  @spec sync_settings(Scope.t(), Node.t()) :: {:ok, sync} | {:error, Access.reason()}
  def sync_settings(%Scope{} = scope, %Node{kind: :adapter, id: id}) do
    with :ok <- authorize_instance(scope),
         %Node{} = current <-
           live_query() |> where([n], n.id == ^id) |> Repo.one() || {:error, :not_found} do
      {:ok, sync(current)}
    end
  end

  defp sync(%Node{} = adapter) do
    %{
      interval: adapter.sync_interval,
      default: adapter.sync_default_interval,
      minimum: adapter.sync_minimum_interval,
      sends_changes: adapter.sync_sends_changes,
      choices: sync_choices(adapter)
    }
  end

  # The intervals an instance admin may choose for `adapter`: the ladder's steps at or
  # above its declared minimum, with its declared default, in order; none before it
  # declares.
  defp sync_choices(%Node{sync_minimum_interval: minimum, sync_default_interval: default})
       when is_integer(minimum) and is_integer(default) do
    [default | Enum.filter(@sync_ladder, &(&1 >= minimum))]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sync_choices(%Node{}), do: []

  @doc false
  # Sets how often `adapter` pulls (`adapter.set_interval`, an instance admin,
  # `authorize_instance/2`) from `attrs`'s `sync_interval`, in seconds: one of
  # `sync_settings/2`'s `choices`, an integer or its decimal string, or nil or `""` for
  # the adapter's declared default. In one transaction, under the adapter's row held
  # `FOR NO KEY UPDATE` (`mutate/3`): a change leaves its entry in the instance's trail
  # and appends `{kind: "sync", interval}` to the adapter's change feed
  # (`Apiary.Adapters.Feed`, nil for the default), which is how the adapter learns of it;
  # the same interval changes nothing and leaves neither.
  # `{:ok, adapter}`; `{:error, :not_declared}` while the adapter has not declared how it
  # pulls; `{:error, changeset}` for a value that is not one of the choices;
  # `{:error, :forbidden}`; or `{:error, :not_found}`.
  @spec update_sync_interval(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason() | :not_declared}
  def update_sync_interval(%Scope{} = scope, %Node{kind: :adapter} = adapter, attrs)
      when is_map(attrs) do
    mutate(scope, adapter, fn recorder, current ->
      with :ok <- declared(current),
           {:ok, updated} <-
             current
             |> Node.sync_interval_changeset(sync_attrs(attrs), sync_choices(current))
             |> Repo.update(),
           :ok <- record_interval(recorder, current, updated) do
        {:ok, updated}
      end
    end)
  end

  defp declared(%Node{sync_default_interval: default}) when is_integer(default), do: :ok
  defp declared(%Node{}), do: {:error, :not_declared}

  # The interval as a page sends it, under a string key or an atom one.
  defp sync_attrs(attrs) do
    case Map.new(attrs, fn {key, value} -> {to_string(key), value} end) do
      %{"sync_interval" => interval} -> %{"sync_interval" => interval}
      _other -> %{}
    end
  end

  defp record_interval(recorder, old, new) do
    case Audit.changed(old, new, [:sync_interval]) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, recorder, :"adapter.set_interval", new, changes),
             {:ok, _seq} <- Feed.append(new, %{kind: "sync", interval: new.sync_interval}),
             do: :ok
    end
  end

  ## What an adapter declares

  @declared [
    :connect_url,
    :setup_url,
    :call_url,
    :sync_default_interval,
    :sync_minimum_interval,
    :sync_sends_changes
  ]

  @doc false
  # Stores what the adapter of `scope`, an adapter's key
  # (`Apiary.Accounts.Scope.for_access_key/1`), declared as it started
  # (`Apiary.Adapters.Wire.declaration/1`): its connect address, where an instance admin
  # sets it up (`setup_url`, which a declaration without one clears: the adapter declares
  # it only while it is not set up), where Qory Apiary calls it (`call_url`, with the
  # instance id of the request that declared it, `instance_id`, which the calls are
  # signed for; a declaration without one clears both), how it pulls
  # (`adapter.declare`, `for_key/2`), and what its description's source role says. One
  # transaction, with the adapter's row held `FOR NO KEY UPDATE`, as an instance admin's
  # change holds it, so a declaration and a change of the interval come one after the
  # other; an adapter deleted meanwhile is `{:error, :not_found}`.
  #
  # A declaration that changes its connect address, its `setup_url`, its `call_url` or how
  # it pulls leaves an entry in the instance's trail whose actor is the key; one that
  # changes none of them leaves none. The adapter's first declaration appends
  # `{kind: "sync", interval: nil}` to its change feed, its default, and a later one
  # appends nothing: as the contract has it, the feed carries the interval at the first
  # declaration and whenever a person changes it. The interval an instance admin chose
  # stays whatever a later declaration says; the adapter raises one below its minimum to
  # that minimum.
  #
  # Each start also stores what its description's source role says
  # (`Apiary.Nodes.Node.source_role_changeset/2`): its words for its items, whether it
  # reports items, its words for its collections, and its line on how to change which
  # collections it reaches, and the apply items of each run's work credential from it with
  # its description's exact `egress_hosts`, each replacing what the start before said; a
  # description with no source role stores the defaults, no words, items, no line and no
  # apply items. A description whose apply items name a host that is not an entry of its
  # `egress_hosts`, or a path template that a target path could fill to a path out of
  # Forager's path grammar, never reaches here: the start's body is refused as it is read
  # (`Apiary.Integrations.Description.parse/1`). Each start also
  # stores the domains its description lists, nil for none
  # (`Apiary.Nodes.Node.domains_changeset/2`); a start that narrows them leaves every
  # collection assigned as it was. They are no part of the trail's entry. A start that
  # changes `items` writes the feed's `linked` or `unlinked` entry for each live
  # collection whose link that changes, in the same transaction
  # (`Apiary.Adapters.Collections.relink_adapter/2`), before the first declaration's
  # `sync` entry, so that the feed counter is taken after the collections, last, as the
  # lock order has it; after the commit those collections are broadcast.
  # A start that changes the source's line on access or its words for its items or its
  # collections tells, after the commit, each organisation with a connection to the
  # adapter that its connection changed, once (`connection_changed`), so an open page of
  # the integration shows them; a start that changes none of them tells none. The start is
  # stored by then: where the database fails to read those connections, the failure is
  # logged, no organisation is told, and the start answers as stored. `opts[:connections]`
  # replaces that read, a function of the adapter, for a test that makes it fail. A start
  # that changes the adapter's `setup_url` or `connect_url` tells, after the commit, the
  # pages subscribed to its keys (`subscribe_keys/2`), as the instance's connections show
  # whether it is configured (`configured?/1`).
  # `{:ok, adapter}`, `{:error, changeset}`, `{:error, :forbidden}`, or
  # `{:error, :not_found}`.
  @spec declare(Scope.t(), Wire.declaration(), keyword) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def declare(%Scope{} = scope, %{} = declaration, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, %Node{id: id}} <- for_key(scope, :"adapter.declare"),
           %Node{} = current <-
             live_query()
             |> where([n], n.id == ^id)
             |> lock("FOR NO KEY UPDATE")
             |> Repo.one() || {:error, :not_found},
           {:ok, declared} <-
             current
             |> Node.declaration_changeset(%{
               connect_url: declaration.connect_url,
               setup_url: Map.get(declaration, :setup_url),
               call_url: Map.get(declaration, :call_url),
               call_instance_id:
                 if(Map.get(declaration, :call_url), do: Map.get(declaration, :instance_id)),
               sync_default_interval: declaration.default_interval,
               sync_minimum_interval: declaration.minimum_interval,
               sync_sends_changes: declaration.sends_changes
             })
             |> Node.source_role_changeset(declaration.description)
             |> Node.domains_changeset(declaration.description)
             |> Repo.update(),
           :ok <- record_declaration(scope, current, declared),
           {:ok, relinked} <- Collections.relink_adapter(current, declared),
           :ok <- tell_first(current, declared) do
        {:ok,
         {declared, relinked, shown_changed?(current, declared),
          set_up_changed?(current, declared)}}
      end
    end)
    |> case do
      {:ok, {declared, relinked, shown_changed?, set_up_changed?}} ->
        :ok = Collections.broadcast_relinked(relinked)
        connections = Keyword.get(opts, :connections, &connections_told/1)
        if shown_changed?, do: :ok = broadcast_shown(declared, connections)
        if set_up_changed?, do: :ok = broadcast_declared(declared)
        {:ok, declared}

      {:error, _reason} = refused ->
        refused
    end
  end

  # What an integration's page shows of a start: the source's line on access and its words
  # for its items and its collections.
  @shown [
    :source_access,
    :item_noun_one,
    :item_noun_other,
    :collection_noun_one,
    :collection_noun_other
  ]

  defp shown_changed?(current, declared),
    do: Map.take(current, @shown) != Map.take(declared, @shown)

  # Whether a start changed what `configured?/1` reads of the adapter: where to set it up
  # and where to connect to it.
  defp set_up_changed?(current, declared),
    do:
      Map.take(current, [:setup_url, :connect_url]) !=
        Map.take(declared, [:setup_url, :connect_url])

  # After the start commits: tells the pages subscribed to the adapter's keys
  # (`subscribe_keys/2`) that whether it is configured may have changed.
  defp broadcast_declared(%Node{id: id} = adapter),
    do:
      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        AccessKeys.topic(AccessKeys.place_id(adapter), id),
        {:adapter_declared, %{node_id: id}}
      )

  # After the start commits: tells each organisation with a connection to the adapter that
  # it changed (`Apiary.Adapters.Collections.broadcast_connection/1`), once, naming the
  # connection `connections` reads for it. The start is stored already, so a read the
  # database fails is logged, by the error's kind alone, and tells none.
  defp broadcast_shown(%Node{} = adapter, connections) do
    adapter |> connections.() |> Enum.each(&(:ok = Collections.broadcast_connection(&1)))
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error(
        "could not tell the organisations connected to adapter #{adapter.public_id} " <>
          "that its start changed what their pages show: #{failure_kind(error)}"
      )

      :ok
  end

  defp failure_kind(%Postgrex.Error{postgres: %{code: code}}), do: inspect(code)
  defp failure_kind(error), do: inspect(error.__struct__)

  # Each organisation's connection to `adapter` that has not ended, else the one that
  # ended last.
  defp connections_told(%Node{id: adapter_id}) do
    from(c in Connection,
      where: c.adapter_id == ^adapter_id,
      distinct: c.organisation_id,
      order_by: [desc_nulls_first: c.ended_at, desc: c.inserted_at],
      select: %{id: c.id, organisation_id: c.organisation_id, adapter_id: c.adapter_id}
    )
    |> Repo.all()
  end

  defp record_declaration(scope, current, declared) do
    case Audit.changed(current, declared, @declared) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"adapter.declare", declared, changes),
             do: :ok
    end
  end

  # The adapter's interval is its default from its first declaration on: the feed says so
  # once.
  defp tell_first(%Node{sync_default_interval: nil}, declared) do
    with {:ok, _seq} <- Feed.append(declared, %{kind: "sync", interval: nil}), do: :ok
  end

  defp tell_first(%Node{}, _declared), do: :ok

  ## When it was last seen

  @doc false
  # When `adapter` was last seen, as a node is: the latest use of any of its access keys,
  # revoked ones included (`last_used_at`, which every accepted request of an adapter's key
  # records, `ApiaryWeb.Contract.AdapterRequest`), or nil when none was ever used. Given a
  # list of adapters, a map of each one's id to its time, one query, without the adapters
  # never seen. To an instance admin (`authorize_instance/2`), `{:ok, time}` or
  # `{:ok, map}`; `{:error, :forbidden}` for anyone else, `{:error, :not_found}` where the
  # feature is off.
  @spec last_seen(Scope.t(), Node.t()) :: {:ok, DateTime.t() | nil} | {:error, Access.reason()}
  @spec last_seen(Scope.t(), [Node.t()]) ::
          {:ok, %{Ecto.UUID.t() => DateTime.t()}} | {:error, Access.reason()}
  def last_seen(%Scope{} = scope, %Node{kind: :adapter, id: id} = adapter) do
    with {:ok, seen} <- last_seen(scope, [adapter]), do: {:ok, Map.get(seen, id)}
  end

  def last_seen(%Scope{} = scope, adapters) when is_list(adapters) do
    with :ok <- authorize_instance(scope) do
      {:ok, last_used(for %Node{kind: :adapter, id: id} <- adapters, do: id)}
    end
  end

  defp last_used([]), do: %{}

  defp last_used(ids) do
    from(k in AccessKey,
      where: k.node_id in ^ids and not is_nil(k.last_used_at),
      where: is_nil(k.organisation_id) and is_nil(k.workspace_id),
      group_by: k.node_id,
      select: {k.node_id, max(k.last_used_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## Keys and codes

  @doc false
  # `adapter`'s keys, those in use first, to an instance admin; none to anyone else.
  @spec list_keys(Scope.t(), Node.t()) :: [AccessKey.t()]
  def list_keys(%Scope{} = scope, %Node{kind: :adapter} = adapter),
    do: AccessKeys.list_for_node(scope, adapter)

  @doc false
  # `adapter`'s outstanding enrolment codes, newest first, to an instance admin; none to
  # anyone else.
  @spec list_codes(Scope.t(), Node.t()) :: [EnrolmentCode.t()]
  def list_codes(%Scope{} = scope, %Node{kind: :adapter} = adapter),
    do: AccessKeys.list_enrolment_codes(scope, adapter)

  @doc false
  # Makes an enrolment code for `adapter` (an instance admin after a recent sign-in), with
  # no stored secrets: `{:ok, code_row, code}`, the code in clear this once;
  # `{:error, :installed}` for an adapter installed with Qory Apiary, which gets its codes
  # from the instance.
  @spec create_code(Scope.t(), Node.t()) ::
          {:ok, EnrolmentCode.t(), String.t()}
          | {:error, Ecto.Changeset.t() | Access.reason() | :sudo | :installed}
  def create_code(%Scope{} = scope, %Node{kind: :adapter} = adapter),
    do: AccessKeys.create_enrolment_code(scope, adapter, %{})

  @doc false
  # Revokes an adapter's key (an instance admin), as `Apiary.AccessKeys.revoke_access_key/2`.
  @spec revoke_key(Scope.t(), AccessKey.t()) :: {:ok, AccessKey.t()} | {:error, Access.reason()}
  def revoke_key(%Scope{} = scope, %AccessKey{organisation_id: nil, workspace_id: nil} = key),
    do: AccessKeys.revoke_access_key(scope, key)

  @doc false
  # Cancels an adapter's outstanding enrolment code (an instance admin), as
  # `Apiary.AccessKeys.cancel_code/2`.
  @spec cancel_code(Scope.t(), EnrolmentCode.t()) ::
          {:ok, EnrolmentCode.t()} | {:error, :used | Access.reason()}
  def cancel_code(
        %Scope{} = scope,
        %EnrolmentCode{organisation_id: nil, workspace_id: nil} = code
      ),
      do: AccessKeys.cancel_code(scope, code)

  @doc false
  # Subscribes an instance admin to `adapter`'s keys and codes (`Apiary.AccessKeys.topic/2`),
  # and to its starts that change where to set it up or to connect to it
  # (`{:adapter_declared, %{node_id: id}}`, `declare/3`).
  @spec subscribe_keys(Scope.t(), Node.t()) :: :ok | {:error, term}
  def subscribe_keys(%Scope{} = scope, %Node{kind: :adapter} = adapter),
    do: AccessKeys.subscribe(scope, adapter)

  ## At the server contract

  @doc false
  # The adapter an access key's scope stands for, once `action` is allowed to it
  # (`Apiary.Access.authorize/3`, asked of the adapter): `{:ok, adapter}`, or `{:error,
  # :not_found}` for a scope of no key, a key with an organisation or a workspace, a key
  # whose node is no adapter in use, or an action the key may not take there,
  # `{:error, :forbidden}` for one its role does not hold.
  @spec for_key(Scope.t(), Access.action()) :: {:ok, Node.t()} | {:error, Access.reason()}
  def for_key(
        %Scope{
          access_key: %AccessKey{node_id: node_id, organisation_id: nil, workspace_id: nil}
        } = scope,
        action
      )
      when is_binary(node_id) do
    adapter = live_query() |> where([n], n.id == ^node_id) |> Repo.one()

    with %Node{} <- adapter || {:error, :not_found},
         :ok <- Access.authorize(scope, action, adapter) do
      {:ok, adapter}
    end
  end

  def for_key(%Scope{}, _action), do: {:error, :not_found}

  @doc false
  # Stores `values`, the secrets `adapter` keeps in Qory Apiary, opened from its upload,
  # for the adapter's key's `scope` (`adapter.app_values_set`): they replace every secret
  # it stored before (`Apiary.Secrets.Instance.put_app_values/3`). In the same
  # transaction, with the adapter's row held, each name must be one the source role of its
  # latest description lists (`secret_names`), and the entry is in the trail the key
  # records in, about the adapter, with the reference, the names, the revision and
  # whether the upload replaced secrets: never a value.
  #
  # `{:ok, stored}`; `{:error, :undeclared}` for a name the description does not list;
  # else what `Apiary.Secrets.Instance.put_app_values/3` answers. None of the refusals
  # changes anything or leaves an entry.
  @spec store_app_values(Scope.t(), Node.t(), [InstanceSecretValue.t()]) ::
          {:ok, Instance.stored()} | {:error, term}
  def store_app_values(%Scope{} = scope, %Node{kind: :adapter} = adapter, values) do
    Instance.put_app_values(adapter, values,
      allowed: &declared_names(&1, values),
      record: fn locked, stored ->
        Audit.record(Repo, scope, :"adapter.app_values_set", locked, %{
          details: %{
            reference: Reference.to_string(stored.reference),
            names: stored.names,
            revision: stored.revision,
            replaced: stored.replaced
          }
        })
      end
    )
  end

  @doc false
  # The answer to `adapter`'s key's read of the secrets the adapter keeps in Qory Apiary
  # (`adapter.app_values_seal`), for the key's `scope`: every secret it stored, sealed to
  # `key`, the access key the request verified under, with a fresh ephemeral key, for the
  # contract revision `revision` (`Apiary.Secrets.AdapterSealing.delivery/3`). With no
  # secret stored, the answer seals an empty list. In one transaction, with the adapter's
  # row held `FOR SHARE`, each read leaves an entry in the trail the key records in, about
  # the adapter, with the access key's id, the secrets' revision and their names: never a
  # value.
  #
  # `{:ok, body}`, the answer's bytes; `{:error, :not_found}` for an adapter deleted, or
  # installed with Qory Apiary and no longer listed; `{:error, :key}` for an access key
  # that fails a key check (`Apiary.Contract.Ed25519.check_public_key/1`) or a seal that
  # fails; `{:error, :unavailable}` when a secret cannot be decrypted, which the log says,
  # without a value. None of the refusals leaves an entry.
  @spec seal_app_values(Scope.t(), Node.t(), AccessKey.t(), pos_integer) ::
          {:ok, binary} | {:error, :not_found | :key | :unavailable | term}
  def seal_app_values(
        %Scope{} = scope,
        %Node{kind: :adapter, id: id},
        %AccessKey{} = key,
        revision
      ) do
    Repo.transact(fn ->
      with %Node{} = adapter <-
             live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
               {:error, :not_found},
           :ok <-
             if(installed?(adapter) and not listed?(adapter), do: {:error, :not_found}, else: :ok),
           :ok <- recipient_key(key),
           {:ok, %{revision: secrets_revision, values: values}} <-
             Instance.reveal_app_values_for_sealing(adapter),
           {:ok, body} <-
             AdapterSealing.delivery(
               values,
               %{
                 adapter_id: adapter.public_id,
                 access_key_id: key.key_id,
                 public_key: key.public_key
               },
               revision
             ),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.app_values_seal", adapter, %{
               details: %{
                 access_key_id: key.key_id,
                 revision: secrets_revision,
                 names: Enum.map(values, & &1.value_id)
               }
             }) do
        {:ok, body}
      end
    end)
  end

  defp recipient_key(%AccessKey{public_key: public_key}) do
    case Ed25519.check_public_key(public_key) do
      :ok -> :ok
      {:error, _refusal} -> {:error, :key}
    end
  end

  defp declared_names(%Node{secret_names: names}, values) do
    names = names || []

    if Enum.all?(values, fn %InstanceSecretValue{value_id: id} -> id in names end),
      do: :ok,
      else: {:error, :undeclared}
  end
end
