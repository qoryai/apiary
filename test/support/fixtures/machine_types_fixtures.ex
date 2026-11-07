defmodule Apiary.MachineTypesFixtures do
  @moduledoc "Test helpers for the instance's machine types."

  import Ecto.Query, only: [from: 2]

  alias Apiary.MachineTypes.MachineType
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  @doc """
  A machine type with `attrs` over 4 vCPUs, 16 GiB, 60 GiB of disk, amd64 and no
  virtualization, inserted without a scope or a pool check. The name is unique unless
  `attrs` has one; a type made the default leaves the seeded default as it is.
  """
  def machine_type_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "type-#{System.unique_integer([:positive])}",
        vcpus: 4,
        memory_mib: 16_384,
        disk_gib: 60,
        arch: "amd64"
      })

    %MachineType{}
    |> MachineType.create_changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Removes the types `names`, with no check of their use, for a page that lists them."
  def remove_machine_types(names) do
    Repo.delete_all(from(t in MachineType, where: t.name in ^names))
  end

  @doc "`type` made the default, and the default before it no longer one."
  def make_default!(%MachineType{} = type) do
    Repo.update_all(from(t in MachineType, where: t.is_default), set: [is_default: false])
    type |> Ecto.Changeset.change(is_default: true) |> Repo.update!()
  end

  @doc "The seeded default type, `standard`."
  def standard_type, do: Repo.get_by!(MachineType, name: "standard")

  @doc "A spec as the provisioner contract writes it, `attrs` over 4 vCPUs, 16 GiB, 60 GiB."
  def spec(attrs \\ %{}) do
    Map.merge(
      %{
        "vcpus" => 4,
        "memory_mib" => 16_384,
        "disk_gib" => 60,
        "arch" => "amd64",
        "virtualization" => false
      },
      Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    )
  end

  @doc "`pool` with `offers` as the offers of its latest claim, nil for none."
  def with_offers(%Node{} = pool, offers) do
    pool |> Ecto.Changeset.change(offers: offers) |> Repo.update!()
  end
end
