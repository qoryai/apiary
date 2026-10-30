defmodule Apiary.InstanceConfig do
  @moduledoc """
  The instance's settings an instance admin changes in Instance settings › Configuration:
  how many days the audit trail keeps an entry (`:audit_retention_days`) and the address
  and the client it came from (`:audit_address_retention_days`), the grace period before a
  deleted workspace or organisation is purged (`:deletion_grace_days`), and how many
  invitations an organisation makes in 24 hours (`:invitations_per_day`).

  **The value** of each (`value/1`) is, in order:

  1. the variable of the same name in the server's environment, `AUDIT_RETENTION_DAYS`,
     `AUDIT_ADDRESS_RETENTION_DAYS`, `DELETION_GRACE_DAYS` or `INVITATIONS_PER_DAY`, where
     it is set and not blank (`env/1`). `Apiary.Audit.boot!/0`, `Apiary.Deletion.boot!/0`
     and `Apiary.Instance.boot!/0` check it at boot, and keep it in the application's
     environment under the key of the same name, nil where it is not set; a test that
     puts the key sets the variable;
  2. else the value an instance admin saved (`stored/0`);
  3. else the default, what the variable unset gives: 90 days, 90 days, 30 days and 20.

  Two rules hold wherever a value comes from. The trail keeps an entry no longer than the
  edition's ceiling (`c:Apiary.Edition.audit_retention_max_days/0`, 90 days in the core),
  so a saved value above it, as after a change of edition, reads as the ceiling. An
  address is not kept longer than its entry: the address's value is never longer than the
  trail's, and its default is 90 days, or the trail's period when that is shorter.
  `source/1` says where a value comes from.

  **Where they are kept.** One column per setting in the instance's row of
  `instance_settings` (`Apiary.InstanceConfig.Row`), NULL for none saved. Each node keeps a copy
  (`Apiary.InstanceConfig.Cache`), read again over `Apiary.PubSub` after each save;
  without it, as in the tests, `stored/0` reads the row each time. A node whose migration
  of these columns has not run yet, with `MIGRATE_ON_BOOT=false`, reads them as none saved.

  **Saving** (`save/3`) is an instance admin's, after a recent sign-in
  (`authorize_save/1`), one part of the page at a time (`fields/1`): `:retention`,
  `:deletion` or `:invitations`. It saves only the settings of the part that the
  environment does not set. A change of a value is an `instance.configure` entry in the
  trail of the instance's organisation, by the admin, with the values before and after.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query

  alias Apiary.{Access, Accounts, Audit, Deletion, Instance, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Dispatches.MachineLogs
  alias Apiary.InstanceConfig.{Cache, Row}
  alias Apiary.Organisations.Organisation
  alias ApiaryWeb.Format

  # A fifth setting, which the documentation and the page leave out, as they leave out the
  # `factory` feature: `:machine_log_retention_days`, how many days a dispatch's machine
  # log is kept, `MACHINE_LOG_RETENTION_DAYS` checked by
  # `Apiary.Dispatches.MachineLogs.boot!/0`, saved in the column of the same name, 30 days
  # by default, from `Apiary.Dispatches.MachineLogs.retention_min_days/0` to
  # `Apiary.Dispatches.MachineLogs.retention_max_days/0` days, its part `:machine_logs`.
  @keys [
    :audit_retention_days,
    :audit_address_retention_days,
    :deletion_grace_days,
    :invitations_per_day,
    :machine_log_retention_days
  ]

  @parts %{
    retention: [:audit_retention_days, :audit_address_retention_days],
    deletion: [:deletion_grace_days],
    invitations: [:invitations_per_day],
    machine_logs: [:machine_log_retention_days]
  }

  # The most invitations a day a save takes: the column is a 32-bit integer.
  @invitations_max 1_000_000

  # The messages name their bounds through bindings: a message built at compile time could
  # not be extracted for the catalogue.
  @days_message dgettext_noop(
                  "errors",
                  "must be between %{min} and %{max} days, or empty for the default"
                )
  @longer_message dgettext_noop(
                    "errors",
                    "cannot be longer than the audit log entries are kept: %{days}"
                  )
  @shorter_message dgettext_noop(
                     "errors",
                     "cannot be shorter than the IP addresses are kept: %{days}"
                   )
  @invitations_message dgettext_noop(
                         "errors",
                         "must be a whole number from 1 to %{max}, or empty for the default"
                       )

  @typedoc "A setting of Instance settings › Configuration."
  @type key ::
          :audit_retention_days
          | :audit_address_retention_days
          | :deletion_grace_days
          | :invitations_per_day
          | :machine_log_retention_days

  @typedoc "A part of Instance settings › Configuration, which is saved at once."
  @type part :: :retention | :deletion | :invitations | :machine_logs

  @typedoc "Where a value comes from."
  @type source :: :env | :saved | :default

  @typedoc "The saved settings, each nil where none is saved."
  @type stored :: %{key => pos_integer | nil}

  @doc "keys/0 is the settings, in the order of the page."
  @spec keys() :: [key]
  def keys, do: @keys

  @doc """
  fields/1 is the settings of `part`: `:retention`, the trail's two periods; `:deletion`,
  the grace period; `:invitations`, the invitations a day.
  """
  @spec fields(part) :: [key]
  def fields(part), do: Map.fetch!(@parts, part)

  @doc """
  invitations_max/0 is the most invitations a day a save takes, #{@invitations_max}; the
  variable takes any whole number from 1.
  """
  @spec invitations_max() :: pos_integer
  def invitations_max, do: @invitations_max

  ## Reading

  @doc """
  value/1 is the value of `key`: the environment's, else the saved one, else the
  default, by the rules of the module's documentation. Reads no saved setting where the
  environment sets what the value depends on.
  """
  @spec value(key) :: pos_integer
  def value(key) when key in @keys do
    stored = if Enum.all?(depends_on(key), &env/1), do: %{}, else: stored()
    effective(key, stored)
  end

  @doc """
  values/1 is the value of each key, given the saved settings `stored` (`load/0`), as
  `value/1` reads them.
  """
  @spec values(stored) :: %{key => pos_integer}
  def values(stored) when is_map(stored), do: Map.new(@keys, &{&1, effective(&1, stored)})

  @doc """
  source/1 is where the value of `key` comes from: `:env`, the server's environment sets
  it; `:saved`, an instance admin saved it; `:default`, neither.
  """
  @spec source(key) :: source
  def source(key) when key in @keys do
    cond do
      env(key) -> :env
      stored()[key] -> :saved
      true -> :default
    end
  end

  @doc """
  env/1 is the value of `key` the server's environment sets, as its owner's `boot!/0`
  checked it, or nil where the variable is not set, or is blank. Where no boot has kept it,
  as under `bin/apiary eval`, it asks that `boot!/0` now.
  """
  @spec env(key) :: pos_integer | nil
  def env(key) when key in @keys do
    value =
      case Application.fetch_env(:apiary, key) do
        {:ok, value} ->
          value

        :error ->
          boot(key)
          Application.get_env(:apiary, key)
      end

    if is_integer(value), do: value
  end

  defp boot(key) when key in [:audit_retention_days, :audit_address_retention_days],
    do: Audit.boot!()

  defp boot(:deletion_grace_days), do: Deletion.boot!()
  defp boot(:invitations_per_day), do: Instance.boot!()
  defp boot(:machine_log_retention_days), do: MachineLogs.boot!()

  @doc """
  stored/0 is the saved settings, as this node's `Apiary.InstanceConfig.Cache` holds them,
  or as the database has them now where no cache runs.
  """
  @spec stored() :: stored
  def stored do
    case Cache.cached() do
      {:ok, stored} -> stored
      :error -> load()
    end
  end

  @doc """
  load/0 is the saved settings as the database has them now: each nil where none is
  saved, where there is no row, and on a schema whose migration of these settings has not
  run yet.
  """
  @spec load() :: stored
  def load, do: row() |> to_stored()

  defp row do
    Repo.get(Row, true)
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :undefined_column} -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  # The instance's registry name, with the `registry` feature: 16 random lower-case hex
  # digits, the first segment of the instance's image names (`Apiary.Registry.Names`).
  # Made once, by the first call on an instance whose row has none, in one statement that
  # keeps a name the row holds, so two nodes at once record one name. Never derived from
  # `PUBLIC_URL`, so a change of address keeps the names. A boot with the feature on makes
  # it and keeps it for the life of the node (`Apiary.Registry.InstanceName`).
  @registry_instance """
  INSERT INTO instance_settings (id, registry_instance, updated_at)
  VALUES (true, $1, $2)
  ON CONFLICT (id) DO UPDATE SET
    registry_instance = COALESCE(instance_settings.registry_instance, EXCLUDED.registry_instance)
  RETURNING registry_instance
  """

  @doc false
  # registry_instance/0 is the instance's registry name: the node's copy, else the row's,
  # made now where the row has none, and kept as the node's copy from then on where the
  # node keeps one (`Apiary.Registry.InstanceName.keeps?/0`), so the row is written once
  # per node; nil on a schema whose migration of the name has not run yet.
  @spec registry_instance() :: String.t() | nil
  def registry_instance do
    case Application.fetch_env(:apiary, :registry_instance) do
      {:ok, name} when is_binary(name) -> name
      _none -> record_registry_instance() |> kept_registry_instance()
    end
  end

  defp kept_registry_instance(name) when is_binary(name) do
    if Apiary.Registry.InstanceName.keeps?(),
      do: Application.put_env(:apiary, :registry_instance, name)

    name
  end

  defp kept_registry_instance(nil), do: nil

  @doc false
  # read_registry_instance/0 is the instance's registry name as it is: the node's copy,
  # else the row's, nil where none is made yet and on a schema without it. A read, with
  # no write: what a claim, a page and a check of an image's place ask.
  @spec read_registry_instance() :: String.t() | nil
  def read_registry_instance do
    case Application.fetch_env(:apiary, :registry_instance) do
      {:ok, name} when is_binary(name) -> name
      _none -> Repo.one(from s in "instance_settings", select: s.registry_instance)
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:undefined_column, :undefined_table] -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  @doc false
  # record_registry_instance/0 makes the instance's registry name where the row has none,
  # and returns the row's; nil on a schema whose migration of the name has not run yet,
  # as `load/0` reads such a schema.
  @spec record_registry_instance() :: String.t() | nil
  def record_registry_instance do
    name = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %{rows: [[recorded]]} =
      Repo.query!(@registry_instance, [name, DateTime.utc_now()])

    recorded
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:undefined_column, :undefined_table] -> nil
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp to_stored(nil), do: Map.new(@keys, &{&1, nil})
  defp to_stored(%Row{} = row), do: Map.take(row, @keys)

  # The settings the value of a key reads.
  defp depends_on(:audit_address_retention_days),
    do: [:audit_retention_days, :audit_address_retention_days]

  defp depends_on(key), do: [key]

  defp effective(:audit_retention_days = key, stored) do
    days = env(key) || stored[key] || default(key)
    min(days, Apiary.Edition.audit_retention_max_days())
  end

  defp effective(:audit_address_retention_days = key, stored) do
    retention = effective(:audit_retention_days, stored)
    {:ok, default} = Audit.parse_address_retention_days(nil, retention)
    min(env(key) || stored[key] || default, retention)
  end

  defp effective(key, stored), do: env(key) || stored[key] || default(key)

  # The default of each setting is what its variable unset gives.
  defp default(:audit_retention_days), do: ok!(Audit.parse_retention_days(nil))
  defp default(:deletion_grace_days), do: ok!(Deletion.parse_grace_days(nil))
  defp default(:invitations_per_day), do: ok!(Instance.parse_invitations_per_day(nil))

  defp default(:machine_log_retention_days),
    do: ok!(MachineLogs.parse_retention_days(nil))

  defp ok!({:ok, value}), do: value

  ## Saving

  @doc """
  authorize_save/1 is whether the person of `scope` may save: `:ok` for an instance admin
  (`Apiary.Access.instance_admin?/1`) who signed in recently
  (`Apiary.Accounts.sudo_mode?/2`); `{:error, :sudo}` for one who did not, who signs in
  again first; `{:error, :forbidden}` for anyone else.
  """
  @spec authorize_save(Scope.t() | nil) :: :ok | {:error, :forbidden | :sudo}
  def authorize_save(%Scope{user: %User{} = user} = scope) do
    cond do
      not Access.instance_admin?(scope) -> {:error, :forbidden}
      not Accounts.sudo_mode?(user) -> {:error, :sudo}
      true -> :ok
    end
  end

  def authorize_save(_scope), do: {:error, :forbidden}

  @doc """
  save/3 saves the settings of `part` (`fields/1`) that `attrs` gives, by their names, for
  the person of `scope`, once `authorize_save/1` lets them. A setting the environment sets
  is left as it is, whatever `attrs` says. Each value is trimmed; an empty one is none
  saved, so the default applies. The bounds:

  - the trail's period, from `Apiary.Audit.retention_min_days/0` days to the edition's
    ceiling, and not shorter than the address's period where
    `AUDIT_ADDRESS_RETENTION_DAYS` sets it;
  - the address's period, from 1 day, and not longer than the trail's period, the one
    saved with it, or the environment's;
  - the grace period, from `Apiary.Deletion.grace_min_days/0` to
    `Apiary.Deletion.grace_max_days/0` days;
  - the invitations a day, from 1 to #{@invitations_max}.

  The row is made where there is none yet, empty; past that, it is written only where a
  saved value changed, and never its `updated_by_id`, which is the product's name's. A
  change of a value is an `instance.configure` entry in the trail of the instance's
  organisation, by the admin, about the organisation, with the values of the part before
  and after, as `value/1` reads them; a save that changes no value, as one that saves the
  default's number in place of none, has none. Once
  committed, every node's cache reads the settings again.

  Returns `{:ok, values}`, the value of each key after the save (`values/1`);
  `{:error, changeset}`; `{:error, :sudo}`; or `{:error, :forbidden}`.
  """
  @spec save(Scope.t() | nil, part, map) ::
          {:ok, %{key => pos_integer}} | {:error, Ecto.Changeset.t() | :sudo | :forbidden}
  def save(scope, part, attrs) when is_map_key(@parts, part) and is_map(attrs) do
    with :ok <- authorize_save(scope), do: write(scope, part, attrs)
  end

  defp write(scope, part, attrs) do
    Repo.transact(fn ->
      current = lock_row()
      before = to_stored(current)
      changeset = changeset(current, part, attrs, before)

      with true <- changeset.valid? || {:error, %{changeset | action: :update}},
           {:ok, organisation} <- instance_organisation(),
           {:ok, row} <- write_row(changeset, current),
           after_save = to_stored(row),
           :ok <- record(scope, organisation, part, before, after_save) do
        {:ok, values(after_save)}
      end
    end)
    |> case do
      {:ok, values} ->
        Cache.changed()
        {:ok, values}

      {:error, _reason} = error ->
        error
    end
  end

  # The row, locked for the save, made where there is none yet.
  defp lock_row do
    Repo.insert_all("instance_settings", [%{id: true, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: :id
    )

    Repo.one!(from r in Row, where: r.id == true, lock: "FOR UPDATE")
  end

  # Writes the row where a saved value changed; a save of the same values writes nothing.
  defp write_row(changeset, current) do
    if changeset.changes == %{},
      do: {:ok, current},
      else: changeset |> Ecto.Changeset.change(updated_at: DateTime.utc_now()) |> Repo.update()
  end

  # The trail's entry of a change of value; a save that changes none has none.
  defp record(scope, organisation, part, before, after_save) do
    case Audit.changed(values(before), values(after_save), fields(part)) do
      nil ->
        :ok

      changes ->
        with {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, organisation),
                 :"instance.configure",
                 organisation,
                 changes
               ),
             do: :ok
    end
  end

  # The instance's organisation, whose trail holds the entry; its owners are the
  # instance's admins.
  defp instance_organisation do
    with id when is_binary(id) <- Apiary.Edition.instance_organisation_id(),
         %Organisation{} = organisation <- Repo.get(Organisation, id) do
      {:ok, organisation}
    else
      _none -> {:error, :forbidden}
    end
  end

  ## The changeset

  # What the save casts: the settings of the part that the environment does not set, each
  # trimmed, checked against the saved settings `current` where the part's other setting
  # is not cast.
  defp changeset(%Row{} = row, part, attrs, current) do
    fields = Enum.reject(fields(part), &env/1)

    row
    |> Ecto.Changeset.cast(trim(attrs), fields)
    |> validate(part, fields, current)
    |> Ecto.Changeset.check_constraint(:audit_retention_days,
      name: :instance_settings_audit_retention_days_check
    )
    |> Ecto.Changeset.check_constraint(:audit_address_retention_days,
      name: :instance_settings_audit_address_retention_days_check
    )
    |> Ecto.Changeset.check_constraint(:deletion_grace_days,
      name: :instance_settings_deletion_grace_days_check
    )
    |> Ecto.Changeset.check_constraint(:invitations_per_day,
      name: :instance_settings_invitations_per_day_check
    )
    |> Ecto.Changeset.check_constraint(:machine_log_retention_days,
      name: :instance_settings_machine_log_retention_days_check
    )
  end

  defp trim(attrs),
    do: Map.new(attrs, fn {k, v} -> {k, if(is_binary(v), do: String.trim(v), else: v)} end)

  defp validate(changeset, :retention, fields, current) do
    ceiling = Apiary.Edition.audit_retention_max_days()
    min = Audit.retention_min_days()

    changeset =
      validate_range(changeset, fields, :audit_retention_days, @days_message, min, ceiling,
        min: Format.number(min),
        max: Format.number(ceiling)
      )

    # The trail's period after the save, its default and the ceiling applied; nil where
    # what was typed for it is refused.
    retention =
      unless error?(changeset, :audit_retention_days) do
        effective(:audit_retention_days, saved(changeset))
      end

    changeset
    |> validate_address(fields, retention || effective(:audit_retention_days, current))
    |> validate_longer_address(fields, retention)
    |> validate_shorter_retention(fields, retention)
  end

  defp validate(changeset, :deletion, fields, _current) do
    {min, max} = {Deletion.grace_min_days(), Deletion.grace_max_days()}

    validate_range(changeset, fields, :deletion_grace_days, @days_message, min, max,
      min: Format.number(min),
      max: Format.number(max)
    )
  end

  defp validate(changeset, :invitations, fields, _current) do
    validate_range(
      changeset,
      fields,
      :invitations_per_day,
      @invitations_message,
      1,
      @invitations_max,
      max: Format.number(@invitations_max)
    )
  end

  defp validate(changeset, :machine_logs, fields, _current) do
    {min, max} = {MachineLogs.retention_min_days(), MachineLogs.retention_max_days()}

    validate_range(changeset, fields, :machine_log_retention_days, @days_message, min, max,
      min: Format.number(min),
      max: Format.number(max)
    )
  end

  # The address's period: a whole number from 1, which names the trail's period as its
  # bound. Longer than the trail's is `validate_longer_address/3`'s.
  defp validate_address(changeset, fields, retention) do
    validate_range(changeset, fields, :audit_address_retention_days, @days_message, 1, nil,
      min: Format.number(1),
      max: Format.number(retention)
    )
  end

  defp validate_longer_address(changeset, fields, retention) do
    field = :audit_address_retention_days
    days = Ecto.Changeset.get_field(changeset, field)

    if field in fields and is_integer(retention) and is_integer(days) and days > retention and
         not error?(changeset, field),
       do: Ecto.Changeset.add_error(changeset, field, @longer_message, days: days(retention)),
       else: changeset
  end

  # Where `AUDIT_ADDRESS_RETENTION_DAYS` sets the address's period, the trail's is not
  # shorter: the page could not show the variable's value beside it otherwise.
  defp validate_shorter_retention(changeset, fields, retention) do
    address = env(:audit_address_retention_days)

    if :audit_retention_days in fields and is_integer(retention) and is_integer(address) and
         retention < address,
       do:
         Ecto.Changeset.add_error(changeset, :audit_retention_days, @shorter_message,
           days: days(address)
         ),
       else: changeset
  end

  # A value cast is a whole number from `min` to `max`, nil for no upper bound; one that is
  # not a whole number says the same as one out of range, with `bounds` for its message.
  defp validate_range(changeset, fields, field, message, min, max, bounds) do
    cond do
      field not in fields ->
        changeset

      error?(changeset, field) ->
        errors =
          Enum.map(changeset.errors, fn
            {^field, {_message, meta}} -> {field, {message, Keyword.merge(meta, bounds)}}
            other -> other
          end)

        %{changeset | errors: errors}

      true ->
        case Ecto.Changeset.get_field(changeset, field) do
          value when is_integer(value) and (value < min or (is_integer(max) and value > max)) ->
            Ecto.Changeset.add_error(changeset, field, message, bounds)

          _valid_or_none ->
            changeset
        end
    end
  end

  defp error?(changeset, field), do: Keyword.has_key?(changeset.errors, field)

  defp saved(changeset), do: changeset |> Ecto.Changeset.apply_changes() |> to_stored()

  defp days(n), do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))
end
