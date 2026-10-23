defmodule Apiary.Repo.Migrations.LetARunTakeARunCode do
  use Ecto.Migration

  # A run handed over with a run code (`Apiary.Runs.RunCode`): its handover answers a `qecr_`
  # code in place of the run key, and the machine redeems the code once at enrolment for
  # the run key. On the run's row of `runs`:
  #
  # - `run_code_sha256`, the SHA-256 of the code, 32 bytes, unique
  #   (`20261022140200_index_a_run_s_run_code`);
  # - `run_code_expires_at`, 15 minutes after the handover;
  # - `run_code_grant`, what the run key will grant, fixed at the handover: the run's id,
  #   its workspace, its node pool, its gateway, the gateway's address and keys, and its
  #   instance id;
  # - `run_code_public_key`, the 32 bytes of the public key that redeemed the code first.
  #
  # Until the code is redeemed, such a run has no run key payload: its `run_key_issued_at`
  # is the handover and its `attach_by` the code's expiry. Its redemption writes the
  # payload, the signature, `run_key_issued_at` and `attach_by`, and the public key, in
  # one write: a run with a code has a payload exactly when it has a public key. All NULL
  # for every other run, every existing row among them.
  #
  # `runs_run_key_check` and `runs_registration_check` take such a run as they take a run
  # with a run key. The checks are added NOT VALID, so adding them takes no scan of the
  # table under its lock; the next migration validates them.
  @registration_columns ~w(registered_at registration_labels registration_about
                            registration_digest)

  def up do
    alter table(:runs) do
      add :run_code_sha256, :binary
      add :run_code_expires_at, :utc_datetime_usec
      add :run_code_grant, :map
      add :run_code_public_key, :binary
    end

    drop constraint(:runs, :runs_registration_check)
    registration_check("run_key_payload IS NOT NULL OR run_code_sha256 IS NOT NULL")

    drop constraint(:runs, :runs_run_key_check)

    run_key_check(
      " AND run_code_sha256 IS NULL",
      " OR (run_key_payload IS NULL AND run_code_sha256 IS NOT NULL AND " <>
        "run_key_issued_at IS NOT NULL AND attach_by > run_key_issued_at AND " <>
        "registered_at IS NOT NULL)"
    )

    create constraint(:runs, :runs_run_code_check,
             check:
               "(run_code_sha256 IS NULL AND run_code_expires_at IS NULL AND " <>
                 "run_code_grant IS NULL AND run_code_public_key IS NULL) OR " <>
                 "(octet_length(run_code_sha256) = 32 AND run_code_expires_at IS NOT NULL AND " <>
                 "run_code_grant IS NOT NULL AND " <>
                 "(run_code_public_key IS NULL OR octet_length(run_code_public_key) = 32) AND " <>
                 "(run_code_public_key IS NULL) = (run_key_payload IS NULL))",
             validate: false
           )
  end

  # Rolled back, a run with a run code could not be held: refused while any is there.
  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM runs WHERE run_code_sha256 IS NOT NULL) THEN
        RAISE EXCEPTION 'runs has runs handed over with a run code: delete them before rolling this back';
      END IF;
    END
    $$
    """)

    drop constraint(:runs, :runs_run_code_check)
    drop constraint(:runs, :runs_run_key_check)
    drop constraint(:runs, :runs_registration_check)

    alter table(:runs) do
      remove :run_code_public_key
      remove :run_code_grant
      remove :run_code_expires_at
      remove :run_code_sha256
    end

    run_key_check("", "")
    registration_check("run_key_payload IS NOT NULL")
  end

  # A run that registered through a gateway carries no heartbeat interval and is given no
  # run configuration at its registration.
  defp registration_check(through_gateway) do
    create constraint(:runs, :runs_registration_check,
             check:
               "(#{all_null(@registration_columns)} AND registration_interval_seconds IS NULL " <>
                 "AND registration_answer_digest IS NULL) OR " <>
                 "(#{all_set(@registration_columns)} AND " <>
                 "((registration_interval_seconds IS NOT NULL AND " <>
                 "registration_answer_digest IS NOT NULL) OR " <>
                 "((#{through_gateway}) AND registration_interval_seconds IS NULL AND " <>
                 "registration_answer_digest IS NULL)))",
             validate: false
           )
  end

  # `without_code` is added to the branch of a direct run, `run_code` as a third branch.
  defp run_key_check(without_code, run_code) do
    create constraint(:runs, :runs_run_key_check,
             check:
               "(run_key_payload IS NULL AND run_key_issued_at IS NULL AND attach_by IS NULL " <>
                 "AND gateway_id IS NULL" <>
                 without_code <>
                 ") OR " <>
                 "(octet_length(run_key_payload) BETWEEN 1 AND 2048 AND " <>
                 "run_key_issued_at IS NOT NULL AND attach_by > run_key_issued_at AND " <>
                 "registered_at IS NOT NULL)" <> run_code,
             validate: false
           )
  end

  defp all_null(columns), do: Enum.map_join(columns, " AND ", &"#{&1} IS NULL")
  defp all_set(columns), do: Enum.map_join(columns, " AND ", &"#{&1} IS NOT NULL")
end
