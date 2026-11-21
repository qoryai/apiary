defmodule Apiary.Repo.Migrations.KeepTheSignInARunSealed do
  use Ecto.Migration

  # Which token of a sign-in a run has: `model_key_copies.login_at`, the time of the
  # sign-in or of its last refresh (`model_key_logins.refreshed_at`, else `signed_in_at`) read
  # just before the token that a secrets request sealed for the run. A refresh changes
  # that time and leaves the key's `value_set_at`, so `value_set_at` cannot tell a run that
  # has the current token from one that has an older one. A report of a 401 for the key
  # marks it only when the run's `login_at` is the sign-in's current time
  # (`Apiary.ModelKeys.Login.rejectable?/3`), and a renewal serves a token newer than it
  # (`Apiary.ModelKeys.Login.access_token/3`, `newer_than:`).
  #
  # Nullable: a key that is no sign-in has none, and a copy written before this column has
  # none, so a report of such a run marks no sign-in. It changes no row.
  def change do
    alter table(:model_key_copies) do
      add :login_at, :utc_datetime_usec
    end
  end
end
