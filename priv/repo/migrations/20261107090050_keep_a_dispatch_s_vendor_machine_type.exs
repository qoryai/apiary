defmodule Apiary.Repo.Migrations.KeepADispatchSVendorMachineType do
  use Ecto.Migration

  # `dispatches.vendor_machine_type`: the vendor's type of the machine the starter
  # created, as the first `dispatched` of the dispatch reported it, 1 to 64 printable
  # ASCII characters with no space (the provisioner contract's `$defs/machine_type`);
  # null when it reported none.
  #
  # Adding a column that may be empty, with no default, rewrites no row. The check is
  # added NOT VALID, so adding it takes no scan of `dispatches` under its lock; the next
  # migration validates it.
  def change do
    alter table(:dispatches) do
      add :vendor_machine_type, :text
    end

    create constraint(:dispatches, :dispatches_vendor_machine_type_check,
             check:
               "vendor_machine_type IS NULL OR " <>
                 "(vendor_machine_type ~ '^[!-~]{1,64}$' AND dispatched_at IS NOT NULL)",
             validate: false
           )
  end
end
