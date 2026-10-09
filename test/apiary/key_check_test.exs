defmodule Apiary.KeyCheckTest do
  @moduledoc """
  The key check at boot (`Apiary.KeyCheck`): what the first boot records in
  `instance_settings`, the boot with the same keys, a boot with another encryption or
  signing secret, the command that accepts a new signing key
  (`Apiary.Release.accept_signing_key/0`), and the messages, which carry no secret.
  """
  # Not async: the keys are the application's configuration, set for a test and put back
  # after it.
  use Apiary.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{KeyCheck, KeyDerivation, Release, SigningKey}

  setup do
    derivation = Application.get_env(:apiary, KeyDerivation)
    signing = Application.get_env(:apiary, SigningKey)

    on_exit(fn ->
      Application.put_env(:apiary, KeyDerivation, derivation)
      Application.put_env(:apiary, SigningKey, signing)
    end)
  end

  defp encryption_secret(secret), do: Application.put_env(:apiary, KeyDerivation, secret: secret)
  defp signing_seed(seed), do: Application.put_env(:apiary, SigningKey, seed: seed)

  # What the instance's row holds, nil when it has none.
  defp recorded do
    Repo.one(
      from(s in "instance_settings",
        select: {s.encryption_secret_check, s.signing_key_fingerprint}
      )
    )
  end

  defp current, do: {KeyCheck.check_value(), SigningKey.fingerprint()}

  # The boot's child, as the application's supervisor starts it: `:ignore`, or the exit
  # that takes the boot down, with the log it wrote.
  defp boot do
    log =
      capture_log(fn ->
        result =
          try do
            KeyCheck.start_link()
          catch
            :exit, reason -> reason
          end

        send(self(), {:boot, result})
      end)

    assert_received {:boot, reason}
    {reason, log}
  end

  @encryption_message """
  APIARY_ENCRYPTION_SECRET is not the one this instance first started with.
  Put back the value kept with your backups (Backup and restore, at /docs). Qory does not start with another: no access key would verify, and no stored secret could be read.\
  """

  defp signing_message(new, recorded) do
    "APIARY_SIGNING_SECRET is not the one this instance's machines pinned: its key's " <>
      "fingerprint is #{new}, the pinned one is #{recorded}.\n" <>
      "Put back the value kept with your backups. To change it on purpose, and pin every " <>
      "machine again, run in a one-off container of this release: " <>
      "bin/apiary eval 'Apiary.Release.accept_signing_key()'"
  end

  test "the check value is HMAC-SHA256 of its label under the key derived for :check" do
    # The test secret's check value, computed outside the application with Python's hmac
    # and hashlib: HKDF-SHA256 (salt apiary/kdf/v1, info "apiary check v1"), then
    # HMAC-SHA256 of "apiary key check v1".
    assert Base.encode16(KeyCheck.check_value(), case: :lower) ==
             "f14fdd75975df9cce0cc14bee46ce35a63085a471c74bcc66b01b4ff976bc259"

    {_id, key} = KeyDerivation.key(:check)
    refute KeyCheck.check_value() == key
  end

  test "the first boot records both values" do
    assert recorded() == nil

    assert boot() == {:ignore, ""}
    assert recorded() == current()
    assert byte_size(KeyCheck.check_value()) == 32
    assert String.length(SigningKey.fingerprint()) == 22
  end

  test "the same keys start, and nothing is written again" do
    assert KeyCheck.check() == :ok
    Repo.query!("UPDATE instance_settings SET updated_at = '2026-01-01'")

    assert KeyCheck.check() == :ok
    assert boot() == {:ignore, ""}
    assert recorded() == current()

    assert %{rows: [[~N[2026-01-01 00:00:00.000000]]]} =
             Repo.query!("SELECT updated_at FROM instance_settings")
  end

  test "another encryption secret stops the boot with its message" do
    assert KeyCheck.check() == :ok
    first = recorded()

    encryption_secret(:crypto.strong_rand_bytes(32))

    assert KeyCheck.check() == {:error, [@encryption_message]}
    assert {:key_check_failed, log} = boot()
    assert log =~ @encryption_message
    refute log =~ "APIARY_SIGNING_SECRET"
    # Nothing recorded over the first.
    assert recorded() == first
  end

  test "another signing secret stops the boot with its message and both fingerprints" do
    assert KeyCheck.check() == :ok
    pinned = SigningKey.fingerprint()
    first = recorded()

    signing_seed(:crypto.strong_rand_bytes(32))
    new = SigningKey.fingerprint()
    refute new == pinned

    assert KeyCheck.check() == {:error, [signing_message(new, pinned)]}
    assert {:key_check_failed, log} = boot()
    assert log =~ signing_message(new, pinned)
    refute log =~ "APIARY_ENCRYPTION_SECRET"
    assert recorded() == first
  end

  test "both secrets changed: a message for each" do
    assert KeyCheck.check() == :ok
    pinned = SigningKey.fingerprint()

    encryption_secret(:crypto.strong_rand_bytes(32))
    signing_seed(:crypto.strong_rand_bytes(32))

    assert KeyCheck.check() ==
             {:error, [@encryption_message, signing_message(SigningKey.fingerprint(), pinned)]}
  end

  test "accept_signing_key/0 records the new fingerprint, and the next boot starts" do
    assert KeyCheck.check() == :ok
    {check, pinned} = recorded()

    signing_seed(:crypto.strong_rand_bytes(32))
    new = SigningKey.fingerprint()
    assert {:key_check_failed, _log} = boot()

    output = capture_io(fn -> assert Release.accept_signing_key() == {:ok, new} end)

    assert output ==
             "The signing key with fingerprint #{new} is now the instance's. " <>
               "Pin it on every machine again.\n"

    refute new == pinned
    # The encryption secret's check value is left as it was.
    assert recorded() == {check, new}
    assert boot() == {:ignore, ""}
  end

  test "accept_signing_key/0 leaves another encryption secret refused" do
    assert KeyCheck.check() == :ok
    encryption_secret(:crypto.strong_rand_bytes(32))

    capture_io(fn -> assert {:ok, _fingerprint} = Release.accept_signing_key() end)

    assert KeyCheck.check() == {:error, [@encryption_message]}
  end

  test "accept_signing_key/0 on an instance with no row records the fingerprint alone" do
    capture_io(fn -> assert {:ok, _fingerprint} = Release.accept_signing_key() end)
    assert recorded() == {nil, SigningKey.fingerprint()}

    # The next boot records the check value beside it.
    assert KeyCheck.check() == :ok
    assert recorded() == current()
  end

  describe "a database with access keys and no recorded values" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key} = access_key_fixture(scope)
      %{key: key}
    end

    test "booted with a wrong encryption secret, stops instead of recording" do
      encryption_secret(:crypto.strong_rand_bytes(32))

      assert KeyCheck.check() == {:error, [@encryption_message]}
      assert {:key_check_failed, log} = boot()
      assert log =~ @encryption_message
      assert recorded() == nil
    end

    test "with only the signing fingerprint recorded, still stops instead of recording" do
      capture_io(fn -> Release.accept_signing_key() end)
      encryption_secret(:crypto.strong_rand_bytes(32))

      assert KeyCheck.check() == {:error, [@encryption_message]}
      assert recorded() == {nil, SigningKey.fingerprint()}
    end

    test "booted with the secret its newest key was coded under, records", %{key: key} do
      # An older key, coded under another secret, is not the one asked.
      Repo.query!(
        "UPDATE access_keys SET inserted_at = inserted_at - interval '1 day' WHERE id = $1",
        [Ecto.UUID.dump!(key.id)]
      )

      encryption_secret(:crypto.strong_rand_bytes(32))
      %{scope: scope} = sign_up_fixture()
      access_key_fixture(scope)

      assert KeyCheck.check() == :ok
      assert recorded() == current()
    end
  end

  describe "two boots at once on an empty row" do
    # Outside the sandbox, on connections of their own, as two instances are: what they
    # write is committed, and taken away after.
    setup do
      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DELETE FROM instance_settings")
        end)
      end)
    end

    test "record one pair, the first to write, and the other compares its own against it" do
      other_check = :crypto.strong_rand_bytes(32)
      other_fingerprint = SigningKey.fingerprint(SigningKey.new(:crypto.strong_rand_bytes(32)))
      parent = self()

      # The first boot's record, held in its transaction until the second has read the
      # empty row and waits on it.
      first =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!(
                "INSERT INTO instance_settings " <>
                  "(id, encryption_secret_check, signing_key_fingerprint, updated_at) " <>
                  "VALUES (true, $1, $2, now())",
                [other_check, other_fingerprint]
              )

              send(parent, :recorded)
              receive do: (:commit -> :ok)
            end)
          end)
        end)

      assert_receive :recorded

      second =
        Task.async(fn -> Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &KeyCheck.check/0) end)

      wait_for_a_lock_wait()
      send(first.pid, :commit)
      Task.await(first)

      assert Task.await(second) ==
               {:error,
                [
                  @encryption_message,
                  signing_message(SigningKey.fingerprint(), other_fingerprint)
                ]}

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &recorded/0) ==
               {other_check, other_fingerprint}
    end
  end

  # Until a statement on this database waits on a lock another transaction holds.
  defp wait_for_a_lock_wait(tries \\ 500) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      waiting > 0 ->
        :ok

      tries == 0 ->
        flunk("the second boot never waited on the first one's record")

      true ->
        Process.sleep(10)
        wait_for_a_lock_wait(tries - 1)
    end
  end

  test "on a schema without the columns, nothing is checked" do
    # As with MIGRATE_ON_BOOT=false before bin/migrate has run this release's migration.
    Repo.query!("ALTER TABLE instance_settings DROP COLUMN signing_key_fingerprint")
    assert KeyCheck.check() == :ok
  end

  test "no message carries a secret, a key derived from one, or the check value" do
    encryption = :crypto.strong_rand_bytes(32)
    seed = :crypto.strong_rand_bytes(32)
    encryption_secret(encryption)
    signing_seed(seed)
    assert KeyCheck.check() == :ok
    {_id, check_key} = KeyDerivation.key(:check)
    check_value = KeyCheck.check_value()

    other_encryption = :crypto.strong_rand_bytes(32)
    other_seed = :crypto.strong_rand_bytes(32)
    encryption_secret(other_encryption)
    signing_seed(other_seed)
    {_id, other_check_key} = KeyDerivation.key(:check)

    assert {:error, messages} = KeyCheck.check()
    assert length(messages) == 2
    {:key_check_failed, log} = boot()
    output = capture_io(fn -> Release.accept_signing_key() end)

    material = [
      encryption,
      seed,
      other_encryption,
      other_seed,
      check_key,
      other_check_key,
      check_value,
      KeyCheck.check_value()
    ]

    for text <- [log, output | messages], value <- material do
      for encoded <- [
            value,
            Base.encode64(value),
            Base.encode64(value, padding: false),
            Base.url_encode64(value, padding: false),
            Base.encode16(value, case: :lower),
            Base.encode16(value, case: :upper)
          ] do
        refute String.contains?(text, encoded), "a message carries key material"
      end
    end
  end
end
