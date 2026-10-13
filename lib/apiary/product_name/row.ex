defmodule Apiary.ProductName.Row do
  @moduledoc """
  The product's name in the instance's row of `instance_settings` (`Apiary.ProductName`):
  `product_name`, nil for none, and who set it last. The schema maps only these columns of
  the row; its other columns are the instance's other settings (`Apiary.Mail.Settings`,
  `Apiary.KeyCheck`, `Apiary.Setup`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Organisations.Organisation

  @primary_key {:id, :boolean, autogenerate: false}
  schema "instance_settings" do
    field :product_name, :string
    field :updated_by_id, :binary_id
    field :updated_at, :utc_datetime_usec
  end

  @typedoc "The product's name of the instance's row."
  @type t :: %__MODULE__{}

  @doc """
  changeset/3 is the name an instance admin sets, `"product_name"` of `attrs`, where the
  edition names the product `default`: spaces at either end taken off; empty, none; equal
  to `default` where that is "Qory Apiary", none as well, so the edition's shows; otherwise
  checked by the rules of an organisation's name
  (`Apiary.Organisations.Organisation.validate_name/2`).
  """
  @spec changeset(t, map, String.t()) :: Ecto.Changeset.t()
  def changeset(row, attrs, default) do
    row
    |> cast(attrs, [:product_name], empty_values: [])
    |> update_change(:product_name, &given(&1, default))
    |> Organisation.validate_name(:product_name)
  end

  defp given(nil, _default), do: nil

  defp given(name, default) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      "Qory Apiary" when default == "Qory Apiary" -> nil
      trimmed -> trimmed
    end
  end
end
