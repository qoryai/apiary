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
  alias Apiary.Organisations.{Hive, Membership, Organisation}

  defguardp key_in_scope(scope, access_key)
            when access_key.organisation_id == scope.organisation.id and
                   access_key.hive_id == scope.hive.id

  @doc "The hive's keys: active first, then revoked; newest first within each."
  def list_access_keys(%Scope{
        organisation: %Organisation{id: organisation_id},
        hive: %Hive{id: hive_id}
      }) do
    Repo.all(
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and k.hive_id == ^hive_id,
        order_by: [asc: not is_nil(k.revoked_at), desc: k.inserted_at, desc: k.id]
    )
  end

  def get_access_key!(
        %Scope{organisation: %Organisation{id: organisation_id}, hive: %Hive{id: hive_id}},
        id
      ) do
    Repo.get_by!(AccessKey, id: id, organisation_id: organisation_id, hive_id: hive_id)
  end

  def change_access_key(%AccessKey{} = access_key, attrs \\ %{}) do
    AccessKey.changeset(access_key, attrs)
  end

  @doc """
  Creates a key for the scope's hive. Any member. Returns the key and its secret,
  the only time the secret is available in clear.
  """
  def create_access_key(
        %Scope{
          user: user,
          organisation: %Organisation{id: organisation_id},
          hive: %Hive{id: hive_id},
          membership: %Membership{}
        },
        attrs
      ) do
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
      {:ok, %{access_key | secret_primary: secret}, secret}
    end
  end

  @doc """
  Rotates the key: a new primary secret, the old primary kept as the secondary
  so a node still on it keeps verifying; a previous secondary is dropped.
  """
  def rotate_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    if access_key.revoked_at do
      {:error, :revoked}
    else
      secret = AccessKey.generate_secret()
      previous = access_key.secret_primary

      with {:ok, access_key} <-
             access_key
             |> Ecto.Changeset.change(
               secret_primary: fn -> secret end,
               secret_secondary: fn -> previous end,
               rotated_at: DateTime.utc_now()
             )
             |> Repo.update() do
        {:ok, %{access_key | secret_primary: secret, secret_secondary: previous}, secret}
      end
    end
  end

  @doc "Drops the secondary secret: the rotation is complete."
  def retire_previous_secret(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    access_key |> Ecto.Changeset.change(secret_secondary: nil) |> Repo.update()
  end

  @doc "Revokes the key: verification fails from now on."
  def revoke_access_key(%Scope{} = scope, %AccessKey{} = access_key)
      when key_in_scope(scope, access_key) do
    access_key
    |> Ecto.Changeset.change(revoked_at: access_key.revoked_at || DateTime.utc_now())
    |> Repo.update()
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
