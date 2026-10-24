defmodule Apiary.Secrets.Instance do
  @moduledoc """
  The instance's secrets: secrets of no organisation and no workspace, each belonging to
  one adapter (`Apiary.Secrets.InstanceSecret`). An adapter keeps one such secret, whose
  values are the secrets the adapter stores in Qory Apiary, each by its name: an app's
  private key, a webhook secret. Qory Apiary does not read what a value means. No query of
  an organisation's or a workspace's secrets (`Apiary.Secrets`) reads them.

  ## At rest

  Each value is encrypted with AES-256-GCM under the instance's data key
  (`Apiary.Secrets.InstanceDataKey`), with a fresh nonce, and with the v3 associated data,
  which binds it to its adapter's public id, its secret's public id and its value id
  (`Apiary.Secrets.Cipher`). The data key, 32 random bytes made with the instance's first
  secret, is kept only wrapped under the instance's values key (`Apiary.KeyDerivation`),
  with that key's id beside it. Nothing keeps the unwrapped key beyond a call.

  The adapter's node points to its secret by a reference (`Apiary.Secrets.Reference`),
  `builtin:<the secret's public id>`, in `secret_store` and `secret_entry`. The built-in
  store resolves the reference only for that adapter.

  ## Writing and reading

  - `put_app_values/3` replaces every value of an adapter's secret, in one transaction,
    with the adapter's row held `FOR NO KEY UPDATE`, the lock order of the adapters' code:
    the secret is made at the first write, revision 1, and each later write raises its
    revision by one.
  - `reveal_app_values_for_sealing/1` is the plaintext of an adapter's values, for the
    adapter's request that delivers them sealed to its key, and for nothing else.
  - `delete_app_values/2` deletes an adapter's secret, when the adapter is deleted.

  Nothing here logs a value, a nonce, a ciphertext or a key. A line about a value that
  does not decrypt contains the adapter's public id and the value id; a line about a data
  key that does not unwrap contains the id of the key it was wrapped under. A value is in
  an `Apiary.Secrets.InstanceSecretValue`, which `inspect` shows without it.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{KeyDerivation, PublicId, Repo}
  alias Apiary.Adapters.Installed
  alias Apiary.Nodes.Node

  alias Apiary.Secrets.{
    Cipher,
    InstanceDataKey,
    InstanceSecret,
    InstanceSecretValue,
    Reference
  }

  # The name of an adapter's one secret.
  @name "APP_VALUES"
  @max_values 16
  @max_value_bytes 16_384
  @value_id ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

  @typedoc "What a write stored: the reference, the revision, the value ids, and whether it replaced values."
  @type stored :: %{
          reference: Reference.t(),
          revision: pos_integer,
          names: [String.t()],
          replaced: boolean
        }

  @typedoc """
  An adapter's values: the revision of its secret, nil before any write, and its values,
  sorted by value id, each with its plaintext in `value`.
  """
  @type revealed :: %{revision: pos_integer | nil, values: [InstanceSecretValue.t()]}

  @doc "max_values/0 is the most values an adapter's secret has."
  @spec max_values() :: pos_integer
  def max_values, do: @max_values

  @doc "max_value_bytes/0 is the most bytes of UTF-8 a value has."
  @spec max_value_bytes() :: pos_integer
  def max_value_bytes, do: @max_value_bytes

  @doc """
  valid_values?/1 says whether `values` may be stored: at most 16
  `Apiary.Secrets.InstanceSecretValue`s, each value id of lower-case letters, digits,
  dots, underscores and hyphens, 1 to 64 characters, starting with a letter or a digit,
  each once, and each value 1 to 16,384 bytes of UTF-8 without a NUL.
  """
  @spec valid_values?(term) :: boolean
  def valid_values?(values) when is_list(values) and length(values) <= @max_values do
    ids = for %InstanceSecretValue{value_id: id} <- values, do: id

    length(ids) == length(values) and Enum.uniq(ids) == ids and
      Enum.all?(values, fn %InstanceSecretValue{value_id: id, value: value} ->
        is_binary(id) and Regex.match?(@value_id, id) and value?(value)
      end)
  end

  def valid_values?(_values), do: false

  defp value?(value) when is_binary(value),
    do:
      byte_size(value) in 1..@max_value_bytes and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp value?(_value), do: false

  @doc """
  put_app_values/3 replaces every value of `adapter`'s secret with `values`
  (`valid_values?/1`), in one transaction, with the adapter's row, in use, held
  `FOR NO KEY UPDATE`. An empty list leaves the secret with no value.

  `opts[:record]`, a function of the adapter as locked and the `t:stored/0` result, runs
  last in the transaction, for the caller's entry in the trail: `{:ok, _}` keeps the
  write, `{:error, reason}` rolls it back and is the answer. `opts[:allowed]`, a function
  of the adapter as locked, runs first: `:ok` goes on, `{:error, reason}` is the answer.

  `{:ok, stored}`; `{:error, :not_found}` for an adapter deleted, or installed with Qory
  Apiary and no longer listed in `QORY_INSTALLED_ADAPTERS`;
  `{:error, :invalid}` for values that are not valid; `{:error, :unavailable}` when the
  instance's data key cannot be unwrapped, which the log says, without a value.
  """
  @spec put_app_values(Node.t(), [InstanceSecretValue.t()], keyword) ::
          {:ok, stored} | {:error, term}
  def put_app_values(%Node{kind: :adapter, id: id}, values, opts \\ []) do
    record = Keyword.get(opts, :record, fn _adapter, _stored -> {:ok, nil} end)
    allowed = Keyword.get(opts, :allowed, fn _adapter -> :ok end)

    if valid_values?(values) do
      Repo.transact(fn ->
        with %Node{} = adapter <- lock_adapter(id) || {:error, :not_found},
             :ok <- listed(adapter),
             :ok <- allowed.(adapter),
             {:ok, key} <- data_key(),
             {:ok, stored} <- write(adapter, key, values),
             {:ok, _recorded} <- record.(adapter, stored) do
          {:ok, stored}
        end
      end)
    else
      {:error, :invalid}
    end
  end

  defp lock_adapter(id) do
    from(n in Node,
      where:
        n.id == ^id and n.kind == :adapter and is_nil(n.deleted_at) and
          is_nil(n.organisation_id) and is_nil(n.workspace_id),
      lock: "FOR NO KEY UPDATE"
    )
    |> Repo.one()
  end

  defp listed(%Node{installed_as: nil}), do: :ok

  defp listed(%Node{installed_as: name}),
    do: if(Installed.listed?(name), do: :ok, else: {:error, :not_found})

  defp write(adapter, key, values) do
    now = DateTime.utc_now()

    {secret, replaced} =
      case Repo.one(
             from s in InstanceSecret,
               where:
                 s.adapter_id == ^adapter.id and fragment("lower(?)", s.name) == ^lower(@name)
           ) do
        nil ->
          secret =
            PublicId.Insert.insert!(%InstanceSecret{
              public_id: PublicId.generate("sec"),
              adapter_id: adapter.id,
              name: @name,
              revision: 1
            })

          {secret, false}

        %InstanceSecret{} = secret ->
          {1, _} =
            Repo.update_all(
              from(s in InstanceSecret, where: s.id == ^secret.id),
              set: [revision: secret.revision + 1, updated_at: now]
            )

          Repo.delete_all(from v in InstanceSecretValue, where: v.secret_id == ^secret.id)
          {%{secret | revision: secret.revision + 1}, true}
      end

    rows =
      for %InstanceSecretValue{value_id: value_id, value: value} <- values do
        aad = Cipher.instance_value_aad(adapter.public_id, secret.public_id, value_id)
        {nonce, ciphertext} = Cipher.encrypt(key, aad, value)

        %{
          id: Ecto.UUID.generate(),
          secret_id: secret.id,
          value_id: value_id,
          nonce: nonce,
          ciphertext: ciphertext,
          inserted_at: now
        }
      end

    {_count, nil} = Repo.insert_all(InstanceSecretValue, rows)
    {:ok, reference} = Reference.new(Reference.builtin(), secret.public_id)

    if adapter.secret_store != reference.store or adapter.secret_entry != reference.entry do
      {1, _} =
        Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
          set: [secret_store: reference.store, secret_entry: reference.entry, updated_at: now]
        )
    end

    {:ok,
     %{
       reference: reference,
       revision: secret.revision,
       names: values |> Enum.map(& &1.value_id) |> Enum.sort(),
       replaced: replaced
     }}
  end

  defp lower(name), do: String.downcase(name)

  @doc """
  reveal_app_values_for_sealing/1 is the plaintext of `adapter`'s values, for the
  adapter's request that delivers them sealed to the key it signed with, and for nothing
  else: `{:ok, revealed}`, the values sorted by value id; no value and a nil revision when
  the adapter has stored none. The reference on the adapter's row is resolved in the
  built-in store, to a secret of that adapter alone.

  `{:error, :unavailable}` when a value cannot be decrypted, with one log line and never
  the value:

    * a row is not the one that was written (moved to another adapter, secret or value
      id, or changed), or the reference finds no secret of the adapter: the line contains
      the adapter's public id and the value id, `(none)` for a missing secret;
    * the instance's data key was wrapped under a key the instance does not hold: the
      line contains that key's id, `key_id=`, and no adapter.

  A reference with no data key row also answers `{:error, :unavailable}`, and logs
  nothing: the first write makes that row, so a reference without one does not occur
  unless the row was deleted.

  It asks nothing of `Apiary.Access`: the caller has verified the adapter's signed request
  and its key's right to it. The plaintext goes into the seal and nowhere else.
  """
  @spec reveal_app_values_for_sealing(Node.t()) :: {:ok, revealed} | {:error, :unavailable}
  def reveal_app_values_for_sealing(%Node{kind: :adapter, id: id, public_id: public_id}) do
    case Repo.one(from n in Node, where: n.id == ^id, select: {n.secret_store, n.secret_entry}) do
      {nil, nil} -> {:ok, %{revision: nil, values: []}}
      {store, entry} -> reveal(id, public_id, Reference.new(store, entry))
      nil -> {:ok, %{revision: nil, values: []}}
    end
  end

  defp reveal(id, public_id, {:ok, %Reference{store: "builtin", entry: secret_id}}) do
    secret =
      Repo.one(
        from s in InstanceSecret,
          where: s.public_id == ^secret_id and s.adapter_id == ^id,
          preload: [values: ^from(v in InstanceSecretValue, order_by: v.value_id)]
      )

    with %InstanceSecret{} <- secret || unavailable(public_id, nil),
         {:ok, key} <- unwrap_current(),
         {:ok, values} <- decrypt_all(key, public_id, secret) do
      {:ok, %{revision: secret.revision, values: values}}
    end
  end

  defp reveal(_id, public_id, _reference), do: unavailable(public_id, nil)

  defp unwrap_current do
    case Repo.get(InstanceDataKey, true) do
      %InstanceDataKey{} = data_key -> unwrap(data_key)
      nil -> {:error, :unavailable}
    end
  end

  defp decrypt_all(key, public_id, %InstanceSecret{values: rows} = secret) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      aad = Cipher.instance_value_aad(public_id, secret.public_id, row.value_id)

      case Cipher.decrypt(key, aad, row.nonce, row.ciphertext) do
        {:ok, plaintext} ->
          {:cont, {:ok, [%InstanceSecretValue{value_id: row.value_id, value: plaintext} | acc]}}

        :error ->
          {:halt, unavailable(public_id, row.value_id)}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unavailable(public_id, value_id) do
    Logger.error(
      "an adapter's stored secret value cannot be decrypted adapter_id=#{public_id} " <>
        "value_id=#{value_id || "(none)"}: APIARY_ENCRYPTION_SECRET is not the key it was " <>
        "stored under, or the row was changed"
    )

    {:error, :unavailable}
  end

  @doc """
  delete_app_values/2 deletes `adapter`'s secret and its values through `repo`, inside the
  caller's transaction, which holds the adapter's row, as the adapter's deletion does:
  true when there was one, false otherwise. The caller clears the adapter's reference.
  """
  @spec delete_app_values(Ecto.Repo.t(), Node.t()) :: boolean
  def delete_app_values(repo, %Node{kind: :adapter, id: id}) do
    {count, _} = repo.delete_all(from s in InstanceSecret, where: s.adapter_id == ^id)
    count > 0
  end

  # The instance's data key, made with its first secret: inside a write, which holds its
  # adapter's row, so two writes of one adapter never both get here first; two adapters'
  # writes may, and the primary key keeps one row, `ON CONFLICT DO NOTHING` leaves the
  # other's, and the read after it takes whichever is there.
  defp data_key do
    data_key = Repo.get(InstanceDataKey, true) || new_data_key()
    unwrap(data_key)
  end

  defp new_data_key do
    {key_id, wrapping_key} = KeyDerivation.key(:values)

    Repo.insert!(
      %InstanceDataKey{
        id: true,
        wrapped_key:
          Cipher.wrap(wrapping_key, Cipher.new_data_key(), Cipher.instance_data_key_aad()),
        wrapping_key_id: key_id
      },
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    Repo.get!(InstanceDataKey, true)
  end

  defp unwrap(%InstanceDataKey{} = data_key) do
    with {:ok, wrapping_key} <- KeyDerivation.key(:values, data_key.wrapping_key_id),
         {:ok, key} <-
           Cipher.unwrap(wrapping_key, data_key.wrapped_key, Cipher.instance_data_key_aad()) do
      {:ok, key}
    else
      :error ->
        Logger.error(
          "the instance's data key cannot be unwrapped key_id=#{data_key.wrapping_key_id}: " <>
            "APIARY_ENCRYPTION_SECRET is not the key it was wrapped under"
        )

        {:error, :unavailable}
    end
  end
end
