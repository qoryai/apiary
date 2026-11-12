defmodule Apiary.Repo.Migrations.CreateOperatorHarnessAssignments do
  use Ecto.Migration

  # An operator's assignments of harness sources to its clients
  # (`ApiaryPro.HarnessAssignments.Assignment`): each row lets the runs of the client
  # `organisation_id` use the operator's links for one harness source, the source as it
  # is in a harness document: `git` and `ref`, and at most one of `path`, `stack` and
  # `module`. A row goes with the client and with the operator, by their keys. The
  # database keeps the rules:
  #
  # - `git` and `ref` are not empty, and a `path`, `stack` or `module` that is set is not
  #   empty: an empty text never reads as "no key", which would widen the source.
  # - At most one of `path`, `stack` and `module` is set.
  # - One row per source, client and operator. The unique index reads an unset key as the
  #   empty text, which no row has as a set key, and each text as its MD5, which keeps
  #   the entry short: a btree entry has at most about 2,700 bytes.
  def change do
    create table(:operator_harness_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :operator_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :git, :text, null: false
      add :ref, :text, null: false
      add :path, :text
      add :stack, :text
      add :module, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:operator_harness_assignments, :operator_harness_assignments_not_empty,
             check: """
             git <> '' AND ref <> ''
             AND (path IS NULL OR path <> '')
             AND (stack IS NULL OR stack <> '')
             AND (module IS NULL OR module <> '')
             """
           )

    create constraint(:operator_harness_assignments, :operator_harness_assignments_narrowing,
             check: "num_nonnulls(path, stack, module) <= 1"
           )

    create unique_index(
             :operator_harness_assignments,
             [
               :operator_id,
               :organisation_id,
               "md5(git)",
               "md5(ref)",
               "md5(COALESCE(path, ''))",
               "md5(COALESCE(stack, ''))",
               "md5(COALESCE(module, ''))"
             ],
             name: :operator_harness_assignments_source_index
           )

    create index(:operator_harness_assignments, [:organisation_id])
  end
end
