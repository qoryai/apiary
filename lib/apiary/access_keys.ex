defmodule Apiary.AccessKeys do
  @moduledoc """
  Access keys: a hive's credentials for the server contract.

  A key has a public id and one or two secrets, encrypted at rest. The secret is
  returned exactly once, from `create_access_key/2` and `rotate_access_key/2`,
  and is never read back through this module except for verification.
  """

  import Ecto.Query, warn: false

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
                 secret_secondary: fn -> previous end,
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

    case Repo.one(query) do
      %AccessKey{} = access_key -> {:ok, access_key}
      nil -> {:error, :unauthorized}
    end
  end

  @doc "The active key behind a key id, secrets decrypted, for request verification."
  def fetch_for_verification(key_id) when is_binary(key_id) do
    case Repo.one(from k in AccessKey, where: k.key_id == ^key_id and is_nil(k.revoked_at)) do
      %AccessKey{} = access_key -> {:ok, access_key}
      nil -> :error
    end
  end

  def fetch_for_verification(_key_id), do: :error

  @doc "Records a use: `last_used_at` now, plus `last_runner_version` and `last_contract_version` from `attrs`."
  def touch(%AccessKey{} = access_key, attrs) do
    access_key |> AccessKey.touch_changeset(attrs) |> Repo.update()
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
