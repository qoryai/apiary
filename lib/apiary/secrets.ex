defmodule Apiary.Secrets do
  @moduledoc """
  A workspace's stored secrets: values a run is given, kept by name, encrypted at rest,
  and never shown again once saved.

  A secret (`Apiary.Secrets.Secret`) has a name, unique in the workspace whatever its
  case, a public id (`sec_…`), a note on what it is used for, and either one value or
  several values, each with a **value id** the person names: `GITHUB_APP_KEY` with the
  values `main-app` and `bot-app`. A secret has at least one value. Adding a second value
  to a secret whose one value has no value id names that value too.

  ## Write-only

  No function of this module returns a value, but `reveal_for_sealing/3`, which the
  secrets endpoint calls to seal a value to a runner, and only that. A listing loads the
  values without their ciphertext. Nothing logs a value, and an audit entry names a
  secret and a value id, never a value.

  ## At rest

  Each value is encrypted with AES-256-GCM under its workspace's **data key**, with a
  fresh nonce, and with associated data that binds it to its workspace, its secret's
  public id and its value id (`Apiary.Secrets.Cipher`). The data key, 32 random bytes,
  is kept only wrapped under the instance's values key, which is derived from
  `APIARY_ENCRYPTION_SECRET` (`Apiary.KeyDerivation`), with the values key's id beside
  it (`Apiary.Secrets.DataKey`). Renaming a value id encrypts the value again under the
  new id. Losing `APIARY_ENCRYPTION_SECRET` loses every stored value.

  ## Who, and the trail

  Reading the secrets, their names, notes and value ids, is `secret.read`, every member;
  every change is `secret.write`, owners and admins, asked of the workspace for a new
  secret and of the secret for a change to it. Linking a secret to what uses it is
  `secret.use`, which the piece that links asks. Every change leaves one `secret.write`
  entry in the audit trail, in its transaction, the secret its subject, with
  `details.change` saying what: `created`, `updated`, `value_set`, `value_added`,
  `value_renamed`, `value_deleted` or `deleted`, and the names and value ids it touched.

  A write locks the scope's organisation `FOR SHARE`, then the workspace, then reads the
  membership again (`Apiary.Access.reload/2`), the security policy's lock order
  (docs/access.md), and a change to a secret locks the secret's row: two writes to one
  secret, or a write and a deletion, take turns.

  A secret in use is not deleted, nor a value in use: `Apiary.Secrets.Usage` answers.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, KeyDerivation, LogMetadata, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Secrets.{Cipher, DataKey, Secret, Usage, Value}

  @max_values 32

  @typedoc """
  Why a change is refused: the reasons of `Apiary.Access`, a changeset with what is wrong
  with the input, the uses of a secret or a value in use, the last value of a secret,
  which goes only with the secret, a secret that already has `max_values/0` values, or
  a data key the instance cannot unwrap, because `APIARY_ENCRYPTION_SECRET` is not the
  one it was wrapped under.
  """
  @type refusal ::
          Access.reason()
          | Ecto.Changeset.t()
          | {:in_use, [Usage.use()]}
          | :last_value
          | :too_many_values
          | :key_unavailable

  @doc "The most values a secret has."
  @spec max_values() :: pos_integer
  def max_values, do: @max_values

  ## Reading

  @doc """
  list_secrets/1 is the scope's workspace's secrets, by name whatever its case, each with
  its values, their value ids and when they were set, never their ciphertext:
  `{:ok, secrets}`, for a reader who may `secret.read`; else `{:error, reason}`,
  `:not_found` where the `security` feature is off.
  """
  @spec list_secrets(Scope.t()) :: {:ok, [Secret.t()]} | {:error, Access.reason()}
  def list_secrets(%Scope{} = scope) do
    with :ok <- may_read(scope) do
      {:ok,
       Repo.all(
         from s in secrets(scope),
           order_by: [asc: fragment("lower(?)", s.name), asc: s.id],
           preload: [values: ^values_query()]
       )}
    end
  end

  @doc """
  get_secret/2 is the scope's workspace's secret with the public id `public_id`, with its
  values as `list_secrets/1` loads them: `{:ok, secret}`, for a reader who may
  `secret.read`; else `{:error, reason}`, `:not_found` for a secret the workspace does
  not have.
  """
  @spec get_secret(Scope.t(), term) :: {:ok, Secret.t()} | {:error, Access.reason()}
  def get_secret(%Scope{} = scope, public_id) do
    with :ok <- may_read(scope),
         true <- PublicId.valid?("sec", public_id),
         %Secret{} = secret <-
           Repo.one(
             from s in secrets(scope),
               where: s.public_id == ^public_id,
               preload: [values: ^values_query()]
           ) do
      {:ok, secret}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp may_read(%Scope{workspace: %Workspace{} = workspace} = scope),
    do: Access.authorize(scope, :"secret.read", workspace)

  defp may_read(_scope), do: {:error, :not_found}

  @doc """
  change_secret/2 is the changeset of a secret's name and note, for a form, without any
  `value` among its params.
  """
  @spec change_secret(Secret.t(), map) :: Ecto.Changeset.t()
  def change_secret(%Secret{} = secret, attrs \\ %{}),
    do: secret |> Secret.changeset(attrs) |> scrub()

  defp secrets(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from s in Secret,
      where: s.organisation_id == ^organisation_id and s.workspace_id == ^workspace_id
  end

  defp values_query do
    from v in Value, select: struct(v, ^Value.public_fields()), order_by: [asc: v.value_id]
  end

  ## Writing

  @doc """
  create_secret/2 stores a new secret of the scope's workspace (`secret.write`), with its
  first value: `attrs` has `name`, `note` (optional), `value`, and `value_id`, optional,
  for a secret that will have several. `{:ok, secret}`, its values loaded without their
  ciphertext; or `{:error, refusal}`, a changeset whose errors are on `name`, `note`,
  `value` or `value_id`.
  """
  @spec create_secret(Scope.t(), map) :: {:ok, Secret.t()} | {:error, refusal}
  def create_secret(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    write(scope, fn scope, workspace ->
      secret_changeset =
        %Secret{
          organisation_id: workspace.organisation_id,
          workspace_id: workspace.id,
          public_id: PublicId.generate("sec"),
          created_by_id: scope.user.id,
          updated_by_id: scope.user.id
        }
        |> Secret.changeset(attrs)

      value_changeset = Value.changeset(%Value{}, attrs)

      with :ok <- Access.check(scope, :"secret.write", workspace),
           :ok <- valid(secret_changeset, value_changeset),
           {:ok, secret} <- Repo.insert(secret_changeset),
           {:ok, value} <- insert_value(scope, workspace, secret, value_changeset),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", secret, %{
               after: %{name: secret.name, note: secret.note, value_ids: [value.value_id]},
               details: %{change: "created", secret_id: secret.public_id, name: secret.name}
             }) do
        {:ok, secret}
      end
    end)
    |> reload()
  end

  @doc """
  update_secret/3 changes a secret's name or note (`secret.write`): `{:ok, secret}`, or
  `{:error, refusal}`. A change that changes nothing leaves no entry.
  """
  @spec update_secret(Scope.t(), Secret.t(), map) :: {:ok, Secret.t()} | {:error, refusal}
  def update_secret(%Scope{} = scope, %Secret{} = secret, attrs) do
    write_secret(scope, secret, fn scope, current ->
      changeset =
        current
        |> Secret.changeset(attrs)
        |> Ecto.Changeset.put_change(:updated_by_id, scope.user.id)

      case Audit.changed(current, Ecto.Changeset.apply_changes(changeset), [:name, :note]) do
        nil ->
          if changeset.valid?, do: {:ok, current}, else: {:error, changeset}

        changed ->
          with {:ok, updated} <- Repo.update(changeset),
               {:ok, _entry} <-
                 Audit.record(
                   Repo,
                   scope,
                   :"secret.write",
                   updated,
                   Map.put(changed, :details, %{
                     change: "updated",
                     secret_id: updated.public_id,
                     name: updated.name
                   })
                 ) do
            {:ok, updated}
          end
      end
    end)
    |> reload()
  end

  @doc """
  set_value/4 replaces a value of a secret (`secret.write`): the one named `value_id`, or
  the secret's one value without a value id when `value_id` is nil. `{:ok, secret}`, or
  `{:error, refusal}`: `:not_found` for a value id the secret does not have, a changeset
  whose error is on `value`.
  """
  @spec set_value(Scope.t(), Secret.t(), String.t() | nil, String.t()) ::
          {:ok, Secret.t()} | {:error, refusal}
  def set_value(%Scope{} = scope, %Secret{} = secret, value_id, value) do
    write_secret(scope, secret, fn scope, current ->
      with {:ok, row} <- fetch_value(current, value_id),
           changeset = Value.changeset(row, %{"value" => value}),
           :ok <- valid(changeset),
           {:ok, _row} <-
             encrypt_and_write(scope, workspace_of(current), current, changeset, :update),
           {:ok, current} <- touch(scope, current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", current, %{
               details: %{
                 change: "value_set",
                 secret_id: current.public_id,
                 name: current.name,
                 value_id: value_id
               }
             }) do
        {:ok, current}
      end
    end)
    |> reload()
  end

  @doc """
  add_value/3 adds a value with its value id to a secret (`secret.write`): `attrs` has
  `value_id` and `value`, and, when the secret's one value has no value id yet,
  `first_value_id`, the value id that value takes. `{:ok, secret}`, or
  `{:error, refusal}`: a changeset whose errors are on `value`, `value_id` or
  `first_value_id`; `:too_many_values` past `max_values/0`.
  """
  @spec add_value(Scope.t(), Secret.t(), map) :: {:ok, Secret.t()} | {:error, refusal}
  def add_value(%Scope{} = scope, %Secret{} = secret, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    write_secret(scope, secret, fn scope, current ->
      workspace = workspace_of(current)
      changeset = Value.changeset(%Value{}, attrs, value_id: :required)
      unnamed = Enum.find(current.values, &is_nil(&1.value_id))

      with :ok <- room_for_another(current),
           {:ok, first} <- first_value_id(unnamed, attrs, changeset),
           :ok <- valid(changeset),
           :ok <- rename_first(scope, workspace, current, unnamed, first),
           {:ok, _row} <- insert_value(scope, workspace, current, changeset),
           {:ok, current} <- touch(scope, current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", current, %{
               details:
                 %{
                   change: "value_added",
                   secret_id: current.public_id,
                   name: current.name,
                   value_id: Ecto.Changeset.get_field(changeset, :value_id)
                 }
                 |> put_if(first, :first_value_id)
             }) do
        {:ok, current}
      end
    end)
    |> reload()
  end

  defp room_for_another(%Secret{values: values}) when length(values) < @max_values, do: :ok
  defp room_for_another(%Secret{}), do: {:error, :too_many_values}

  # The value id the secret's one value takes when a second is added: none to take when
  # every value has one; required, and a value id, when one has none.
  defp first_value_id(nil, _attrs, _changeset), do: {:ok, nil}

  defp first_value_id(%Value{} = unnamed, attrs, changeset) do
    first =
      unnamed
      |> Ecto.Changeset.cast(%{"value_id" => attrs["first_value_id"]}, [:value_id])
      |> Value.value_id_changeset(:required)

    cond do
      not first.valid? ->
        {:error, copy_errors(changeset, first, :value_id, :first_value_id)}

      Ecto.Changeset.get_field(first, :value_id) == Ecto.Changeset.get_field(changeset, :value_id) ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :value_id,
           dgettext_noop("errors", "is the value ID the first value takes")
         )}

      true ->
        {:ok, Ecto.Changeset.get_field(first, :value_id)}
    end
  end

  defp rename_first(_scope, _workspace, _secret, nil, nil), do: :ok

  defp rename_first(scope, workspace, secret, %Value{} = unnamed, value_id) do
    case reencrypt(scope, workspace, secret, unnamed, value_id) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  rename_value/4 gives a secret's value another value id (`secret.write`), and encrypts it
  again under the new one, which its associated data binds. `{:ok, secret}`, or
  `{:error, refusal}`: `:not_found` for a value id the secret does not have, a changeset
  whose error is on `value_id`.
  """
  @spec rename_value(Scope.t(), Secret.t(), String.t() | nil, String.t()) ::
          {:ok, Secret.t()} | {:error, refusal}
  def rename_value(%Scope{} = scope, %Secret{} = secret, value_id, new_value_id) do
    # The value id as it will be stored: what the no-op compare, the associated data and
    # the audit entry all take.
    new_value_id = Value.normalise_value_id(new_value_id)

    write_secret(scope, secret, fn scope, current ->
      case fetch_value(current, value_id) do
        {:ok, %Value{value_id: ^new_value_id}} ->
          {:ok, current}

        {:ok, row} ->
          with {:ok, _row} <- reencrypt(scope, workspace_of(current), current, row, new_value_id),
               {:ok, current} <- touch(scope, current),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"secret.write", current, %{
                   before: %{value_id: value_id},
                   after: %{value_id: new_value_id},
                   details: %{
                     change: "value_renamed",
                     secret_id: current.public_id,
                     name: current.name
                   }
                 }) do
            {:ok, current}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> reload()
  end

  @doc """
  delete_value/3 deletes a secret's value (`secret.write`). `{:ok, secret}`, or
  `{:error, refusal}`: `:not_found` for a value id the secret does not have,
  `:last_value` for its only value, which goes only with the secret, `{:in_use, uses}`
  for a value something uses.
  """
  @spec delete_value(Scope.t(), Secret.t(), String.t() | nil) ::
          {:ok, Secret.t()} | {:error, refusal}
  def delete_value(%Scope{} = scope, %Secret{} = secret, value_id) do
    write_secret(scope, secret, fn scope, current ->
      with {:ok, row} <- fetch_value(current, value_id),
           :ok <- not_last(current),
           :ok <- not_in_use(Enum.filter(Usage.uses(Repo, current), &(&1.value_id == value_id))),
           {:ok, _row} <- Repo.delete(row),
           {:ok, current} <- touch(scope, current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", current, %{
               before: %{value_id: value_id},
               details: %{
                 change: "value_deleted",
                 secret_id: current.public_id,
                 name: current.name
               }
             }) do
        {:ok, current}
      end
    end)
    |> reload()
  end

  defp not_last(%Secret{values: [_one]}), do: {:error, :last_value}
  defp not_last(%Secret{}), do: :ok

  @doc """
  delete_secret/2 deletes a secret with its values (`secret.write`). `{:ok, secret}`, the
  secret as it was, or `{:error, refusal}`: `{:in_use, uses}` for a secret something
  uses (`Apiary.Secrets.Usage`).
  """
  @spec delete_secret(Scope.t(), Secret.t()) :: {:ok, Secret.t()} | {:error, refusal}
  def delete_secret(%Scope{} = scope, %Secret{} = secret) do
    write_secret(scope, secret, fn scope, current ->
      with :ok <- not_in_use(Usage.uses(Repo, current)),
           {:ok, deleted} <- Repo.delete(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", deleted, %{
               before: %{name: deleted.name, value_ids: Enum.map(current.values, & &1.value_id)},
               details: %{change: "deleted", secret_id: deleted.public_id, name: deleted.name}
             }) do
        {:ok, %{deleted | values: current.values}}
      end
    end)
    |> reload_deleted()
  end

  defp reload_deleted({:error, %Ecto.Changeset{} = changeset}), do: {:error, scrub(changeset)}
  defp reload_deleted(other), do: other

  defp not_in_use([]), do: :ok
  defp not_in_use(uses), do: {:error, {:in_use, uses}}

  ## Sealing

  @doc """
  reveal_for_sealing/3 is the plaintext of a stored value, for the secrets endpoint to seal
  to a runner's key, and for nothing else: the one function that returns a value. The
  value is `workspace`'s secret with the public id `secret_id`, and its value with
  `value_id`, nil for a secret's one value without one.

  `{:ok, plaintext}`; `{:error, :not_found}` for a secret or a value the workspace does
  not have; `{:error, :unavailable}` when the value cannot be decrypted: the data key was
  wrapped under a key the instance does not hold, or the row is not the one that was
  written (moved to another secret, workspace or value id, or changed), with a line in
  the log that names the secret and the value id, never the value.

  It asks nothing of `Apiary.Access`, and is the one function of this module that does
  not: it is the server's own sealing path, called by the secrets endpoint once it has
  verified the runner's signed request and decided what that runner may receive, with no
  person's scope to ask about. The plaintext goes into the seal and nowhere else: not
  into a log, an assign, a process's state or an error.
  """
  @spec reveal_for_sealing(%Workspace{}, String.t(), String.t() | nil) ::
          {:ok, binary} | {:error, :not_found | :unavailable}
  def reveal_for_sealing(
        %Workspace{id: workspace_id, organisation_id: organisation_id},
        secret_id,
        value_id
      )
      when is_binary(secret_id) and (is_binary(value_id) or is_nil(value_id)) do
    query =
      from v in Value,
        join: s in Secret,
        on: s.id == v.secret_id,
        join: k in DataKey,
        on: k.id == v.data_key_id,
        where:
          s.organisation_id == ^organisation_id and s.workspace_id == ^workspace_id and
            s.public_id == ^secret_id,
        select: {v, k}

    query =
      if is_nil(value_id),
        do: where(query, [v], is_nil(v.value_id)),
        else: where(query, [v], v.value_id == ^value_id)

    case Repo.one(query) do
      {%Value{} = row, %DataKey{} = data_key} ->
        aad = Cipher.value_aad(workspace_id, secret_id, value_id)

        # An unwrap that fails has said so in the log already.
        with {:ok, key} <- unwrap(data_key),
             {:ok, plaintext} <- Cipher.decrypt(key, aad, row.nonce, row.ciphertext) do
          {:ok, plaintext}
        else
          {:error, :key_unavailable} -> {:error, :unavailable}
          :error -> unavailable(organisation_id, workspace_id, secret_id, value_id)
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp unavailable(organisation_id, workspace_id, secret_id, value_id) do
    Logger.error(
      "stored secret value cannot be decrypted secret_id=#{secret_id} " <>
        "value_id=#{value_id || "(none)"}: APIARY_ENCRYPTION_SECRET is not the key it was " <>
        "stored under, or the row was changed",
      LogMetadata.metadata(organisation_id, workspace_id)
    )

    {:error, :unavailable}
  end

  ## The write

  # A write to the scope's workspace: in one transaction, the organisation `FOR SHARE`,
  # the workspace `FOR NO KEY UPDATE`, the membership read again under its lock, then
  # `fun` with the scope as read and the workspace, which asks its question first.
  defp write(%Scope{workspace: %Workspace{id: workspace_id}} = scope, fun) do
    Repo.transact(fn ->
      :ok = Access.lock_places(scope)

      case Repo.one(
             from w in Workspace,
               where: w.id == ^workspace_id and w.organisation_id == ^scope.organisation.id,
               lock: "FOR NO KEY UPDATE"
           ) do
        %Workspace{} = workspace ->
          fun.(Access.reload(scope, lock: :share), workspace)

        nil ->
          {:error, :not_found}
      end
    end)
  end

  defp write(_scope, _fun), do: {:error, :not_found}

  # A write to one secret: the secret read again under `FOR UPDATE`, in the scope's
  # workspace, with its values, then asked of.
  defp write_secret(%Scope{} = scope, %Secret{id: id}, fun) do
    write(scope, fn scope, workspace ->
      with %Secret{} = current <-
             Repo.one(
               from s in secrets(scope),
                 where: s.id == ^id,
                 lock: "FOR UPDATE"
             ),
           current = Repo.preload(current, values: values_query()),
           :ok <- Access.check(scope, :"secret.write", current) do
        fun.(scope, %{current | workspace: workspace})
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp workspace_of(%Secret{workspace: %Workspace{} = workspace}), do: workspace

  defp touch(scope, %Secret{} = secret) do
    secret
    |> Ecto.Changeset.change(updated_by_id: scope.user.id)
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now())
    |> Repo.update()
  end

  # The secret as the caller sees it after a write: with its values, without their
  # ciphertext.
  defp reload({:ok, %Secret{id: id}}) do
    {:ok, Repo.one!(from s in Secret, where: s.id == ^id, preload: [values: ^values_query()])}
  end

  defp reload({:error, %Ecto.Changeset{} = changeset}), do: {:error, scrub(changeset)}
  defp reload(other), do: other

  # A changeset handed back to a caller keeps no plaintext: not in its params, under a
  # string or an atom key, nor in its changes.
  defp scrub(%Ecto.Changeset{} = changeset) do
    params = changeset.params && Map.drop(changeset.params, ["value", :value])
    %{changeset | params: params, changes: Map.delete(changeset.changes, :value)}
  end

  defp fetch_value(%Secret{values: values}, value_id) do
    case Enum.find(values, &(&1.value_id == value_id)) do
      %Value{} = value -> {:ok, Repo.reload!(value)}
      nil -> {:error, :not_found}
    end
  end

  defp valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  # A new secret's two changesets: the secret's, with the value's errors on it, so a form
  # shows every error at once.
  defp valid(%Ecto.Changeset{} = secret, %Ecto.Changeset{} = value) do
    if secret.valid? and value.valid? do
      :ok
    else
      errors = Enum.filter(value.errors, fn {field, _} -> field in [:value, :value_id] end)
      {:error, %{secret | errors: secret.errors ++ errors, valid?: false}}
    end
  end

  defp copy_errors(changeset, from, field, as) do
    Enum.reduce(Keyword.get_values(from.errors, field), %{changeset | valid?: false}, fn
      {message, opts}, acc -> Ecto.Changeset.add_error(acc, as, message, opts)
    end)
  end

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)

  ## Encryption

  defp insert_value(scope, workspace, secret, changeset) do
    changeset =
      changeset
      |> Ecto.Changeset.change(
        organisation_id: workspace.organisation_id,
        workspace_id: workspace.id,
        secret_id: secret.id,
        created_by_id: scope.user.id
      )

    encrypt_and_write(scope, workspace, secret, changeset, :insert)
  end

  # Encrypts the changeset's plaintext under the workspace's data key, bound to the value
  # id it will have, takes the plaintext out of the changeset, and writes the row.
  defp encrypt_and_write(scope, workspace, secret, changeset, how) do
    plaintext = Ecto.Changeset.get_change(changeset, :value)
    value_id = Ecto.Changeset.get_field(changeset, :value_id)

    with {:ok, data_key, key} <- data_key(workspace) do
      aad = Cipher.value_aad(workspace.id, secret.public_id, value_id)
      {nonce, ciphertext} = Cipher.encrypt(key, aad, plaintext)

      changeset
      |> Ecto.Changeset.delete_change(:value)
      |> Ecto.Changeset.change(
        nonce: nonce,
        ciphertext: ciphertext,
        data_key_id: data_key.id,
        updated_by_id: scope.user.id
      )
      |> then(fn changeset ->
        case how do
          :insert -> Repo.insert(changeset)
          :update -> Repo.update(changeset)
        end
      end)
      |> case do
        {:ok, row} -> {:ok, %{row | value: nil}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # A value decrypted under the value id it has and encrypted again under `value_id`,
  # without leaving this function.
  defp reencrypt(scope, workspace, secret, %Value{} = value, value_id) do
    changeset =
      Value.value_id_changeset(Ecto.Changeset.change(value, value_id: value_id), :required)

    with :ok <- valid(changeset),
         %Value{} = row <- Repo.reload!(value),
         {:ok, data_key} <- {:ok, Repo.get!(DataKey, row.data_key_id)},
         {:ok, key} <- unwrap(data_key),
         {:ok, plaintext} <-
           decrypt_row(key, workspace, secret, row) do
      # Bound to the value id the row will be stored with, as the changeset has it.
      aad =
        Cipher.value_aad(
          workspace.id,
          secret.public_id,
          Ecto.Changeset.get_field(changeset, :value_id)
        )

      {nonce, ciphertext} = Cipher.encrypt(key, aad, plaintext)

      changeset
      |> Ecto.Changeset.change(nonce: nonce, ciphertext: ciphertext, updated_by_id: scope.user.id)
      |> Repo.update()
    end
  end

  defp decrypt_row(key, workspace, secret, %Value{} = row) do
    aad = Cipher.value_aad(workspace.id, secret.public_id, row.value_id)

    case Cipher.decrypt(key, aad, row.nonce, row.ciphertext) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      :error ->
        unavailable(workspace.organisation_id, workspace.id, secret.public_id, row.value_id)
        {:error, :key_unavailable}
    end
  end

  # The workspace's data key, made with its first secret: the row, and the key unwrapped.
  # Inside the write, which holds the workspace's row, so two writes never both make one.
  defp data_key(%Workspace{id: workspace_id, organisation_id: organisation_id}) do
    data_key =
      Repo.one(from k in DataKey, where: k.workspace_id == ^workspace_id) ||
        new_data_key(organisation_id, workspace_id)

    case unwrap(data_key) do
      {:ok, key} -> {:ok, data_key, key}
      {:error, _reason} -> {:error, :key_unavailable}
    end
  end

  defp new_data_key(organisation_id, workspace_id) do
    {key_id, wrapping_key} = KeyDerivation.key(:values)
    aad = Cipher.data_key_aad(organisation_id, workspace_id)

    Repo.insert!(%DataKey{
      organisation_id: organisation_id,
      workspace_id: workspace_id,
      wrapped_key: Cipher.wrap(wrapping_key, Cipher.new_data_key(), aad),
      wrapping_key_id: key_id
    })
  end

  defp unwrap(%DataKey{} = data_key) do
    aad = Cipher.data_key_aad(data_key.organisation_id, data_key.workspace_id)

    with {:ok, wrapping_key} <- KeyDerivation.key(:values, data_key.wrapping_key_id),
         {:ok, key} <- Cipher.unwrap(wrapping_key, data_key.wrapped_key, aad) do
      {:ok, key}
    else
      :error ->
        Logger.error(
          "a workspace's data key cannot be unwrapped key_id=#{data_key.wrapping_key_id}: " <>
            "APIARY_ENCRYPTION_SECRET is not the key it was wrapped under",
          LogMetadata.metadata(data_key.organisation_id, data_key.workspace_id)
        )

        {:error, :key_unavailable}
    end
  end
end
