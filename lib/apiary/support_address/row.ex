defmodule Apiary.SupportAddress.Row do
  @moduledoc """
  The support address in the instance's row of `instance_settings`
  (`Apiary.SupportAddress`): `support_address`, nil for none. The schema maps only this
  column of the row and `updated_at`; its other columns are the instance's other settings
  (`Apiary.InstanceConfig.Row`, `Apiary.ProductName.Row`, `Apiary.Mail.Settings`,
  `Apiary.KeyCheck`, `Apiary.Setup`). It never writes `updated_by_id`, which is who set the
  product's name last: who saved the address is in the audit trail.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_settings" do
    field :support_address, :string
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The support address of the instance's row."
  @type t :: %__MODULE__{}

  @doc """
  changeset/2 is the address an instance admin saves, `"support_address"` of `attrs`:
  spaces at either end taken off; empty, none; otherwise an https address or an email
  address (`Apiary.SupportAddress.parse/1`), with the field's error where it is neither.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:support_address], empty_values: [])
    |> update_change(:support_address, &trimmed/1)
    |> validate_change(:support_address, fn :support_address, value ->
      case Apiary.SupportAddress.parse(value) do
        {:ok, _address} -> []
        {:error, _reason} -> [support_address: Apiary.SupportAddress.invalid_message()]
      end
    end)
    |> check_constraint(:support_address, name: :instance_settings_support_address_length)
  end

  defp trimmed(nil), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
