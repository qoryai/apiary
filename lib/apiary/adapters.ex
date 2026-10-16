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
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of no organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed. It acts for an organisation only through a
  # connection (`Apiary.Adapters.Connections.connection_for_key/3`). Each time it starts it
  # declares its connect address and how it pulls (`declare/2`, `adapter.declare`); an
  # instance admin then chooses how often it pulls among the choices that declaration
  # allows (`sync_settings/2`, `update_sync_interval/3`, `adapter.set_interval`), which
  # the adapter learns from its change feed (`Apiary.Adapters.Feed`). When it was last
  # seen is its keys' latest use (`last_seen/2`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Accounts, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Adapters.{ConnectPass, Connections, Feed, Wire}
  alias Apiary.Contract.Ed25519
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

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
           {:ok, adapter} <- Repo.insert(changeset),
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
  # held `FOR SHARE`: the organisation's pending connection to it, made or taken
  # (`Apiary.Adapters.Connections.start/3`, which ends a connected one no listing has
  # named yet and makes a new one in its place), with a new connect pass for it
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
  # connection, never the pass or its nonce.
  #
  # `{:error, :connected}` while the organisation is connected to it and a listing named
  # the connection;
  # `{:error, :no_connect_url}` while the adapter declared no address; `{:error, :no_key}`
  # while it holds no access key in use; `{:error, :forbidden}`; `{:error, :not_found}`;
  # none of them changes anything or leaves an entry.
  @spec connect(Scope.t(), Node.t()) ::
          {:ok, String.t(), {String.t(), String.t()}}
          | {:error,
             :connected | :no_connect_url | :no_key | :invalid | :too_long | Access.reason()}
  def connect(%Scope{} = scope, %Node{id: id}) do
    result =
      Repo.transact(fn ->
        with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
             %Node{} = current <-
               live_query() |> where([n], n.id == ^id) |> lock("FOR SHARE") |> Repo.one() ||
                 {:error, :not_found},
             :ok <- connectable(current),
             nonce = ConnectPass.new_nonce(),
             {:ok, connection, pass} <- Connections.start(scope, current, nonce),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"adapter.connect", scope.organisation, %{
                 details:
                   current
                   |> Map.take([:name, :public_id])
                   |> Map.put(:connection_id, connection.public_id)
               }) do
          {:ok,
           {with_state(current.connect_url, pass), {connection.public_id, Ed25519.encode(nonce)}}}
        end
      end)

    case result do
      {:ok, {url, session}} -> {:ok, url, session}
      {:error, _reason} = error -> error
    end
  end

  defp connectable(%Node{connect_url: nil}), do: {:error, :no_connect_url}

  defp connectable(%Node{} = adapter),
    do: if(AccessKeys.active_key?(adapter), do: :ok, else: {:error, :no_key})

  # The connect address with the pass as the query parameter `state`, before any fragment:
  # `?state=` when the address has no query, `&state=` after one. A pass is base64url and
  # a dot, which a query carries as they are.
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
  # Deletes `adapter` (`adapter.delete`, an instance admin): it leaves every page, its name
  # is free again, and its row stays for what names it. In the same transaction, under its
  # row held `FOR NO KEY UPDATE` (`mutate/3`), its keys in use are revoked and its
  # outstanding codes cancelled (`Apiary.AccessKeys.revoke_node_keys/3`, each key with
  # its entry of `access_key.revoke`), and every connection to it that has not ended ends
  # (`integration_deleted`), which the entry records (`ended_connection_ids`, their public
  # ids).
  # `{:ok, adapter}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def delete_adapter(%Scope{} = scope, %Node{} = adapter) do
    mutate(scope, adapter, fn recorder, current ->
      now = DateTime.utc_now()

      with {:ok, key_ids} <- AccessKeys.revoke_node_keys(recorder, current, :node_deleted),
           connection_ids = Connections.end_for_adapter(current, now),
           {:ok, deleted} <-
             current
             |> Ecto.Changeset.change(deleted_at: now, deleted_by_id: scope.user.id)
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
             }) do
        {:ok, deleted}
      end
    end)
  end

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

  @declared [:connect_url, :sync_default_interval, :sync_minimum_interval, :sync_sends_changes]

  @doc false
  # Stores what the adapter of `scope`, an adapter's key
  # (`Apiary.Accounts.Scope.for_access_key/1`), declared as it started
  # (`Apiary.Adapters.Wire.declaration/1`): its connect address and how it pulls
  # (`adapter.declare`, `for_key/2`). One transaction, with the adapter's row held
  # `FOR NO KEY UPDATE`, as an instance admin's change holds it, so a declaration and a
  # change of the interval come one after the other; an adapter deleted meanwhile is
  # `{:error, :not_found}`.
  #
  # A declaration that changes something leaves an entry in the instance's trail whose
  # actor is the key; one that changes nothing leaves none. The adapter's first
  # declaration appends `{kind: "sync", interval: nil}` to its change feed, its default,
  # and a later one appends nothing: as the contract has it, the feed carries the interval
  # at the first declaration and whenever a person changes it. The interval an instance
  # admin chose stays whatever a later declaration says; the adapter raises one below its
  # minimum to that minimum.
  # `{:ok, adapter}`, `{:error, changeset}`, `{:error, :forbidden}`, or
  # `{:error, :not_found}`.
  @spec declare(Scope.t(), Wire.declaration()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def declare(%Scope{} = scope, %{} = declaration) do
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
               sync_default_interval: declaration.default_interval,
               sync_minimum_interval: declaration.minimum_interval,
               sync_sends_changes: declaration.sends_changes
             })
             |> Repo.update(),
           :ok <- record_declaration(scope, current, declared),
           :ok <- tell_first(current, declared) do
        {:ok, declared}
      end
    end)
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
  # no stored secrets: `{:ok, code_row, code}`, the code in clear this once.
  @spec create_code(Scope.t(), Node.t()) ::
          {:ok, EnrolmentCode.t(), String.t()}
          | {:error, Ecto.Changeset.t() | Access.reason() | :sudo}
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
  # Subscribes an instance admin to `adapter`'s keys and codes (`Apiary.AccessKeys.topic/2`).
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
end
