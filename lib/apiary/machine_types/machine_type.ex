defmodule Apiary.MachineTypes.MachineType do
  @moduledoc """
  A machine type of the instance (`Apiary.MachineTypes`): its key, which process
  documents, stages and runs use; its name, which people see; its spec, as the
  provisioner contract's `$defs/machine_spec` bounds it; and whether it is the default.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @key ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @reserved "default"
  @max_name 100
  @arches ~w(amd64 arm64)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "machine_types" do
    field :key, :string
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
  key?/1 is whether `key` is one a type may have: 1 to 64 lower-case letters, digits and
  hyphens that start with a letter, other than `default`.
  """
  @spec key?(term) :: boolean
  def key?(key), do: is_binary(key) and key != @reserved and Regex.match?(@key, key)

  @doc """
  readable/1 is the name a type of the key `key` gets where none is given: the key with
  its hyphens as spaces and its first letter in upper case, `large-gpu` as Large gpu.
  """
  @spec readable(String.t()) :: String.t()
  def readable(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> String.replace(rest, "-", " ")

  @doc """
  create_changeset/2 is the changeset of a new type: its key, its name and its spec
  (`changeset/2`).
  """
  @spec create_changeset(t, map) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = type, attrs), do: changeset(type, attrs)

  @doc """
  changeset/2 is the changeset of a type's key, name and spec. A key that is not
  one a type may have is an error on `:key` with `validation: :format`, and `default` one
  with `validation: :reserved`; a key another type has, `constraint: :unique`. A name
  that is blank, longer than 100 code points, or has a control character (U+0000 to
  U+001F, U+007F) or a line or paragraph separator (U+2028, U+2029) is an error on
  `:name`: the diagnostics contract takes a name of 1 to 100 code points with no control
  character. A name another type has, ignoring case, is one with `constraint: :unique`.
  A number out of its bounds is an error on its field.
  """
  @spec changeset(t | Ecto.Changeset.t(), map) :: Ecto.Changeset.t()
  def changeset(type, attrs) do
    type
    |> cast(attrs, [:key, :name])
    |> validate_required([:key, :name])
    |> validate_key()
    |> validate_length(:name, max: @max_name, count: :codepoints)
    |> validate_format(:name, ~r/\A[^\x00-\x1f\x7f\x{2028}\x{2029}]+\z/u)
    |> spec_changeset(attrs)
    |> unique_constraint(:key, name: :machine_types_key_index)
    |> unique_constraint(:name, name: :machine_types_name_lower_index)
    |> check_constraint(:key, name: :machine_types_key_check)
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

  defp validate_key(changeset) do
    case get_change(changeset, :key) do
      @reserved -> add_error(changeset, :key, "is reserved", validation: :reserved)
      nil -> changeset
      _key -> validate_format(changeset, :key, @key)
    end
  end
end
