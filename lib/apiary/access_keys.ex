defmodule Apiary.AccessKeys do
  @moduledoc """
  Access keys: a hive's credentials for the server contract.

  A key has a public id and one or two secrets, encrypted at rest. The secret is
  returned exactly once, from `create_access_key/2` and `rotate_access_key/2`,
  and is never read back through this module except for verification.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.Repo
  alias Apiary.Accounts.Scope
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Organisations
  alias Apiary.Organisations.{Hive, Organisation}

  defguardp key_in_scope(scope, access_key)
            when access_key.organisation_id == scope.organisation.id and
                   access_key.hive_id == scope.hive.id

  @doc """
  The hive's keys: active first, then revoked; newest first within each. The
  secret columns are not loaded; `rotating` says whether a previous secret exists.
  """
  def list_access_keys(%Scope{
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id}
      }) do
    Repo.all(
      from k in without_secrets_query(),
        where: k.organisation_id == ^organisation_id and k.hive_id == ^hive_id,
        order_by: [asc: not is_nil(k.revoked_at), desc: k.inserted_at, desc: k.id]
    )
  end

  @doc "One key of the scope's hive, without its secrets (see `list_access_keys/1`)."
  def get_access_key!(
        %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
        id
      ) do
    Repo.one!(
      from k in without_secrets_query(),
        where: k.id == ^id and k.organisation_id == ^organisation_id and k.hive_id == ^hive_id
    )
  end

  # Decrypted secrets have no business in a LiveView's state: the web layer gets
  # rows selected without the secret columns.
  defp without_secrets_query do
    from k in AccessKey,
      select: struct(k, ^AccessKey.public_fields()),
      select_merge: %{rotating: not is_nil(k.secret_secondary)}
  end

  def change_access_key(%AccessKey{} = access_key, attrs \\ %{}) do
    AccessKey.changeset(access_key, attrs)
  end

  @doc """
  Creates a key for the scope's hive. Any member, read again from the database:
  a caller whose membership is gone gets `{:error, :unauthorized}`. Returns the
  key (without secrets) and its secret, the only time the secret is available in
  clear.
  """
  def create_access_key(
        %Scope{
          user: user,
          organisation: %Organisation{id: organisation_id},
          hive: %Hive{id: hive_id}
        } = scope,
        attrs
      ) do
    with {:ok, _membership} <- Organisations.fetch_membership(scope) do
      secret = AccessKey.generate_secret()

      changeset =
        %AccessKey{
          organisation_id: organisation_id,
          hive_id: hive_id,
          created_by_id: user.id,
          key_id: AccessKey.generate_key_id(),
          # A closure, so the query log sees a function and never the secret
          # (Ecto logs the cast parameters; Cloak unwraps the closure on dump).
          secret_primary: fn -> secret end
        }
        |> AccessKey.changeset(attrs)

      with {:ok, access_key} <- Repo.insert(changeset) do
        {:ok, AccessKey.without_secrets(%{access_key | secret_primary: nil}), secret}
      end
    end
  end

  @doc """
  Rotates the key: a new primary secret, the old primary kept as the secondary
  so a node still on it keeps verifying; a previous secondary is dropped.

  The row is read again and locked, so the secret kept as the secondary is the
  one in the database now, whatever the struct passed in remembers.
  """
  def rotate_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, access_key, fn
      %AccessKey{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %AccessKey{secret_primary: previous} = current ->
        secret = AccessKey.generate_secret()

        with {:ok, updated} <-
               current
               |> Ecto.Changeset.change(
                 secret_primary: fn -> secret end,
                 secret_secondary: previous && fn -> previous end,
                 rotated_at: DateTime.utc_now()
               )
               |> Repo.update() do
          {:ok, {updated, secret}}
        end
    end)
  end

  @doc "Drops the secondary secret: the rotation is complete."
  def retire_previous_secret(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, access_key, fn current ->
      current |> Ecto.Changeset.change(secret_secondary: nil) |> Repo.update()
    end)
  end

  @doc "Revokes the key: verification fails from now on."
  def revoke_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    mutate(scope, access_key, fn current ->
      current
      |> Ecto.Changeset.change(revoked_at: current.revoked_at || DateTime.utc_now())
      |> Repo.update()
    end)
  end

  # Authorizes on the caller's membership as it is now, then hands `fun` the
  # key as it is now, locked for the rest of the transaction. The result leaves
  # without secrets.
  defp mutate(%Scope{} = scope, %AccessKey{id: id}, fun) do
    fn ->
      with {:ok, _membership} <- Organisations.fetch_membership(scope),
           {:ok, current} <- lock_access_key(scope, id) do
        fun.(current)
      end
    end
    |> Repo.transact()
    |> case do
      {:ok, %AccessKey{} = access_key} ->
        {:ok, AccessKey.without_secrets(access_key)}

      {:ok, {%AccessKey{} = access_key, secret}} ->
        {:ok, AccessKey.without_secrets(access_key), secret}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_access_key(%Scope{organisation: organisation, hive: hive}, id) do
    query =
      from k in AccessKey,
        where: k.id == ^id and k.organisation_id == ^organisation.id and k.hive_id == ^hive.id,
        lock: "FOR UPDATE"

    # A secret that cannot be decrypted with the key the instance holds (see
    # `readable?/1`) is dropped here, never carried over: a rotation issues a new secret
    # in its place, and a revocation still revokes.
    case Repo.one(query) do
      %AccessKey{} = access_key -> {:ok, drop_unreadable(access_key)}
      nil -> {:error, :unauthorized}
    end
  end

  defp drop_unreadable(%AccessKey{} = access_key) do
    %{
      access_key
      | secret_primary: if(is_binary(access_key.secret_primary), do: access_key.secret_primary),
        secret_secondary:
          if(is_binary(access_key.secret_secondary), do: access_key.secret_secondary)
    }
  end

  @doc """
  The active key behind a key id, secrets decrypted, for request verification: `:error`
  for a key id the hive does not hold or has revoked, and `{:error, :unreadable}`, with a
  line in the log, when the secrets cannot be decrypted with the key the instance holds
  (`CLOAK_KEY` is not the one they were encrypted with).
  """
  def fetch_for_verification(key_id) when is_binary(key_id) do
    case Repo.one(from k in AccessKey, where: k.key_id == ^key_id and is_nil(k.revoked_at)) do
      %AccessKey{} = access_key ->
        if readable?(access_key), do: {:ok, access_key}, else: unreadable(key_id)

      nil ->
        :error
    end
  rescue
    ArgumentError -> unreadable(key_id)
  end

  # A secret encrypted under another key does not raise when it is loaded: the cipher's
  # failure comes through as the atom `:error` in the field. A secret is a binary or nil.
  defp readable?(%AccessKey{secret_primary: primary, secret_secondary: secondary}) do
    (is_binary(primary) or is_nil(primary)) and (is_binary(secondary) or is_nil(secondary))
  end

  # The key id is public; nothing of the row is in the line.
  defp unreadable(key_id) do
    Logger.error(
      "access key secret cannot be decrypted key_id=#{key_id}: " <>
        "CLOAK_KEY is not the key the secret was encrypted with"
    )

    {:error, :unreadable}
  end

  def fetch_for_verification(_key_id), do: :error

  @doc "Records a use: `last_used_at` now, plus `last_runner_version` and `last_contract_version` from `attrs`."
  def touch(%AccessKey{} = access_key, attrs) do
    access_key |> AccessKey.touch_changeset(attrs) |> Repo.update()
  end

  @doc """
  Records a delivery to the events endpoint: `last_used_at`, the runner and
  contract versions when the request named them (a request that named none
  leaves what is recorded), and `last_heartbeat_at` when the delivery held a new
  heartbeat, never moving it backwards. One `UPDATE`, without reading the row.
  """
  def touch_delivery(%AccessKey{id: id}, attrs) do
    set =
      [
        last_used_at: attrs[:last_used_at] || DateTime.utc_now(),
        last_runner_version: attrs[:last_runner_version],
        last_contract_version: attrs[:last_contract_version]
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)

    query = from(k in AccessKey, where: k.id == ^id)

    query =
      case attrs[:last_heartbeat_at] do
        %DateTime{} = at ->
          # GREATEST ignores a null: the first heartbeat sets the column.
          from k in query,
            update: [
              set: [
                last_heartbeat_at:
                  fragment("GREATEST(?, ?)", k.last_heartbeat_at, type(^at, :utc_datetime_usec))
              ]
            ]

        _ ->
          query
      end

    Repo.update_all(query, set: set)
    :ok
  end

  @doc "The `server` block of the runner file for this key."
  def server_block(%AccessKey{key_id: key_id}, secret, base_url) when is_binary(secret) do
    """
    apiVersion: qory.dev/v1alpha1
    server:
      url: #{base_url}
      access_key: #{key_id}
      secret: #{secret}
    """
  end
end
