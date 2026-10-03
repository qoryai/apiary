defmodule Apiary.Kinds.Coded do
  @moduledoc """
  Coded puts and checks the integrity code (`Apiary.Integrity`) of a row of the kinds: a
  release, a service definition, a connection. The schema says what it codes, by three
  functions, and stores the code in `integrity_key_id`, `integrity_code` and
  `integrity_version`:

    * `integrity_kind/0`, the kind of row, such as `"connection"`;
    * `integrity_version/0`, the version of its choice of fields, which a new row is coded
      under and which is stored with it;
    * `integrity_fields/2`, the fields of a row at a version, in a fixed order.

  `seal/1` codes a changeset as it will be written, so its id must be set before; `verify/1`
  checks a row as read, under the version it was coded under.
  """

  alias Apiary.Integrity

  @doc """
  seal/1 puts the code of the row `changeset` will write, its id included, into the
  changeset. Call it last, once every other change is made.
  """
  @spec seal(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def seal(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  def seal(%Ecto.Changeset{data: %module{}} = changeset) do
    version = module.integrity_version()
    row = Ecto.Changeset.apply_changes(changeset)

    if is_nil(row.id), do: raise(ArgumentError, "a row is coded with its id, which is not set")

    {key_id, code} =
      Integrity.code(module.integrity_kind(), version, module.integrity_fields(row, version))

    Ecto.Changeset.change(changeset,
      integrity_key_id: key_id,
      integrity_code: code,
      integrity_version: version
    )
  end

  @doc """
  verify/1 checks the code of `row` as read: `:ok`, or `{:error, :mismatch}` or
  `{:error, :unknown_key}`.
  """
  @spec verify(struct) :: :ok | {:error, :mismatch | :unknown_key}
  def verify(%module{} = row) do
    version = row.integrity_version

    if is_integer(version) and version in module.integrity_versions() do
      Integrity.verify(
        module.integrity_kind(),
        version,
        module.integrity_fields(row, version),
        row.integrity_key_id,
        row.integrity_code
      )
    else
      {:error, :mismatch}
    end
  end
end
