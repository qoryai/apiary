defmodule Apiary.KeyCheck do
  @moduledoc """
  The check at boot that the instance runs with the keys it first started with, its
  `APIARY_ENCRYPTION_SECRET` and its `APIARY_SIGNING_SECRET`, so that a boot with another
  stops instead of serving: with another encryption secret no access key would verify and
  no stored secret could be read, and with another signing secret every machine would
  refuse its answers.

  **What is recorded.** Two values, in the instance's own row of `instance_settings`:

    * `encryption_secret_check`, the check value of `APIARY_ENCRYPTION_SECRET`
      (`check_value/0`): HMAC-SHA256 of the label `#{inspect("apiary key check v1")}` under
      the key `Apiary.KeyDerivation` derives for the purpose `:check`, 32 bytes. It tells
      whether the secret is the same, and nothing of the secret or of any other key
      derived from it;
    * `signing_key_fingerprint`, the fingerprint of the signing key's public half
      (`Apiary.SigningKey.fingerprint/0`), 22 characters, public by design: it is what
      every machine pins.

  **At boot.** `check/0` runs once the migrations have run: this module is the child of the
  application's supervisor after `Apiary.Release.Migrator`, and it runs with
  `MIGRATE_ON_BOOT=false` too, where `bin/migrate` has run before the start. A value the
  row does not hold yet is recorded, so the first boot records both. Before the check
  value is recorded on a database that holds data, the oldest row with a key id derived
  from `APIARY_ENCRYPTION_SECRET`, across the tables that hold one (`key_id_columns/0`),
  must carry the current secret's key id. The instance holds one secret at a time, so a
  database it ran on with one secret holds no other key id; where a boot without this
  check, before its migration ran, added rows under another secret, the oldest row is
  still the first secret's, unless that boot changed it. So a wrong secret is not
  recorded as the right one, nor the right one refused for rows a wrong one added; a
  database with no such row records the secret it is given. Then each recorded value is
  compared with the current one, and a mismatch stops the boot with a message in the log
  for each key that does not match (`encryption_message/0`, `signing_message/2`). A
  message names the variable and, for the signing key, the two fingerprints; never a
  secret, a key or the check value.

  The recording is one statement that keeps a value the row holds already, and answers
  the values the row holds after it: two instances booting at once on an empty row record
  one pair, the first to write, and the other compares its own against it. On a schema
  without the two columns, the migration of this release not yet run, the check records
  and compares nothing.

  **A change on purpose.** A new signing key means pinning every machine again. Its
  fingerprint, the one the refusal names as the key's, set in
  `APIARY_ACCEPT_SIGNING_FINGERPRINT` (read by `config/runtime.exs`, trimmed) makes it the
  instance's at the next boot: where the recorded fingerprint is another and the variable
  equals the current key's, compared in constant time, the boot records it, logs
  `accepted_message/1` and goes on. Any other value changes nothing, and the boot stops as
  without it; the value is never written out. It names one key, so a value left set
  accepts no later key, and needs no reset. It is read only while the encryption secret's
  check value matches: it never takes a boot past that check, nor records a fingerprint on
  a boot that check refuses. The encryption secret has no such variable: it never changes
  once an access key exists. `Apiary.Release.accept_signing_key/0` records the current
  fingerprint too (`accept_signing_key/0`), in a one-off container of the release.

  Off in test (`config :apiary, Apiary.KeyCheck, enabled: false`), where the tests call
  `check/0`.
  """

  import Ecto.Query

  require Logger

  alias Apiary.{KeyDerivation, Repo, SigningKey}

  @label "apiary key check v1"

  # Keeps a value the row holds, so the first to record wins a race on an empty row, and
  # answers what the row holds after the statement.
  @record """
  INSERT INTO instance_settings (id, encryption_secret_check, signing_key_fingerprint, updated_at)
  VALUES (true, $1, $2, $3)
  ON CONFLICT (id) DO UPDATE SET
    encryption_secret_check =
      COALESCE(instance_settings.encryption_secret_check, EXCLUDED.encryption_secret_check),
    signing_key_fingerprint =
      COALESCE(instance_settings.signing_key_fingerprint, EXCLUDED.signing_key_fingerprint)
  RETURNING encryption_secret_check, signing_key_fingerprint
  """

  # Each column that stores a key id derived from APIARY_ENCRYPTION_SECRET, with its table
  # and the purpose of the key it names (`Apiary.KeyDerivation`). The check's migration
  # comes after every table but `instance_settings`' mail columns, which a later migration
  # adds: a table or column the schema does not have yet holds no key id
  # (`oldest_key_id/1`).
  @key_id_columns [
    {"access_keys", :integrity_key_id, :integrity},
    {"access_key_enrolment_codes", :integrity_key_id, :integrity},
    {"integration_releases", :integrity_key_id, :integrity},
    {"service_definitions", :integrity_key_id, :integrity},
    {"workspace_connections", :integrity_key_id, :integrity},
    {"workspace_data_keys", :wrapping_key_id, :values},
    {"instance_settings", :mail_key_id, :mail}
  ]

  # The column that says when a table's key id was written, where it is not `inserted_at`:
  # the instance's one row of settings has none, and its SMTP password is written when the
  # mail settings are saved.
  @made_at %{"instance_settings" => :mail_saved_at}

  @accept """
  INSERT INTO instance_settings (id, signing_key_fingerprint, updated_at)
  VALUES (true, $1, $2)
  ON CONFLICT (id) DO UPDATE SET signing_key_fingerprint = EXCLUDED.signing_key_fingerprint
  """

  @doc "Starts once, as a worker the supervisor does not restart."
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Runs `check/0`. Returns `:ignore` when the keys match, so nothing stays in the
  supervision tree; otherwise logs each message and exits, which takes the boot down.
  """
  @spec start_link() :: :ignore
  def start_link do
    case check() do
      :ok ->
        :ignore

      {:error, messages} ->
        Enum.each(messages, &Logger.error/1)
        exit(:key_check_failed)
    end
  end

  @doc "enabled?/0 is whether the application runs the check at boot: true unless configured off."
  @spec enabled?() :: boolean
  def enabled?, do: Keyword.get(Application.get_env(:apiary, __MODULE__, []), :enabled, true)

  @doc """
  check/0 records what the instance's row does not hold yet and compares both values
  with the current keys: `:ok`, or `{:error, messages}`, one message for each key that
  does not match. See the module's documentation.
  """
  @spec check() :: :ok | {:error, [String.t(), ...]}
  def check do
    case recorded() do
      :no_columns ->
        :ok

      {recorded_check, recorded_fingerprint} = recorded ->
        check = check_value()
        fingerprint = SigningKey.fingerprint()

        cond do
          is_binary(recorded_check) and is_binary(recorded_fingerprint) ->
            recorded |> accept_named(check, fingerprint) |> compare(check, fingerprint)

          is_nil(recorded_check) and not oldest_data_under_secret?() ->
            {:error, [encryption_message()]}

          true ->
            check
            |> record(fingerprint)
            |> accept_named(check, fingerprint)
            |> compare(check, fingerprint)
        end
    end
  end

  @doc """
  key_id_columns/0 is each column that stores a key id derived from
  `APIARY_ENCRYPTION_SECRET`: `{table, column, purpose}`, the purpose of the key it names
  (`Apiary.KeyDerivation`). The check reads them before it records the check value.
  """
  @spec key_id_columns() :: [{String.t(), atom, KeyDerivation.purpose()}, ...]
  def key_id_columns, do: @key_id_columns

  @doc """
  made_at_column/1 is the column of `table`, one of `key_id_columns/0`'s, that says when
  its row's key id was written, which the check orders the rows by: `inserted_at`, and
  `mail_saved_at` for `instance_settings`, whose one row the mail settings' save writes.
  """
  @spec made_at_column(String.t()) :: atom
  def made_at_column(table), do: Map.get(@made_at, table, :inserted_at)

  @doc """
  check_value/0 is the check value of the current `APIARY_ENCRYPTION_SECRET`: HMAC-SHA256
  of `#{inspect(@label)}` under the key `Apiary.KeyDerivation` derives for `:check`, 32
  bytes.
  """
  @spec check_value() :: <<_::256>>
  def check_value do
    {_key_id, key} = KeyDerivation.key(:check)
    :crypto.mac(:hmac, :sha256, key, @label)
  end

  @doc """
  accept_signing_key/0 records the fingerprint of the current signing key as the
  instance's, in place of the one recorded, and returns it. The key is checked as at
  boot first (`Apiary.SigningKey.boot!/0`), so a key the boot refuses is never recorded.
  The check of the encryption secret is left as it is.
  """
  @spec accept_signing_key() :: String.t()
  def accept_signing_key do
    :ok = SigningKey.boot!()
    fingerprint = SigningKey.fingerprint()
    Repo.query!(@accept, [fingerprint, NaiveDateTime.utc_now()])
    fingerprint
  end

  @doc """
  accepted_message/1 is what the log says when `APIARY_ACCEPT_SIGNING_FINGERPRINT` made the
  signing key with `fingerprint` the instance's, as `Apiary.Release.accept_signing_key/0`
  says it.
  """
  @spec accepted_message(String.t()) :: String.t()
  def accepted_message(fingerprint) do
    "The signing key with fingerprint #{fingerprint} is now the instance's. " <>
      "Pin it on every machine again."
  end

  @doc "encryption_message/0 is what the log says when `APIARY_ENCRYPTION_SECRET` does not match."
  @spec encryption_message() :: String.t()
  def encryption_message do
    """
    APIARY_ENCRYPTION_SECRET is not the one this instance first started with.
    Put back the value kept with your backups (Backup and restore, at /docs). Qory does not start with another: no access key would verify, and no stored secret could be read.\
    """
  end

  @doc """
  signing_message/2 is what the log says when `APIARY_SIGNING_SECRET` does not match:
  `fingerprint` is the current key's, `recorded` the one the instance recorded.
  """
  @spec signing_message(String.t(), String.t()) :: String.t()
  def signing_message(fingerprint, recorded) do
    """
    APIARY_SIGNING_SECRET is not the one this instance's machines pinned: its key's fingerprint is #{fingerprint}, the pinned one is #{recorded}.
    Put back the value kept with your backups. To change it on purpose, and pin every machine again, set APIARY_ACCEPT_SIGNING_FINGERPRINT=#{fingerprint} and start Qory Apiary again.\
    """
  end

  # What the row holds, `{nil, nil}` when there is no row yet, or `:no_columns` on a
  # schema this release's migration has not reached.
  defp recorded do
    query =
      from(s in "instance_settings",
        select: {s.encryption_secret_check, s.signing_key_fingerprint}
      )

    Repo.one(query) || {nil, nil}
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:undefined_column, :undefined_table] -> :no_columns
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp record(check, fingerprint) do
    %{rows: [[recorded_check, recorded_fingerprint]]} =
      Repo.query!(@record, [check, fingerprint, NaiveDateTime.utc_now()])

    {recorded_check, recorded_fingerprint}
  end

  # Whether the oldest row with a key id, across `@key_id_columns`, carries the current
  # secret's key id for its purpose; true when no row has one. One query per table, for
  # its oldest row, and only until the check value is recorded. Not the newest row, which
  # a boot without this check may have written under a wrong secret; nor any row that
  # differs, which would refuse the right secret on such a database with a message not
  # true of it. Only the key id is compared, not the code: a changed row under the
  # secret's own key id proves the secret, and the request path still refuses that row.
  defp oldest_data_under_secret? do
    case Enum.flat_map(@key_id_columns, &oldest_key_id/1) do
      [] ->
        true

      oldest_per_table ->
        {_inserted_at, key_id, purpose} =
          Enum.min_by(oldest_per_table, &elem(&1, 0), NaiveDateTime)

        {current, _key} = KeyDerivation.key(purpose)
        key_id == current
    end
  end

  # The oldest row's time and key id, none for a table without one, nor for a column the
  # schema does not have yet (its migration not yet run): it holds no key id.
  defp oldest_key_id({table, column, purpose}) do
    made_at = made_at_column(table)

    query =
      from(t in table,
        where: not is_nil(field(t, ^column)),
        order_by: [asc: field(t, ^made_at), asc: t.id],
        limit: 1,
        select: {field(t, ^made_at), field(t, ^column)}
      )

    for {made_at, key_id} <- Repo.all(query), do: {made_at, key_id, purpose}
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:undefined_column, :undefined_table] -> []
        _other -> reraise error, __STACKTRACE__
      end
  end

  # The signing key `APIARY_ACCEPT_SIGNING_FINGERPRINT` names, recorded as the instance's
  # when it is the current key and the recorded fingerprint is another: the pair the row
  # holds after. Only while the encryption secret's check value matches, so the variable
  # never takes a boot past that check, nor records a fingerprint on a boot it refuses.
  # The value is compared with the current fingerprint alone, in constant time, and never
  # written out: should it hold a secret by mistake, the log does not carry it.
  defp accept_named({recorded_check, recorded_fingerprint} = recorded, check, fingerprint) do
    if recorded_fingerprint != fingerprint and same_check?(recorded_check, check) and
         named?(fingerprint) do
      Repo.query!(@accept, [fingerprint, NaiveDateTime.utc_now()])
      Logger.warning(accepted_message(fingerprint))
      {recorded_check, fingerprint}
    else
      recorded
    end
  end

  defp named?(fingerprint) do
    case Application.get_env(:apiary, :accept_signing_fingerprint_setting) do
      value when is_binary(value) ->
        named = String.trim(value)
        byte_size(named) == byte_size(fingerprint) and :crypto.hash_equals(named, fingerprint)

      _unset ->
        false
    end
  end

  defp compare({recorded_check, recorded_fingerprint}, check, fingerprint) do
    messages =
      Enum.reject(
        [
          if(not same_check?(recorded_check, check), do: encryption_message()),
          if(recorded_fingerprint != fingerprint,
            do: signing_message(fingerprint, recorded_fingerprint)
          )
        ],
        &is_nil/1
      )

    if messages == [], do: :ok, else: {:error, messages}
  end

  defp same_check?(recorded, check),
    do: byte_size(recorded) == byte_size(check) and :crypto.hash_equals(recorded, check)
end
