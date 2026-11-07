defmodule Apiary.MachineTypes.MachineType do
  @moduledoc """
  A machine type of the instance (`Apiary.MachineTypes`): its name and its spec, as the
  provisioner contract's `$defs/machine_spec` bounds it, and whether it is the default.
  The name is fixed once the type is made.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @reserved "default"
  @arches ~w(amd64 arm64)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "machine_types" do
    field :name, :string
    field :vcpus, :integer
    field :memory_mib, :integer
    field :disk_gib, :integer
    field :arch, :string
    field :virtualization, :boolean, default: false
    field :is_default, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The architectures a type may have, in the order a form offers them."
  @spec arches() :: [String.t()]
  def arches, do: @arches

  @doc """
  name?/1 is whether `name` is one a type may have: 1 to 64 lower-case letters, digits and
  hyphens that start with a letter, other than `default`.
  """
  @spec name?(term) :: boolean
  def name?(name), do: is_binary(name) and name != @reserved and Regex.match?(@name, name)

  @doc """
  create_changeset/2 is the changeset of a new type: its name and its spec. A name that
  is not one a type may have is an error on `:name` with `validation: :format`, and
  `default` one with `validation: :reserved`; a name another type has, `constraint:
  :unique`. A number out of its bounds is an error on its field.
  """
  @spec create_changeset(t, map) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_name()
    |> spec_changeset(attrs)
    |> unique_constraint(:name, name: :machine_types_name_index)
    |> check_constraint(:name, name: :machine_types_name_check)
  end

  @doc """
  spec_changeset/2 is the changeset of a type's spec: `vcpus` 1 to 1024, `memory_mib`
  512 to 8388608, `disk_gib` 1 to 65536, `arch` `amd64` or `arm64`, and
  `virtualization`.
  """
  @spec spec_changeset(t | Ecto.Changeset.t(), map) :: Ecto.Changeset.t()
  def spec_changeset(type_or_changeset, attrs) do
    type_or_changeset
    |> cast(attrs, [:vcpus, :memory_mib, :disk_gib, :arch, :virtualization])
    |> validate_required([:vcpus, :memory_mib, :disk_gib, :arch])
    |> validate_number(:vcpus, greater_than_or_equal_to: 1, less_than_or_equal_to: 1024)
    |> validate_number(:memory_mib,
      greater_than_or_equal_to: 512,
      less_than_or_equal_to: 8_388_608
    )
    |> validate_number(:disk_gib, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_536)
    |> validate_inclusion(:arch, @arches)
    |> check_constraint(:vcpus, name: :machine_types_spec_check)
  end

  defp validate_name(changeset) do
    case get_change(changeset, :name) do
      @reserved -> add_error(changeset, :name, "is reserved", validation: :reserved)
      nil -> changeset
      _name -> validate_format(changeset, :name, @name)
    end
  end
end
