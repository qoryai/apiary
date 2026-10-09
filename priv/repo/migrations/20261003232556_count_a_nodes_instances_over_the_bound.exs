defmodule Apiary.Repo.Migrations.CountANodesInstancesOverTheBound do
  use Ecto.Migration

  # A node records at most 256 new instances in 24 hours (`Apiary.Nodes.seen/3`); an
  # instance past that bound is not recorded, and is counted here instead, with when the
  # last one was. Both are written by an `update_all` outside any changeset, as the starts
  # refused at the instance limit are.
  def change do
    alter table(:nodes) do
      add :instance_ids_over_bound, :integer, null: false, default: 0
      add :instance_ids_over_bound_at, :utc_datetime_usec
    end

    create constraint(:nodes, :nodes_instance_ids_over_bound_check,
             check: "instance_ids_over_bound >= 0"
           )
  end
end
