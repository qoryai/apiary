defmodule Apiary.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  # The tenant of an organisation (`ApiaryPro.Tenants.Tenant`), one row per organisation:
  # written in the transaction that creates it, through the edition's creation hook, and
  # inner-joined wherever the `ApiaryPro` modules read one. Its kind, `organisation` or
  # `operator`, which also manages client organisations; whether it is the instance
  # organisation, whose owners are the instance admins; its operator, when it is a client,
  # and since when; and its suspension. The row goes with its organisation.
  #
  # The database keeps the rules, so no code has to:
  #
  # - One instance organisation at most: the partial unique index lets exactly one row
  #   carry the flag. The instance organisation may be of either kind; it is never
  #   suspended, since it holds the instance admins, who activate everything else, and
  #   never a client, since no operator's people read the instance's own.
  # - The managing relationship is one level deep. `operator_kind` is generated, `operator`
  #   when `operator_id` is set and NULL otherwise, and `(operator_id, operator_kind)` is a
  #   foreign key to `(organisation_id, kind)`, which a unique index makes a key: a client's
  #   operator is of the kind `operator`, and an operator with clients can neither become an
  #   organisation nor go while one references it (no action). Without an operator both
  #   columns are NULL, and the key is not checked. Only an organisation of the kind
  #   `organisation` has an operator, so an operator is never a client and a client never
  #   becomes an operator.
  # - `operator_since`, since when a client is its operator's, is set exactly while it has
  #   one.
  # - A suspender only with a suspension.
  #
  # A trigger would say the same in procedural code, read on every write; the keys and the
  # checks are declared, and Postgres answers them on the rows a write touches.
  def change do
    create table(:tenants, primary_key: false) do
      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :kind, :text, null: false, default: "organisation"
      add :instance_organisation, :boolean, null: false, default: false
      add :operator_id, :binary_id

      add :operator_kind, :text,
        generated:
          "ALWAYS AS (CASE WHEN operator_id IS NULL THEN NULL ELSE 'operator' END) STORED"

      add :operator_since, :utc_datetime_usec
      add :suspended_at, :utc_datetime_usec
      add :suspended_by_id, references(:users, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:organisation_id, :kind])

    execute(
      """
      ALTER TABLE tenants ADD CONSTRAINT tenants_operator_fkey
        FOREIGN KEY (operator_id, operator_kind) REFERENCES tenants (organisation_id, kind)
      """,
      "ALTER TABLE tenants DROP CONSTRAINT tenants_operator_fkey"
    )

    create unique_index(:tenants, [:instance_organisation],
             where: "instance_organisation",
             name: :tenants_one_instance_organisation_index
           )

    create index(:tenants, [:operator_id], where: "operator_id IS NOT NULL")

    create constraint(:tenants, :tenants_kind_check,
             check: "kind IN ('organisation', 'operator')"
           )

    create constraint(:tenants, :tenants_instance_organisation_not_suspended,
             check: "NOT (instance_organisation AND suspended_at IS NOT NULL)"
           )

    create constraint(:tenants, :tenants_instance_organisation_not_client,
             check: "NOT (instance_organisation AND operator_id IS NOT NULL)"
           )

    create constraint(:tenants, :tenants_client_kind_check,
             check: "operator_id IS NULL OR kind = 'organisation'"
           )

    create constraint(:tenants, :tenants_operator_since_check,
             check: "(operator_id IS NULL) = (operator_since IS NULL)"
           )

    create constraint(:tenants, :tenants_suspension_check,
             check: "suspended_by_id IS NULL OR suspended_at IS NOT NULL"
           )
  end
end
