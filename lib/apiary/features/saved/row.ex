defmodule Apiary.Features.Saved.Row do
  @moduledoc """
  The features an instance admin saved (`Apiary.Features.Saved`), in the instance's row of
  `instance_settings`: `features`, the names of the features on, nil until the first save;
  `features_version`, raised by one on each write of `features`, which a save compares
  with the version its list was read at; and `features_seen`, the names of the features
  the saved list has seen, on or off: one it has not seen takes its default.

  The schema maps only these columns of the row, and `updated_at`; its other columns are
  the instance's other settings (`Apiary.InstanceConfig.Row`, `Apiary.Mail.Settings`).
  """
  use Ecto.Schema

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_settings" do
    field :features, {:array, :string}
    field :features_version, :integer, default: 0
    field :features_seen, {:array, :string}, default: []
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The saved features of the instance's row."
  @type t :: %__MODULE__{}
end
