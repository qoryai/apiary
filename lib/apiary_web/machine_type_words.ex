defmodule ApiaryWeb.MachineTypeWords do
  @moduledoc false

  # The words of a machine type (`Apiary.MachineTypes`) wherever a page shows one: its
  # sizes, a picker's options, and the line of the type a run is queued on.

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.MachineTypes.MachineType
  alias ApiaryWeb.ArtifactComponents

  @mib 1_048_576
  @gib 1_073_741_824

  @doc "A memory of `mib` MiB: \"4 GiB\", \"1.5 GiB\", \"512 MiB\"."
  @spec memory(pos_integer) :: String.t()
  def memory(mib), do: ArtifactComponents.size(mib * @mib)

  @doc "A disk of `gib` GiB: \"30 GiB\", \"2,048 GiB\"."
  @spec disk(pos_integer) :: String.t()
  def disk(gib), do: ArtifactComponents.size(gib * @gib)

  @doc """
  option/1 is a type as a picker offers it: "large: 4 vCPUs, 16 GiB", and ", virtualization"
  after a type that has it.
  """
  @spec option(MachineType.t()) :: String.t()
  def option(%MachineType{virtualization: true} = type),
    do:
      ngettext(
        "%{name}: %{count} vCPU, %{memory}, virtualization",
        "%{name}: %{count} vCPUs, %{memory}, virtualization",
        type.vcpus,
        name: type.name,
        memory: memory(type.memory_mib)
      )

  def option(%MachineType{} = type),
    do:
      ngettext(
        "%{name}: %{count} vCPU, %{memory}",
        "%{name}: %{count} vCPUs, %{memory}",
        type.vcpus,
        name: type.name,
        memory: memory(type.memory_mib)
      )

  @doc """
  default_options/2 is the options of a document's "Default machine type": "Default
  (standard)", which is `default`, the instance's default type, then each type of `types`;
  and `value` as it is when no option has it.
  """
  @spec default_options([MachineType.t()], String.t() | nil) :: [{String.t(), String.t()}]
  def default_options(types, value) do
    [{gettext("Default (%{name})", name: default_name(types)), "default"} | options(types)]
    |> with_value(value)
  end

  @doc """
  entry_options/3 is the options of a workflow entry's "Machine type": "Workspace default
  (standard)", the empty value, where "standard" is the document's default type, or the
  instance's for `default`; "Default (standard)", `default`, for an entry whose value is
  `default`; then each type of `types`; and `value` as it is when no option has it.
  """
  @spec entry_options([MachineType.t()], String.t() | nil, String.t() | nil) ::
          [{String.t(), String.t()}]
  def entry_options(types, default, value) do
    [{workspace_default(types, default), ""} | instance_default(types, value)]
    |> Kernel.++(options(types))
    |> with_value(value)
  end

  @doc """
  default_words/2 is a document's "Default machine type" `value` in the words of its
  picker, for a reader who cannot change it: "Default (standard)" for `default` or none,
  else the type's name.
  """
  @spec default_words([MachineType.t()], String.t() | nil) :: String.t()
  def default_words(types, value) when value in [nil, "", "default"],
    do: gettext("Default (%{name})", name: default_name(types))

  def default_words(_types, value), do: value

  @doc """
  entry_words/3 is a workflow entry's "Machine type" `value` in the words of its picker,
  for a reader who cannot change it: "Workspace default (standard)" for none, with the
  document's default `default`, "Default (standard)" for `default`, else the type's name.
  """
  @spec entry_words([MachineType.t()], String.t() | nil, String.t() | nil) :: String.t()
  def entry_words(types, default, value) when value in [nil, ""],
    do: workspace_default(types, default)

  def entry_words(types, _default, value), do: default_words(types, value)

  defp workspace_default(types, default) do
    name =
      if is_binary(default) and default != "default" and Enum.any?(types, &(&1.name == default)),
        do: default,
        else: default_name(types)

    gettext("Workspace default (%{name})", name: name)
  end

  # An entry whose `machine` is `default` runs on the instance's default type, whatever the
  # document's default: the option keeps that value through the next save.
  defp instance_default(types, "default"),
    do: [{gettext("Default (%{name})", name: default_name(types)), "default"}]

  defp instance_default(_types, _value), do: []

  defp options(types), do: for(type <- types, do: {option(type), type.name})

  defp default_name(types) do
    case Enum.find(types, & &1.is_default) do
      %MachineType{name: name} -> name
      nil -> "default"
    end
  end

  defp with_value(options, value) when is_binary(value) and value not in ["", "default"] do
    if Enum.any?(options, &(elem(&1, 1) == value)), do: options, else: options ++ [{value, value}]
  end

  defp with_value(options, _value), do: options

  @doc """
  requested/2 is the type a run is queued on, with its spec, from the name and the spec as
  the provisioner contract writes it: "large (4 vCPUs, 16 GiB, 60 GiB disk)", and ",
  virtualization" before the parenthesis closes for a spec that has it.
  """
  @spec requested(String.t(), map) :: String.t()
  def requested(name, %{} = spec) do
    words = [
      name: name,
      memory: memory(spec["memory_mib"]),
      disk: disk(spec["disk_gib"])
    ]

    if spec["virtualization"] == true,
      do:
        ngettext(
          "%{name} (%{count} vCPU, %{memory}, %{disk} disk, virtualization)",
          "%{name} (%{count} vCPUs, %{memory}, %{disk} disk, virtualization)",
          spec["vcpus"],
          words
        ),
      else:
        ngettext(
          "%{name} (%{count} vCPU, %{memory}, %{disk} disk)",
          "%{name} (%{count} vCPUs, %{memory}, %{disk} disk)",
          spec["vcpus"],
          words
        )
  end
end
