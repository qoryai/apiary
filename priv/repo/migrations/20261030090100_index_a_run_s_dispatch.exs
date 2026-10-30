defmodule Apiary.Repo.Migrations.IndexARunSDispatch do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # The runs whose start failed, by their dispatch: a dispatch deleted with its run of the
  # queue sets `runs.dispatch_id` to nil, and finds those runs through this index.
  def change do
    create index(:runs, [:dispatch_id],
             where: "dispatch_id IS NOT NULL",
             name: :runs_dispatch_id_index,
             concurrently: true
           )
  end
end
