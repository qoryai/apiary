defmodule Apiary.Repo.Migrations.KeepARunSModelSettings do
  use Ecto.Migration

  # What a run of the queue keeps of its model choice (`Apiary.Dispatches.RunSettings`),
  # written once, in the transaction of its handover (`Apiary.Dispatches.Handover`):
  #
  # - `runs.run_settings`: the `run_settings` the handover answered, a JSON object of at
  #   most 64 KiB as the database encodes it, only on a run of the queue. It has no key,
  #   no secret and no id of either.
  # - `runs.provider_connection_id` and `runs.provider_secret_id`: the model provider the
  #   run uses and its keys' secret. Each becomes NULL should its row be deleted.
  # - `runs.provider_value_id`: the value id of the key the run uses, the rule of
  #   `secret_values.value_id`; `runs.provider_chain`: `organisation` or `operator`, the
  #   chain of the provider; `runs.provider_api`: the API of the provider the run uses, a
  #   JSON object with `format`, `endpoint` and `auth`, and `key_prefixes` when the
  #   provider's description lists them, of at most 8 KiB as the database encodes it. The
  #   three are NULL or all set, and only with `run_settings`. None has a key, a secret or
  #   the id of either.
  #
  # Four end causes join the causes of a run of the queue and of its dispatch, as a
  # handover that cannot form a run's model choice ends it: `provider_gone`,
  # `runtime_unserved`, `key_gone` and `model_gone`. Like the causes of a handover that
  # cannot form the run's variables or its input, each comes with the outcome `error`
  # (`result_outcome`) on a run that is not a prebuild.
  #
  # Rolled back, the columns and their data go, and the causes are as before; the roll
  # back refuses while a run of the queue or a dispatch has one of the four causes.
  @before ~w(released closed undone run_ended lost collection_ended superseded
             variables_invalid ticket_gone inputs_invalid prebuilt)
  @model ~w(provider_gone runtime_unserved key_gone model_gone)
  @handover ~w(variables_invalid ticket_gone inputs_invalid) ++ @model

  def up do
    alter table(:runs) do
      add :run_settings, :jsonb

      add :provider_connection_id,
          references(:organisation_connections, type: :binary_id, on_delete: :nilify_all)

      add :provider_secret_id, references(:secrets, type: :binary_id, on_delete: :nilify_all)
      add :provider_value_id, :text
      add :provider_chain, :text
      add :provider_api, :jsonb
    end

    create constraint(:runs, :runs_run_settings_check,
             check:
               "run_settings IS NULL OR (jsonb_typeof(run_settings) = 'object' " <>
                 "AND octet_length(run_settings::text) <= 65536 AND dispatch_run_id IS NOT NULL)"
           )

    create constraint(:runs, :runs_provider_check,
             check: """
             (provider_value_id IS NULL AND provider_chain IS NULL AND provider_api IS NULL
               AND provider_connection_id IS NULL AND provider_secret_id IS NULL)
             OR (run_settings IS NOT NULL AND provider_value_id IS NOT NULL
               AND provider_chain IS NOT NULL AND provider_api IS NOT NULL
               AND provider_value_id ~ '^[a-z0-9][a-z0-9_.-]{0,63}$'
               AND provider_chain IN ('organisation', 'operator'))
             """
           )

    create constraint(:runs, :runs_provider_api_check,
             check:
               "provider_api IS NULL OR (jsonb_typeof(provider_api) = 'object' " <>
                 "AND provider_api ?& ARRAY['format', 'endpoint', 'auth'] " <>
                 "AND jsonb_typeof(provider_api -> 'format') = 'string' " <>
                 "AND jsonb_typeof(provider_api -> 'endpoint') = 'string' " <>
                 "AND jsonb_typeof(provider_api -> 'auth') = 'object' " <>
                 "AND (provider_api - ARRAY['format', 'endpoint', 'auth', 'key_prefixes']) " <>
                 "= '{}'::jsonb AND octet_length(provider_api::text) <= 8192)"
           )

    create index(:runs, [:provider_connection_id], where: "provider_connection_id IS NOT NULL")

    causes(@before ++ @model)
    outcomes(@handover)
  end

  def down do
    outcomes(~w(variables_invalid ticket_gone inputs_invalid))
    causes(@before)

    drop index(:runs, [:provider_connection_id], where: "provider_connection_id IS NOT NULL")
    drop constraint(:runs, :runs_provider_api_check)
    drop constraint(:runs, :runs_provider_check)
    drop constraint(:runs, :runs_run_settings_check)

    alter table(:runs) do
      remove :provider_api
      remove :provider_chain
      remove :provider_value_id
      remove :provider_secret_id
      remove :provider_connection_id
      remove :run_settings
    end
  end

  defp causes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    for table <- [:dispatch_runs, :dispatches] do
      drop constraint(table, :"#{table}_end_cause_check")

      create constraint(table, :"#{table}_end_cause_check",
               check: "end_cause IS NULL OR end_cause IN (#{list})"
             )
    end
  end

  # The checks of `result_outcome` that name the causes a handover ends a run for.
  defp outcomes(handover) do
    list = Enum.map_join(handover, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_check)
    drop constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check)

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_check,
             check:
               "result_outcome IS NULL OR (" <>
                 "result_outcome IN ('proposal', 'questions', 'error', 'none', 'refused') " <>
                 "AND step <> 'prebuild' AND COALESCE(end_cause IN ('run_ended', " <>
                 "#{list}), false))"
           )

    create constraint(:dispatch_runs, :dispatch_runs_result_outcome_error_check,
             check:
               "step = 'prebuild' OR NOT COALESCE(end_cause IN (#{list}), false) " <>
                 "OR COALESCE(result_outcome = 'error', false)"
           )
  end
end
