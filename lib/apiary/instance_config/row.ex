defmodule Apiary.InstanceConfig.Row do
  @moduledoc """
  The settings an instance admin saves in Instance settings › Configuration, in the
  instance's row of `instance_settings` (`Apiary.InstanceConfig`): how many days the audit
  trail keeps an entry and the address it came from, the grace period before a purge, and
  the invitations an organisation makes a day. Each is nil until saved, and nil is the
  default.

  The schema maps only these columns of the row, and `updated_at`; its other columns are
  the instance's other settings (`Apiary.Mail.Settings`, `Apiary.ProductName.Row`,
  `Apiary.KeyCheck`, `Apiary.Setup`). It never writes `updated_by_id`, which says who set
  the product's name last: who saved these is in the audit trail.
  """
  use Ecto.Schema

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_settings" do
    field :audit_retention_days, :integer
    field :audit_address_retention_days, :integer
    field :deletion_grace_days, :integer
    field :invitations_per_day, :integer
    # The days a dispatch's machine log is kept (`Apiary.Dispatches.MachineLogs`).
    field :machine_log_retention_days, :integer
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The settings of the instance's row that Instance settings › Configuration saves."
  @type t :: %__MODULE__{}
end
