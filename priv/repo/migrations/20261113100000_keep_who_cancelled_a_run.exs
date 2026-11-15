defmodule Apiary.Repo.Migrations.KeepWhoCancelledARun do
  use Ecto.Migration

  # A member's cancel of a running run (`Apiary.Runs.cancel/2`):
  #
  # - `cancel_requested_at`, when the member pressed Cancel run;
  # - `cancel_requested_by_id`, the member, nil once their account's row is gone.
  #
  # From that moment the run changes nothing more, whatever its exit. Nil for every other
  # run. Not folded: a rebuild keeps them. Both columns are new and may be empty, with no
  # default, so no row is written again. The key to `users` is added NOT VALID, so adding
  # it takes no scan of the table under its lock; `20261113100100` validates it.
  def change do
    alter table(:runs) do
      add :cancel_requested_at, :utc_datetime_usec

      add :cancel_requested_by_id,
          references(:users, type: :binary_id, on_delete: :nilify_all, validate: false)
    end
  end
end
