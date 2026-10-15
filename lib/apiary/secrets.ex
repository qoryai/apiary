defmodule Apiary.Secrets do
  @moduledoc """
  A workspace's stored secrets: values kept by name, encrypted at rest, and never shown
  again once saved. A run receives none of them: it receives only its security policy.

  A secret (`Apiary.Secrets.Secret`) has a name, unique in the workspace whatever its
  case, a public id (`sec_…`), a note on what it is used for, and either one value or
  several values, each with a **value id** the person names: `GITHUB_APP_PRIVATE_KEY` with
  the values `main-app` and `bot-app`. A secret has at least one value. Adding a second
  value to a secret whose one value has no value id names that value too.

  ## Write-only

  No function of this module returns a value, but `reveal_for_sealing/3`, which the
  secrets endpoint calls to seal a value to the gateway, and only that. A listing loads the
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
  `secret.use`. Every change leaves one `secret.write`
  entry in the audit trail, in its transaction, the secret its subject, with
  `details.change` saying what: `created`, `updated`, `value_set`, `value_added`,
  `value_renamed`, `value_deleted` or `deleted`, and the names and value ids it touched.

  A write locks the scope's organisation `FOR SHARE`, then the workspace, then reads the
  membership again (`Apiary.Access.reload/2`), the security policy's lock order
  (docs/access.md), and a change to a secret locks the secret's row: two writes to one
  secret, or a write and a deletion, take turns.

  A secret in use is not deleted, nor a value in use: `Apiary.Secrets.Usage` answers.

  ## An organisation's secrets

  A secret may belong to an organisation instead of a workspace: its `workspace_id` is
  nil. `list_organisation_secrets/1`, `get_organisation_secret/2` and
  `create_organisation_secret/2` read and make them; the changes of a secret, from
  `update_secret/3` to `delete_secret/2`, take either, and change a secret only at the
  level it is at, read again there. An organisation's secret's name is unique among the
  organisation's secrets whatever its case, and a workspace's secret may have the same
  name: nothing finds a secret by its name across the two.

  Who may read, change or link them the edition answers
  (`c:Apiary.Edition.organisation_secrets/2`), asked once the membership is read again,
  before anything of them is read or written; whether they may be sealed it answers for
  `:seal`, asked with a nil scope. Its refusal is handed back as it is.

  Their values are encrypted under the organisation's data key
  (`Apiary.Secrets.OrganisationDataKey`), one per organisation, made with its first
  secret, with associated data that binds each to its organisation, its secret's public
  id and its value id (`Apiary.Secrets.Cipher`, v2). Every change leaves its
  `secret.write` entry in the organisation's trail, with `details.level` `organisation`.

  A write of an organisation's secrets locks the organisation `FOR SHARE`, reads the
  membership again under `FOR SHARE`, asks the edition, then takes the organisation's
  advisory transaction lock for its secrets, so the writes of one organisation's secrets
  take turns and its first secret makes its data key alone; a change to a secret then
  locks the secret's row (docs/access.md).
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Audit, Edition, KeyDerivation, LogMetadata, PublicId, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Secrets.{Cipher, DataKey, OrganisationDataKey, Secret, Usage, Value}

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
  `:not_found` where the `secrets` feature is off.
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

  @doc """
  list_organisation_secrets/1 is the scope's organisation's secrets, those without a
  workspace, by name whatever its case, each with its values, their value ids and when
  they were set, never their ciphertext, as `list_secrets/1` loads them: `{:ok, secrets}`,
  where the edition lets the scope's person read them
  (`c:Apiary.Edition.organisation_secrets/2`, `:read`); else its `{:error, reason}`.
  """
  @spec list_organisation_secrets(Scope.t()) ::
          {:ok, [Secret.t()]} | {:error, Access.reason()}
  def list_organisation_secrets(%Scope{} = scope) do
    with :ok <- may_read_organisation(scope) do
      {:ok,
       Repo.all(
         from s in organisation_secrets(scope),
           order_by: [asc: fragment("lower(?)", s.name), asc: s.id],
           preload: [values: ^values_query()]
       )}
    end
  end

  @doc """
  get_organisation_secret/2 is the scope's organisation's secret, one without a
  workspace, with the public id `public_id`, with its values as `list_secrets/1` loads
  them: `{:ok, secret}`, where the edition lets the scope's person read them; else
  `{:error, reason}`, the edition's, or `:not_found` for a secret the organisation does
  not have at its level.
  """
  @spec get_organisation_secret(Scope.t(), term) ::
          {:ok, Secret.t()} | {:error, Access.reason()}
  def get_organisation_secret(%Scope{} = scope, public_id) do
    with :ok <- may_read_organisation(scope),
         true <- PublicId.valid?("sec", public_id),
         %Secret{} = secret <-
           Repo.one(
             from s in organisation_secrets(scope),
               where: s.public_id == ^public_id,
               preload: [values: ^values_query()]
           ) do
      {:ok, secret}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  list_uses/2 is what uses each of `secrets`, as `list_secrets/1` or
  `list_organisation_secrets/1` gave them (`Apiary.Secrets.Usage`), by the secret's row
  id: `{:ok, uses}`, for a reader who may read every level among them, `secret.read` for
  the scope's workspace's, and the edition's answer for the organisation's; else
  `{:error, reason}`. A secret of another workspace or organisation is used by nothing
  here.
  """
  @spec list_uses(Scope.t(), [Secret.t()]) ::
          {:ok, %{Ecto.UUID.t() => [Usage.use()]}} | {:error, Access.reason()}
  def list_uses(%Scope{} = scope, secrets) when is_list(secrets) do
    {at_organisation, at_workspace} = Enum.split_with(secrets, &is_nil(&1.workspace_id))

    with :ok <- may_read_uses(scope, at_organisation, at_workspace) do
      {:ok, Map.new(secrets, &{&1.id, uses_in(scope, &1)})}
    end
  end

  # A list of none, or with a workspace's secret, is asked of the workspace (`secret.read`);
  # one with an organisation's secret, of the edition; one with both, of both.
  defp may_read_uses(scope, [], _at_workspace), do: may_read(scope)
  defp may_read_uses(scope, _at_organisation, []), do: may_read_organisation(scope)

  defp may_read_uses(scope, _at_organisation, _at_workspace) do
    with :ok <- may_read(scope), do: may_read_organisation(scope)
  end

  defp uses_in(
         %Scope{organisation: %Organisation{id: organisation_id}},
         %Secret{organisation_id: organisation_id, workspace_id: nil} = secret
       ),
       do: Usage.uses(Repo, secret)

  defp uses_in(
         %Scope{workspace: %Workspace{id: workspace_id}},
         %Secret{workspace_id: workspace_id} = secret
       )
       when not is_nil(workspace_id),
       do: Usage.uses(Repo, secret)

  defp uses_in(_scope, %Secret{}), do: []

  defp may_read(%Scope{workspace: %Workspace{} = workspace} = scope),
    do: Access.authorize(scope, :"secret.read", workspace)

  defp may_read(_scope), do: {:error, :not_found}

  # The edition's answer for the organisation's secrets, asked of the membership as it is
  # now (`Access.reload/2`).
  defp may_read_organisation(%Scope{organisation: %Organisation{}} = scope),
    do: scope |> Access.reload() |> organisation_verdict(:read)

  defp may_read_organisation(_scope), do: {:error, :not_found}

  defp organisation_verdict(%Scope{organisation: %Organisation{}} = scope, verb),
    do: Edition.organisation_secrets(scope, verb)

  defp organisation_verdict(_scope, _verb), do: {:error, :not_found}

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

  # The scope's organisation's secrets, those without a workspace.
  defp organisation_secrets(%Scope{organisation: %Organisation{id: organisation_id}}) do
    from s in Secret,
      where: s.organisation_id == ^organisation_id and is_nil(s.workspace_id)
  end

  defp values_query do
    from v in Value, select: struct(v, ^Value.public_fields()), order_by: [asc: v.value_id]
  end

  ## Writing

  @doc """
  create_secret/2 stores a new secret of the scope's workspace (`secret.write`) with its
  values, in one transaction. `attrs` has `name`, `note` (optional), and either

  - `value`, and `value_id`, optional: a secret of one value; or
  - `values`, a list of maps, each with `value_id`, required, and `value`, or a map of
    them by index, as a form sends them, taken in the order of the index: a secret of
    several values, at most `max_values/0`, each value id unique in the secret. A
    `value` or `value_id` beside them is not looked at.

  `{:ok, secret}`, its values loaded without their ciphertext; or `{:error, refusal}`, a
  changeset whose errors are on `name`, `note`, `value` or `value_id`, or, for several
  values, on `values` and on each value's changeset. More than `max_values/0` values
  are refused with an error on `values` before any of them is looked at, and none is
  under it. Otherwise, several values refused by their checks or by the secret's name
  have their changesets under `values`, in the order they came, each with its errors on
  its `value_id` and its `value`; no value at all is an error on `values`. A
  value ID or a value that is not text is invalid. The changeset holds no value, nor do
  the changesets of the values under it.
  """
  @spec create_secret(Scope.t(), map) :: {:ok, Secret.t()} | {:error, refusal}
  def create_secret(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    write(scope, fn scope, workspace ->
      new_secret(
        scope,
        %Secret{organisation_id: workspace.organisation_id, workspace_id: workspace.id},
        attrs,
        Access.check(scope, :"secret.write", workspace)
      )
    end)
    |> reload()
  end

  @doc """
  create_organisation_secret/2 stores a new secret of the scope's organisation, without a
  workspace, with its values, in one transaction, where the edition lets the scope's
  person change the organisation's secrets (`c:Apiary.Edition.organisation_secrets/2`,
  `:write`). `attrs` and the answer are `create_secret/2`'s; a refusal of the edition is
  its `{:error, reason}`, as it is.
  """
  @spec create_organisation_secret(Scope.t(), map) :: {:ok, Secret.t()} | {:error, refusal}
  def create_organisation_secret(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    write_organisation(scope, fn scope, organisation ->
      new_secret(scope, %Secret{organisation_id: organisation.id, workspace_id: nil}, attrs, :ok)
    end)
    |> reload()
  end

  # A new secret at the level `secret` names, with its values, once `may` is `:ok`.
  defp new_secret(scope, %Secret{} = secret, attrs, may) do
    secret_changeset =
      %{
        secret
        | public_id: PublicId.generate("sec"),
          created_by_id: scope.user.id,
          updated_by_id: scope.user.id
      }
      |> Secret.changeset(attrs)

    {how, value_changesets} = new_values(attrs)

    with :ok <- may,
         :ok <- valid_new(how, secret_changeset, value_changesets),
         {:ok, secret} <-
           secret_changeset |> Repo.insert() |> with_values(how, value_changesets),
         {:ok, value_ids} <- insert_values(scope, secret, value_changesets),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"secret.write", secret, %{
             after: %{name: secret.name, note: secret.note, value_ids: value_ids},
             details:
               level(secret, %{change: "created", secret_id: secret.public_id, name: secret.name})
           }) do
      {:ok, secret}
    end
  end

  # An entry's details, with `level: "organisation"` for a secret of an organisation.
  defp level(%Secret{workspace_id: nil}, details), do: Map.put(details, :level, "organisation")
  defp level(%Secret{}, details), do: details

  # A new secret's values: its one value, its value id optional; or several, each with a
  # value id, unique among them.
  defp new_values(%{"values" => values}) do
    if entries(values) > @max_values,
      do: {:several, :too_many},
      else: {:several, value_changesets(values)}
  end

  defp new_values(attrs), do: {:one, [Value.changeset(%Value{}, attrs)]}

  # How many values were sent, counted before any is looked at.
  defp entries(values) when is_map(values), do: map_size(values)
  defp entries(values) when is_list(values), do: length(values)
  defp entries(_values), do: 0

  defp value_changesets(values) do
    values
    |> in_order()
    |> Enum.map(fn value ->
      value = Map.new(value, fn {key, field} -> {to_string(key), field} end)
      Value.changeset(%Value{}, value, value_id: :required)
    end)
    |> unique_value_ids()
  end

  # A form's values by index ("0", "1", …), in the order of the index; a list as it is.
  defp in_order(values) when is_list(values), do: Enum.filter(values, &is_map/1)

  defp in_order(values) when is_map(values) do
    values
    |> Enum.flat_map(fn {index, value} ->
      case Integer.parse(to_string(index)) do
        {index, ""} when is_map(value) -> [{index, value}]
        _other -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp in_order(_values), do: []

  # A value id taken by a value before it is refused on the later one.
  defp unique_value_ids(changesets) do
    {changesets, _seen} =
      Enum.map_reduce(changesets, MapSet.new(), fn changeset, seen ->
        case Ecto.Changeset.get_field(changeset, :value_id) do
          nil ->
            {changeset, seen}

          value_id ->
            if MapSet.member?(seen, value_id),
              do:
                {Ecto.Changeset.add_error(
                   changeset,
                   :value_id,
                   dgettext_noop("errors", "is already a value ID of this secret")
                 ), seen},
              else: {changeset, MapSet.put(seen, value_id)}
        end
      end)

    changesets
  end

  # A new secret's changesets, all checked before anything is written. For one value, its
  # errors on the secret's changeset, so a form shows every error at once; for several,
  # the values' changesets under the secret's, each with its own, and the count of them
  # on `values`.
  defp valid_new(:one, secret, [value]), do: valid(secret, value)

  defp valid_new(:several, secret, :too_many) do
    {:error,
     Ecto.Changeset.add_error(
       secret,
       :values,
       dgettext_noop("errors", "A secret holds at most %{count} values."),
       count: @max_values,
       validation: :length,
       kind: :max
     )}
  end

  defp valid_new(:several, secret, values) do
    count = length(values)

    secret =
      if count == 0,
        do:
          Ecto.Changeset.add_error(secret, :values, dgettext_noop("errors", "can't be blank"),
            validation: :required
          ),
        else: secret

    if secret.valid? and Enum.all?(values, & &1.valid?) do
      :ok
    else
      {:error, %{Ecto.Changeset.put_assoc(secret, :values, values) | valid?: false}}
    end
  end

  # A new secret the database refused, its name taken: for several values, with their
  # changesets under it all the same, so a form shows each as it was.
  defp with_values({:error, %Ecto.Changeset{} = secret}, :several, values),
    do: {:error, %{Ecto.Changeset.put_assoc(secret, :values, values) | valid?: false}}

  defp with_values(result, _how, _values), do: result

  defp insert_values(scope, secret, changesets) do
    Enum.reduce_while(changesets, {:ok, []}, fn changeset, {:ok, value_ids} ->
      case insert_value(scope, secret, changeset) do
        {:ok, value} -> {:cont, {:ok, value_ids ++ [value.value_id]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
                   Map.put(
                     changed,
                     :details,
                     level(updated, %{
                       change: "updated",
                       secret_id: updated.public_id,
                       name: updated.name
                     })
                   )
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
             encrypt_and_write(scope, current, changeset, :update),
           {:ok, current} <- touch(scope, current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"secret.write", current, %{
               details:
                 level(current, %{
                   change: "value_set",
                   secret_id: current.public_id,
                   name: current.name,
                   value_id: value_id
                 })
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
      changeset = Value.changeset(%Value{}, attrs, value_id: :required)
      unnamed = Enum.find(current.values, &is_nil(&1.value_id))

      with :ok <- room_for_another(current),
           {:ok, first} <- first_value_id(unnamed, attrs, changeset),
           :ok <- valid(changeset),
           :ok <- rename_first(scope, current, unnamed, first),
           {:ok, _row} <- insert_value(scope, current, changeset),
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
                 |> then(&level(current, &1))
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

  defp rename_first(_scope, _secret, nil, nil), do: :ok

  defp rename_first(scope, secret, %Value{} = unnamed, value_id) do
    case reencrypt(scope, secret, unnamed, value_id) do
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
          with {:ok, _row} <- reencrypt(scope, current, row, new_value_id),
               {:ok, current} <- touch(scope, current),
               {:ok, _entry} <-
                 Audit.record(Repo, scope, :"secret.write", current, %{
                   before: %{value_id: value_id},
                   after: %{value_id: new_value_id},
                   details:
                     level(current, %{
                       change: "value_renamed",
                       secret_id: current.public_id,
                       name: current.name
                     })
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
               details:
                 level(current, %{
                   change: "value_deleted",
                   secret_id: current.public_id,
                   name: current.name
                 })
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
               details:
                 level(deleted, %{
                   change: "deleted",
                   secret_id: deleted.public_id,
                   name: deleted.name
                 })
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
  to the gateway's key, and for nothing else: the one function that returns a value. The
  value is the secret with the public id `secret_id` of `place`, a workspace or an
  organisation, at that level only, and its value with `value_id`, nil for a secret's one
  value without one. A workspace's reveal never finds its organisation's secret, nor an
  organisation's a workspace's.

  `{:ok, plaintext}`; `{:error, :not_found}` for a secret or a value the place does not
  have at its level; `{:error, :unavailable}` when the value cannot be decrypted: the
  data key was wrapped under a key the instance does not hold, or the row is not the one
  that was written (moved to another secret, workspace, organisation or value id, or
  changed), with a line in the log that names the secret and the value id, never the
  value. For an organisation, the edition is asked first, `:seal` with a nil scope
  (`c:Apiary.Edition.organisation_secrets/2`), and its refusal is the answer, as it is.

  It asks nothing of `Apiary.Access`, and is the one function of this module that does
  not: it is the server's sealing path, called by the secrets endpoint once it has
  verified the gateway's signed request and decided what that gateway may receive, with no
  person's scope to ask about. The plaintext goes into the seal and nowhere else: not
  into a log, an assign, a process's state or an error.
  """
  @spec reveal_for_sealing(%Workspace{} | %Organisation{}, String.t(), String.t() | nil) ::
          {:ok, binary} | {:error, Access.reason() | :unavailable}
  def reveal_for_sealing(
        %Workspace{id: workspace_id, organisation_id: organisation_id},
        secret_id,
        value_id
      )
      when is_binary(secret_id) and (is_binary(value_id) or is_nil(value_id)) do
    from(v in Value,
      join: s in Secret,
      on: s.id == v.secret_id,
      join: k in DataKey,
      on: k.id == v.data_key_id,
      where:
        s.organisation_id == ^organisation_id and s.workspace_id == ^workspace_id and
          s.public_id == ^secret_id,
      select: {v, k}
    )
    |> reveal(organisation_id, workspace_id, secret_id, value_id)
  end

  def reveal_for_sealing(%Organisation{id: organisation_id}, secret_id, value_id)
      when is_binary(secret_id) and (is_binary(value_id) or is_nil(value_id)) do
    with :ok <- Edition.organisation_secrets(nil, :seal) do
      from(v in Value,
        join: s in Secret,
        on: s.id == v.secret_id and s.organisation_id == v.organisation_id,
        join: k in OrganisationDataKey,
        on: k.id == v.organisation_data_key_id and k.organisation_id == v.organisation_id,
        where:
          s.organisation_id == ^organisation_id and is_nil(s.workspace_id) and
            is_nil(v.workspace_id) and s.public_id == ^secret_id,
        select: {v, k}
      )
      |> reveal(organisation_id, nil, secret_id, value_id)
    end
  end

  defp reveal(query, organisation_id, workspace_id, secret_id, value_id) do
    query =
      if is_nil(value_id),
        do: where(query, [v], is_nil(v.value_id)),
        else: where(query, [v], v.value_id == ^value_id)

    case Repo.one(query) do
      {%Value{} = row, data_key} ->
        aad = value_aad(organisation_id, workspace_id, secret_id, value_id)

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

  # A write to the scope's organisation's secrets, in one transaction, in the lock order of
  # docs/access.md: the organisation `FOR SHARE` (`Access.lock_places/1`), the membership
  # read again under its locks (`Access.reload/2`, `lock: :share`), the edition's answer
  # for `:write`, then the organisation's advisory transaction lock for its secrets, which
  # every write of them takes, so they take turns: the first secret makes the data key
  # alone, and a name is checked against the names before it. Then `fun` with the scope as
  # read and the organisation.
  defp write_organisation(%Scope{organisation: %Organisation{id: organisation_id}} = scope, fun) do
    Repo.transact(fn ->
      :ok = Access.lock_places(scope)
      scope = Access.reload(scope, lock: :share)

      with %Organisation{} = organisation <-
             Repo.get(Organisation, organisation_id) || {:error, :not_found},
           :ok <- organisation_verdict(scope, :write) do
        :ok = lock_organisation_secrets(organisation_id)
        fun.(scope, organisation)
      end
    end)
  end

  defp write_organisation(_scope, _fun), do: {:error, :not_found}

  # The organisation's advisory transaction lock for its secrets, held until the
  # transaction ends. It locks no row: it is taken after every row lock of the lock order
  # but those of the rows the write changes, and only by the writes of the organisation's
  # secrets.
  defp lock_organisation_secrets(organisation_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "apiary:organisation_secrets:" <> organisation_id
    ])

    :ok
  end

  # A write to one secret, at the level the secret is at: the secret read again under
  # `FOR UPDATE` at that level, in the scope's workspace or organisation, with its values,
  # then asked of.
  defp write_secret(%Scope{} = scope, %Secret{workspace_id: nil, id: id}, fun) do
    write_organisation(scope, fn scope, _organisation ->
      case Repo.one(
             from s in organisation_secrets(scope),
               where: s.id == ^id,
               lock: "FOR UPDATE"
           ) do
        %Secret{} = current -> fun.(scope, Repo.preload(current, values: values_query()))
        nil -> {:error, :not_found}
      end
    end)
  end

  defp write_secret(%Scope{} = scope, %Secret{id: id}, fun) do
    write(scope, fn scope, _workspace ->
      with %Secret{} = current <-
             Repo.one(
               from s in secrets(scope),
                 where: s.id == ^id,
                 lock: "FOR UPDATE"
             ),
           current = Repo.preload(current, values: values_query()),
           :ok <- Access.check(scope, :"secret.write", current) do
        fun.(scope, current)
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

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
  # The values under a new secret's changeset are scrubbed too, and the `values` the
  # form sent dropped from its params.
  defp scrub(%Ecto.Changeset{} = changeset) do
    params = changeset.params && Map.drop(changeset.params, ["value", :value, "values", :values])

    changes =
      case Map.delete(changeset.changes, :value) do
        %{values: values} = changes when is_list(values) ->
          %{changes | values: Enum.map(values, &scrub/1)}

        changes ->
          changes
      end

    %{changeset | params: params, changes: changes}
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

  defp insert_value(scope, secret, changeset) do
    changeset =
      changeset
      |> Ecto.Changeset.change(
        organisation_id: secret.organisation_id,
        workspace_id: secret.workspace_id,
        secret_id: secret.id,
        created_by_id: scope.user.id
      )

    encrypt_and_write(scope, secret, changeset, :insert)
  end

  # Encrypts the changeset's plaintext under the data key of the secret's level, bound to
  # the value id it will have, takes the plaintext out of the changeset, and writes the
  # row.
  defp encrypt_and_write(scope, secret, changeset, how) do
    plaintext = Ecto.Changeset.get_change(changeset, :value)
    value_id = Ecto.Changeset.get_field(changeset, :value_id)

    with {:ok, key_field, key} <- data_key(secret) do
      aad = value_aad(secret, value_id)
      {nonce, ciphertext} = Cipher.encrypt(key, aad, plaintext)

      changeset
      |> Ecto.Changeset.delete_change(:value)
      |> Ecto.Changeset.change(
        [nonce: nonce, ciphertext: ciphertext, updated_by_id: scope.user.id] ++ key_field
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
  defp reencrypt(scope, secret, %Value{} = value, value_id) do
    changeset =
      Value.value_id_changeset(Ecto.Changeset.change(value, value_id: value_id), :required)

    with :ok <- valid(changeset),
         %Value{} = row <- Repo.reload!(value),
         {:ok, key} <- unwrap(key_of(row)),
         {:ok, plaintext} <- decrypt_row(key, secret, row) do
      # Bound to the value id the row will be stored with, as the changeset has it.
      aad = value_aad(secret, Ecto.Changeset.get_field(changeset, :value_id))
      {nonce, ciphertext} = Cipher.encrypt(key, aad, plaintext)

      changeset
      |> Ecto.Changeset.change(nonce: nonce, ciphertext: ciphertext, updated_by_id: scope.user.id)
      |> Repo.update()
    end
  end

  # The data key a value's row names: its organisation's, or its workspace's.
  defp key_of(%Value{organisation_data_key_id: id}) when not is_nil(id),
    do: Repo.get!(OrganisationDataKey, id)

  defp key_of(%Value{data_key_id: id}), do: Repo.get!(DataKey, id)

  defp decrypt_row(key, secret, %Value{} = row) do
    aad = value_aad(secret, row.value_id)

    case Cipher.decrypt(key, aad, row.nonce, row.ciphertext) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      :error ->
        unavailable(secret.organisation_id, secret.workspace_id, secret.public_id, row.value_id)
        {:error, :key_unavailable}
    end
  end

  # The associated data of a value of `secret`: v1 at a workspace, v2 at an organisation
  # (`Apiary.Secrets.Cipher`).
  defp value_aad(%Secret{} = secret, value_id),
    do: value_aad(secret.organisation_id, secret.workspace_id, secret.public_id, value_id)

  defp value_aad(organisation_id, nil, secret_id, value_id),
    do: Cipher.organisation_value_aad(organisation_id, secret_id, value_id)

  defp value_aad(_organisation_id, workspace_id, secret_id, value_id),
    do: Cipher.value_aad(workspace_id, secret_id, value_id)

  # The data key of the secret's level, made with its first secret: the field of the
  # value's row that names it, and the key unwrapped.
  #
  # A workspace's: inside the write, which holds the workspace's row, so two writes never
  # both make one.
  #
  # An organisation's: inside the write, which holds the organisation's advisory lock, so
  # two writes do not both get here first; and should one ever, the unique index on
  # `organisation_id` keeps one key, `ON CONFLICT DO NOTHING` leaves the other's, and the
  # read after it takes whichever is there.
  defp data_key(%Secret{workspace_id: nil, organisation_id: organisation_id}) do
    data_key =
      organisation_data_key(organisation_id) || new_organisation_data_key(organisation_id)

    case unwrap(data_key) do
      {:ok, key} -> {:ok, [organisation_data_key_id: data_key.id], key}
      {:error, _reason} -> {:error, :key_unavailable}
    end
  end

  defp data_key(%Secret{workspace_id: workspace_id, organisation_id: organisation_id}) do
    data_key =
      Repo.one(from k in DataKey, where: k.workspace_id == ^workspace_id) ||
        new_data_key(organisation_id, workspace_id)

    case unwrap(data_key) do
      {:ok, key} -> {:ok, [data_key_id: data_key.id], key}
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

  defp organisation_data_key(organisation_id),
    do: Repo.one(from k in OrganisationDataKey, where: k.organisation_id == ^organisation_id)

  defp new_organisation_data_key(organisation_id) do
    {key_id, wrapping_key} = KeyDerivation.key(:values)
    aad = Cipher.organisation_data_key_aad(organisation_id)

    Repo.insert!(
      %OrganisationDataKey{
        organisation_id: organisation_id,
        wrapped_key: Cipher.wrap(wrapping_key, Cipher.new_data_key(), aad),
        wrapping_key_id: key_id
      },
      on_conflict: :nothing,
      conflict_target: [:organisation_id]
    )

    organisation_data_key(organisation_id)
  end

  defp unwrap(%DataKey{} = data_key) do
    aad = Cipher.data_key_aad(data_key.organisation_id, data_key.workspace_id)
    unwrap(data_key, aad, "a workspace's", data_key.workspace_id)
  end

  defp unwrap(%OrganisationDataKey{} = data_key) do
    aad = Cipher.organisation_data_key_aad(data_key.organisation_id)
    unwrap(data_key, aad, "an organisation's", nil)
  end

  defp unwrap(data_key, aad, whose, workspace_id) do
    with {:ok, wrapping_key} <- KeyDerivation.key(:values, data_key.wrapping_key_id),
         {:ok, key} <- Cipher.unwrap(wrapping_key, data_key.wrapped_key, aad) do
      {:ok, key}
    else
      :error ->
        Logger.error(
          "#{whose} data key cannot be unwrapped key_id=#{data_key.wrapping_key_id}: " <>
            "APIARY_ENCRYPTION_SECRET is not the key it was wrapped under",
          LogMetadata.metadata(data_key.organisation_id, workspace_id)
        )

        {:error, :key_unavailable}
    end
  end
end
