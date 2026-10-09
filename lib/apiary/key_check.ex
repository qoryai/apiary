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
  value is recorded on a database that has access keys, the newest key's integrity code
  must be under the secret's key id (`Apiary.AccessKeys.AccessKey.verify_integrity/1`),
  so a wrong secret is never recorded as the right one. Then each recorded value is
  compared with the current one, and a mismatch stops the boot with a message in the log
  for each key that does not match (`encryption_message/0`, `signing_message/2`). A
  message names the variable and, for the signing key, the two fingerprints; never a
  secret, a key or the check value.

  The recording is one statement that keeps a value the row holds already, and answers
  the values the row holds after it: two instances booting at once on an empty row record
  one pair, the first to write, and the other compares its own against it. On a schema
  without the two columns, the migration of this release not yet run, the check records
  and compares nothing.

  **A change on purpose.** A new signing key means pinning every machine again;
  `Apiary.Release.accept_signing_key/0` records its fingerprint (`accept_signing_key/0`),
  in a one-off container of the release, since a refused boot leaves none running. The
  encryption secret has no such command: it never changes once an access key exists.

  Off in test (`config :apiary, Apiary.KeyCheck, enabled: false`), where the tests call
  `check/0`.
  """

  import Ecto.Query

  require Logger

  alias Apiary.AccessKeys.AccessKey
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
            compare(recorded, check, fingerprint)

          is_nil(recorded_check) and not newest_access_key_verifies?() ->
            {:error, [encryption_message()]}

          true ->
            compare(record(check, fingerprint), check, fingerprint)
        end
    end
  end

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
    Put back the value kept with your backups. To change it on purpose, and pin every machine again, run in a one-off container of this release: bin/apiary eval 'Apiary.Release.accept_signing_key()'\
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

  # The newest access key, revoked or not, is the one most likely made under the secret
  # the instance runs with now. None at all is a database nothing can be checked against.
  # Only a key id that is not the secret's is a wrong secret: a mismatch under the row's
  # own key id proves the secret, and the request path still refuses that one key.
  defp newest_access_key_verifies? do
    query = from(k in AccessKey, order_by: [desc: k.inserted_at, desc: k.id], limit: 1)

    case Repo.one(query) do
      nil -> true
      key -> AccessKey.verify_integrity(key) != {:error, :unknown_key}
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
