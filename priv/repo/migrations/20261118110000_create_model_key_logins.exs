defmodule Apiary.Repo.Migrations.CreateModelKeyLogins do
  use Ecto.Migration

  # The sign-in of a model key whose provider's API has `oauth_refresh`
  # (`Apiary.ModelKeys.Login`): one row per such key, by the value's row id
  # (`secret_values.id`), which a rename of the value id leaves as it is. The row holds no
  # secret: the tokens are the key's value, in `secret_values`, encrypted as any key.
  #
  #   * `account_id`: the account the sign-in is of, from the pasted login;
  #   * `access_expires_at`: when the access token expires, read from the token without
  #     checking its signature, to time the refresh;
  #   * `signed_in_at`: when the login was pasted; `refreshed_at`: when it was last
  #     refreshed, nil until the first refresh;
  #   * `state`: `signed_in`, or `sign_in_needed` once the provider rejected the refresh
  #     for good; `sign_in_cause` is then the reason, and nil otherwise;
  #   * `failures`, `retry_at` and `last_failure`: the refreshes that failed since the
  #     last good one, when the next may start, and when the last one failed;
  #   * `generation`: 1 for the first login of the key, plus 1 for each login pasted
  #     over it, so a refresh that started before it is dropped;
  #   * `lease_id` and `lease_until`: the process that refreshes the login, and until
  #     when it may.
  #
  # The row is of the key's organisation: the composite key to `secret_values` holds
  # `organisation_id` to the value's, as `model_key_states` does. The row goes with the
  # value (`ON DELETE CASCADE`). Nothing exists to fill. Down drops the table.
  def change do
    create table(:model_key_logins, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :secret_value_id,
          references(:secret_values,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          primary_key: true

      add :account_id, :text, null: false
      add :access_expires_at, :utc_datetime_usec, null: false
      add :signed_in_at, :utc_datetime_usec, null: false
      add :refreshed_at, :utc_datetime_usec
      add :state, :text, null: false, default: "signed_in"
      add :sign_in_cause, :text
      add :failures, :integer, null: false, default: 0
      add :retry_at, :utc_datetime_usec
      add :last_failure, :utc_datetime_usec
      add :generation, :integer, null: false, default: 1
      add :lease_id, :binary_id
      add :lease_until, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:model_key_logins, [:organisation_id])

    create constraint(:model_key_logins, :model_key_logins_account_id_check,
             check: "length(account_id) BETWEEN 1 AND 255"
           )

    create constraint(:model_key_logins, :model_key_logins_state_check,
             check: """
             (state = 'signed_in' AND sign_in_cause IS NULL)
             OR (state = 'sign_in_needed' AND sign_in_cause IS NOT NULL
                 AND sign_in_cause ~ '^[a-z][a-z0-9_]{0,63}$')
             """
           )

    create constraint(:model_key_logins, :model_key_logins_failures_check, check: "failures >= 0")

    create constraint(:model_key_logins, :model_key_logins_generation_check,
             check: "generation >= 1"
           )

    create constraint(:model_key_logins, :model_key_logins_lease_check,
             check: "(lease_id IS NULL) = (lease_until IS NULL)"
           )
  end
end
