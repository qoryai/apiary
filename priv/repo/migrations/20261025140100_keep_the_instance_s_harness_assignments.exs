defmodule Apiary.Repo.Migrations.KeepTheInstanceSHarnessAssignments do
  use Ecto.Migration

  # The instance's assignments of harness sources (`Apiary.Harnesses.Assignment`): each
  # row lets the runs of one organisation, or of every organisation, use the instance's
  # links for one harness source. `organisation_id` is that organisation, NULL for every
  # organisation, which `every_organisation` marks: the check
  # `harness_assignments_every_organisation` keeps the two in step. A row is deleted with
  # its organisation. `source` is the harness source as it is in a harness document: a
  # JSON object with the texts `git` and `ref` and at most one of `path`, `stack` and
  # `module`, at most 8,192 bytes as text. One row per source and organisation: the unique
  # index reads every organisation as the nil UUID, and the source as the MD5 of its
  # jsonb text, in which the keys are in one order. The MD5 keeps the index entry short:
  # a btree entry has at most about 2,700 bytes.
  @nobody "'00000000-0000-0000-0000-000000000000'::uuid"

  def change do
    create table(:harness_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all)

      add :every_organisation, :boolean, null: false
      add :source, :map, null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:harness_assignments, :harness_assignments_every_organisation,
             check: "every_organisation = (organisation_id IS NULL)"
           )

    create constraint(:harness_assignments, :harness_assignments_source_shape,
             check: """
             (jsonb_typeof(source) = 'object'
             AND jsonb_typeof(source -> 'git') = 'string'
             AND jsonb_typeof(source -> 'ref') = 'string'
             AND octet_length(source::text) <= 8192) IS TRUE
             """
           )

    create unique_index(
             :harness_assignments,
             ["md5(source::text)", "COALESCE(organisation_id, #{@nobody})"],
             name: :harness_assignments_source_index
           )

    create index(:harness_assignments, [:organisation_id])
    create index(:harness_assignments, [:created_by_id])
  end
end
