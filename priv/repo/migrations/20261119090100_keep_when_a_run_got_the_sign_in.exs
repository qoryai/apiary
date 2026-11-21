defmodule Apiary.Repo.Migrations.KeepWhenARunGotTheSignIn do
  use Ecto.Migration

  # When a run's copy of a sign-in took its current `login_at`
  # (`model_key_copies.login_sealed_at`): the database's `clock_timestamp()` at the
  # secrets request that sealed that token for the run, kept while later requests seal the
  # same token. A report of a 401 (`unauthorized`) whose `at` is older than it is for a
  # token the run had before, so it marks nothing (`Apiary.ModelKeys.reject/3`).
  #
  # Nullable: a key that is no sign-in has none, and a copy written before this column has
  # none, so a report of such a run is not dropped for its time. It changes no row.
  def change do
    alter table(:model_key_copies) do
      add :login_sealed_at, :utc_datetime_usec
    end
  end
end
