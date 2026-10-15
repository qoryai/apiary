defmodule Apiary.Adapters do
  # Adapters holds an organisation's adapters: nodes of kind `:adapter` (`na_…`,
  # `Apiary.Nodes.Node`), each a separate service through which an external system reaches
  # Qory Apiary under an access key of the adapter's node. An adapter lives at its organisation,
  # with no workspace, and is made, renamed, connected and deleted here alone:
  # `Apiary.Nodes` refuses one.
  #
  # Every function a page calls takes a scope of the organisation and reads or changes only
  # its adapters in use; an adapter of another organisation, a deleted one, or a node of
  # another kind is not found. Each change asks `Apiary.Access` first, `adapter.create`,
  # `adapter.edit`, `adapter.connect` or `adapter.delete` (owners and admins), all of the
  # feature `factory`, so a change where the feature is off or hidden from the person is
  # not found; and leaves its audit entry in its transaction. Its access keys are
  # `Apiary.AccessKeys`'s: enrolled with a code (`access_key.create_code`), never made in a
  # browser, never with stored secrets.
  #
  # A node pool may name the adapter that serves it (`served_by_id`, `Apiary.Nodes`): one of
  # `serving_choices/1`. Deleting an adapter revokes its keys, cancels its codes and clears
  # every pool it served, in one transaction, under the organisation's lock that a change
  # of a pool takes too (`Apiary.Gateways.lock/1`), with the adapter's row `FOR UPDATE`.
  #
  # A person connects an adapter with `connect/2`: the address the adapter declared, with a
  # connect pass (`Apiary.Adapters.ConnectPass`) as its `state`. How often the adapter
  # checks the source is `sync/1`: what it declared, and the interval a person chose among
  # `sync/1`'s `choices` (`update_sync/3`, `adapter.edit`), which the adapter learns from
  # its change feed (`Apiary.Adapters.Feed`).
  #
  # At the server contract an adapter's key acts as the role `adapter_key`
  # (`Apiary.Access.role/1`), with a scope of its organisation and no workspace
  # (`Apiary.Accounts.Scope.for_access_key/1`): `for_key/2` is the adapter such a scope
  # stands for, once the action is allowed.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Audit, Gateways, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Adapters.{ConnectPass, Feed}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  ## Reads

  @doc false
  # The scope's organisation's adapters in use, by name.
  @spec list_adapters(Scope.t()) :: [Node.t()]
  def list_adapters(%Scope{} = scope) do
    scope
    |> live_query()
    |> order_by([n], asc: n.name, asc: n.id)
    |> Repo.all()
  end

  @doc false
  # The scope's organisation's adapter in use whose public id is `public_id`, with the
  # account that made it; nil for one deleted, of another organisation, a node of another
  # kind, or none.
  @spec get_adapter(Scope.t(), term) :: Node.t() | nil
  def get_adapter(%Scope{} = scope, public_id) when is_binary(public_id) do
    scope
    |> live_query()
    |> where([n], n.public_id == ^public_id)
    |> preload(:created_by)
    |> Repo.one()
  end

  def get_adapter(%Scope{}, _public_id), do: nil

  @doc false
  # The adapters a node pool of the scope's organisation may name as the one that serves
  # it: the organisation's adapters in use, by name.
  @spec serving_choices(Scope.t()) :: [Node.t()]
  def serving_choices(%Scope{} = scope), do: list_adapters(scope)

  @doc false
  # The node pools in use of the scope's organisation, in any of its workspaces, that
  # `adapter` serves, by name.
  @spec served_pools(Scope.t(), Node.t()) :: [Node.t()]
  def served_pools(
        %Scope{organisation: %Organisation{id: organisation_id}},
        %Node{kind: :adapter, id: id, organisation_id: organisation_id}
      ) do
    from(n in Node,
      where: n.organisation_id == ^organisation_id and n.served_by_id == ^id,
      where: n.kind == :pool and is_nil(n.deleted_at),
      order_by: [asc: n.name, asc: n.id]
    )
    |> Repo.all()
  end

  def served_pools(%Scope{}, %Node{}), do: []

  # The scope's organisation's adapters in use.
  defp live_query(%Scope{organisation: %Organisation{id: organisation_id}}) do
    from n in Node,
      where: n.organisation_id == ^organisation_id and is_nil(n.workspace_id),
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
  # Makes an adapter of the scope's organisation (`adapter.create`, owners and admins),
  # from `attrs`, its `name`. `{:ok, adapter}`, `{:error, changeset}`, `{:error,
  # :forbidden}`, or `{:error, :not_found}` where the feature is off or hidden from the
  # person, or the organisation out of their reach.
  @spec create_adapter(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def create_adapter(
        %Scope{user: user, organisation: %Organisation{id: organisation_id} = organisation} =
          scope,
        attrs
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"adapter.create", organisation),
           changeset =
             Node.adapter_changeset(
               %Node{
                 kind: :adapter,
                 organisation_id: organisation_id,
                 workspace_id: nil,
                 created_by_id: user.id,
                 instance_limit: nil,
                 gateway_choice: :direct
               },
               attrs
             ),
           {:ok, adapter} <- Repo.insert(changeset),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.create", adapter, %{
               after: Map.take(adapter, [:name, :kind, :public_id])
             }) do
        {:ok, adapter}
      end
    end)
  end

  @doc false
  # Renames `adapter` (`adapter.edit`, owners and admins) from `attrs`, its `name`.
  # `{:ok, adapter}`, unchanged and with no entry when the name is the same;
  # `{:error, changeset}`; `{:error, :forbidden}`; or `{:error, :not_found}`.
  @spec rename_adapter(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def rename_adapter(%Scope{} = scope, %Node{} = adapter, attrs) do
    mutate(scope, :"adapter.edit", adapter, fn current ->
      with {:ok, renamed} <- current |> Node.adapter_changeset(attrs) |> Repo.update(),
           :ok <- record_rename(scope, current, renamed) do
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
  # Starts the connection of `adapter` (`adapter.connect`, owners and admins): `{:ok, url}`,
  # the address the adapter declared (`connect_url`) with a fresh connect pass as its query
  # parameter `state`, where the page sends the person; the pass is in no entry and is
  # stored nowhere. `{:error, :no_connect_url}` while the adapter has declared none,
  # `{:error, :no_key}` while it holds no active access key, `{:error, :forbidden}`, or
  # `{:error, :not_found}`; none of them leaves an entry.
  @spec connect(Scope.t(), Node.t()) ::
          {:ok, String.t()}
          | {:error, :no_connect_url | :no_key | :invalid | :too_long | Access.reason()}
  def connect(%Scope{} = scope, %Node{} = adapter) do
    connect(scope, adapter, fn current ->
      cond do
        is_nil(current.connect_url) ->
          {:error, :no_connect_url}

        not AccessKeys.active_key?(current) ->
          {:error, :no_key}

        true ->
          with {:ok, pass} <- ConnectPass.issue(current.public_id),
               do: {:ok, with_state(current.connect_url, pass)}
      end
    end)
  end

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
  # Starts the connection of `adapter` (`adapter.connect`, owners and admins): `issue`,
  # given the adapter as it is now, makes what the person is sent to the adapter with,
  # `{:ok, pass}`, which the entry never holds. `{:ok, pass}`, `{:error, :forbidden}`,
  # `{:error, :not_found}`, or the `{:error, reason}` of `issue`, with no entry.
  @spec connect(Scope.t(), Node.t(), (Node.t() -> {:ok, term} | {:error, term})) ::
          {:ok, term} | {:error, term}
  def connect(%Scope{} = scope, %Node{} = adapter, issue) when is_function(issue, 1) do
    mutate(scope, :"adapter.connect", adapter, fn current ->
      with {:ok, pass} <- issue.(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"adapter.connect", current, %{
               details: Map.take(current, [:name, :public_id])
             }) do
        {:ok, pass}
      end
    end)
  end

  ## How often an adapter checks the source

  # The intervals a person may choose, in seconds, before the adapter's minimum is applied:
  # an adapter that sends the source's changes as they happen checks only for what it
  # missed, from a quarter of an hour to a day; one that learns of changes only by checking,
  # from a minute to an hour.
  @sync_choices %{true: [900, 3600, 21_600, 86_400], false: [60, 300, 900, 3600]}

  @doc false
  # How `adapter` checks the source: what it declared (`sends_changes`, `default`,
  # `minimum`, each nil until it first declares), the interval a person set (`interval`,
  # nil for the adapter's default), and the intervals a person may choose (`choices`):
  # those of its kind of checking at or above its minimum, none before it declares.
  @spec sync(Node.t()) :: %{
          sends_changes: boolean | nil,
          interval: pos_integer | nil,
          default: pos_integer | nil,
          minimum: pos_integer | nil,
          choices: [pos_integer]
        }
  def sync(%Node{kind: :adapter} = adapter) do
    %{
      sends_changes: adapter.sync_sends_changes,
      interval: adapter.sync_interval,
      default: adapter.sync_default_interval,
      minimum: adapter.sync_minimum_interval,
      choices: sync_choices(adapter)
    }
  end

  defp sync_choices(%Node{sync_sends_changes: sends_changes, sync_minimum_interval: minimum})
       when is_boolean(sends_changes) do
    choices = Map.fetch!(@sync_choices, sends_changes)
    if is_integer(minimum), do: Enum.filter(choices, &(&1 >= minimum)), else: choices
  end

  defp sync_choices(%Node{}), do: []

  @doc false
  # The changeset of the interval a person sets for `adapter`, from `attrs`'s `interval`:
  # one of `sync/1`'s `choices`, or empty for the adapter's default.
  @spec change_sync(Node.t(), map) :: Ecto.Changeset.t()
  def change_sync(%Node{kind: :adapter} = adapter, attrs \\ %{}) do
    Node.sync_interval_changeset(adapter, sync_attrs(attrs), sync_choices(adapter))
  end

  @doc false
  # Sets the interval of `adapter`'s check (`adapter.edit`, owners and admins), from
  # `attrs`'s `interval`, in seconds, one of `sync/1`'s `choices`, or `""` for the
  # adapter's default. A change appends `{kind: "sync", interval}` to the adapter's feed
  # (nil for the default) and leaves its entry, in one transaction; the same interval
  # changes nothing. `{:ok, adapter}`, `{:error, changeset}`, `{:error, :forbidden}`, or
  # `{:error, :not_found}`.
  @spec update_sync(Scope.t(), Node.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def update_sync(%Scope{} = scope, %Node{} = adapter, attrs) do
    mutate(scope, :"adapter.edit", adapter, fn current ->
      changeset =
        Node.sync_interval_changeset(current, sync_attrs(attrs), sync_choices(current))

      with {:ok, updated} <- Repo.update(changeset) do
        case Audit.changed(current, updated, [:sync_interval]) do
          nil ->
            {:ok, updated}

          changes ->
            with {:ok, _entry} <- Audit.record(Repo, scope, :"adapter.edit", updated, changes),
                 {:ok, _seq} <-
                   Feed.append(updated, %{kind: "sync", interval: updated.sync_interval}) do
              {:ok, updated}
            end
        end
      end
    end)
  end

  # The interval as a page sends it: `interval`, or the changeset's field, `sync_interval`.
  defp sync_attrs(attrs) do
    case Map.new(attrs, fn {key, value} -> {to_string(key), value} end) do
      %{"interval" => interval} -> %{"sync_interval" => interval}
      %{"sync_interval" => interval} -> %{"sync_interval" => interval}
      _other -> %{}
    end
  end

  ## What an adapter declares

  @doc false
  # Stores what the adapter of `scope`, an adapter's key (`Apiary.Accounts.Scope.for_access_key/1`),
  # declared as it started (`Apiary.Adapters.Wire.declaration/1`): its connect address and
  # how it checks the source (`adapter.declare`). A declaration that changes something
  # leaves an entry whose actor is the key; one that changes nothing leaves none. The
  # adapter's first declaration appends `{kind: "sync", interval: nil}` to its feed, its
  # default; so does a later one that leaves the interval a person set out of `sync/1`'s
  # `choices` (above its minimum, or of the other kind of checking), which goes back to
  # the default. One transaction, with the adapter's row locked. `{:ok,
  # adapter}`, `{:error, changeset}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec declare(Scope.t(), map) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def declare(%Scope{} = scope, %{} = declaration) do
    Repo.transact(fn ->
      with {:ok, %Node{id: id}} <- for_key(scope, :"adapter.declare"),
           %Node{} = current <-
             Repo.one(from(n in Node, where: n.id == ^id, lock: "FOR UPDATE")) ||
               {:error, :not_found},
           {:ok, declared} <- current |> declaration_changeset(declaration) |> Repo.update(),
           :ok <- record_declaration(scope, current, declared),
           :ok <- tell_default(current, declared) do
        {:ok, declared}
      end
    end)
  end

  defp declaration_changeset(current, declaration) do
    changeset =
      Node.declaration_changeset(current, %{
        connect_url: declaration.connect_url,
        sync_default_interval: declaration.default_interval,
        sync_minimum_interval: declaration.minimum_interval,
        sync_sends_changes: declaration.sends_changes
      })

    # The interval a person set stays while it is one of the choices the declaration
    # leaves, and goes back to the default when it is not.
    choices = sync_choices(Ecto.Changeset.apply_changes(changeset))

    case current.sync_interval do
      interval when is_integer(interval) ->
        if interval in choices,
          do: changeset,
          else: Ecto.Changeset.put_change(changeset, :sync_interval, nil)

      nil ->
        changeset
    end
  end

  @declared [
    :connect_url,
    :sync_default_interval,
    :sync_minimum_interval,
    :sync_sends_changes,
    :sync_interval
  ]

  defp record_declaration(scope, current, declared) do
    case Audit.changed(current, declared, @declared) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <- Audit.record(Repo, scope, :"adapter.declare", declared, changes),
             do: :ok
    end
  end

  # The adapter's interval is its default from its first declaration on, and again when a
  # person's interval is no longer a choice: the feed says so.
  defp tell_default(current, declared) do
    first? = is_nil(current.sync_sends_changes)
    cleared? = is_integer(current.sync_interval) and is_nil(declared.sync_interval)

    if first? or cleared? do
      with {:ok, _seq} <- Feed.append(declared, %{kind: "sync", interval: nil}), do: :ok
    else
      :ok
    end
  end

  @doc false
  # Deletes `adapter` (`adapter.delete`, owners and admins): it leaves every page, its name
  # is free again, and its row stays for what names it until its organisation is purged.
  # In the same transaction its keys in use are revoked and its outstanding codes
  # cancelled (`Apiary.AccessKeys.revoke_node_keys/3`, each key with its entry of
  # `access_key.revoke`), and every pool it served is served by none, which the entry
  # records (`unserved_pool_ids`, their public ids). The organisation's lock comes first
  # (`Apiary.Gateways.lock/1`), as a change of a pool takes it, then the adapter's row.
  # `{:ok, adapter}`, `{:error, :forbidden}`, or `{:error, :not_found}`.
  @spec delete_adapter(Scope.t(), Node.t()) ::
          {:ok, Node.t()} | {:error, Ecto.Changeset.t() | Access.reason()}
  def delete_adapter(
        %Scope{user: user, organisation: %Organisation{id: organisation_id}} = scope,
        %Node{} = adapter
      ) do
    Repo.transact(fn ->
      with :ok <- Gateways.lock({:organisation, organisation_id}) do
        mutate(scope, :"adapter.delete", adapter, fn current ->
          now = DateTime.utc_now()

          with {:ok, key_ids} <- AccessKeys.revoke_node_keys(scope, current, :node_deleted),
               pool_ids = unserve_pools(current, now),
               {:ok, deleted} <-
                 current
                 |> Ecto.Changeset.change(deleted_at: now, deleted_by_id: user.id)
                 |> Repo.update(),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"adapter.delete", deleted, %{
                   before: %{deleted_at: nil},
                   after: %{deleted_at: deleted.deleted_at},
                   details:
                     deleted
                     |> Map.take([:name, :kind, :public_id])
                     |> Map.put(:revoked_key_ids, key_ids)
                     |> Map.put(:unserved_pool_ids, pool_ids)
                 }) do
            {:ok, deleted}
          end
        end)
      end
    end)
  end

  # Every pool `adapter` serves, deleted ones too, is served by none from now on: the
  # public ids of those in use, in order.
  defp unserve_pools(%Node{id: id, organisation_id: organisation_id}, now) do
    {_count, pools} =
      Repo.update_all(
        from(n in Node,
          where: n.organisation_id == ^organisation_id and n.served_by_id == ^id,
          select: {n.public_id, n.deleted_at}
        ),
        set: [served_by_id: nil, updated_at: now]
      )

    for({public_id, nil} <- pools, do: public_id) |> Enum.sort()
  end

  # Asks `action` of the person as they are now, then hands `fun` the adapter as it is now,
  # in use and the scope's organisation's, locked for the rest of the transaction.
  defp mutate(scope, action, %Node{id: id} = adapter, fun) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, action, adapter),
           %Node{} = current <-
             scope |> live_query() |> where([n], n.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
        fun.(current)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  ## At the server contract

  @doc false
  # The adapter an access key's scope stands for, once `action` is allowed to it
  # (`Apiary.Access.authorize/3`, asked of the adapter): `{:ok, adapter}`, or `{:error,
  # :not_found}` for a scope of no key, a key whose node is no adapter in use of the key's
  # organisation, or an action the key may not take there, `{:error, :forbidden}` for one
  # its role does not hold.
  @spec for_key(Scope.t(), Access.action()) :: {:ok, Node.t()} | {:error, Access.reason()}
  def for_key(
        %Scope{access_key: %AccessKey{node_id: node_id, organisation_id: organisation_id}} =
          scope,
        action
      )
      when is_binary(node_id) and is_binary(organisation_id) do
    adapter =
      Repo.one(
        from n in Node,
          where: n.id == ^node_id and n.organisation_id == ^organisation_id,
          where: n.kind == :adapter and is_nil(n.workspace_id) and is_nil(n.deleted_at)
      )

    with %Node{} <- adapter || {:error, :not_found},
         :ok <- Access.authorize(scope, action, adapter) do
      {:ok, adapter}
    end
  end

  def for_key(%Scope{}, _action), do: {:error, :not_found}
end
