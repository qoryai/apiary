defmodule ApiaryWeb.MachineTypeWords do
  @moduledoc false

  # The words of a machine type (`Apiary.MachineTypes`) wherever a page shows one: its
  # sizes, a picker's options, and the line of the type a run is queued on.

  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText, only: [rich_ngettext: 4]

  alias Apiary.MachineTypes.MachineType
  alias ApiaryWeb.ArtifactComponents

  # A key beside a name, as the Machine types list shows it; in a run's facts, at the
  # size of the text around it.
  @key_class "font-mono text-[12px] text-muted"
  @fact_key_class "font-mono text-muted"

  @mib 1_048_576
  @gib 1_073_741_824

  @doc "A memory of `mib` MiB: \"4 GiB\", \"1.5 GiB\", \"512 MiB\"."
  @spec memory(pos_integer) :: String.t()
  def memory(mib), do: ArtifactComponents.size(mib * @mib)

  @doc "A disk of `gib` GiB: \"30 GiB\", \"2,048 GiB\"."
  @spec disk(pos_integer) :: String.t()
  def disk(gib), do: ArtifactComponents.size(gib * @gib)

  @doc """
  option/1 is a type as a picker offers it, by its name: "Large: 4 vCPUs, 16 GiB", and ",
  virtualization" after a type that has it.
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
  (Standard)", which is `default`, the instance's default type by its name, then each type
  of `types`, whose value is its key. A key no type has (`missing?/2`) has the first
  option's words in place of `default`, so the picker keeps the key until a person picks
  another. Another `value` no option has, one that breaks the key's pattern, is an option
  as it is.
  """
  @spec default_options([MachineType.t()], String.t() | nil) :: [{String.t(), String.t()}]
  def default_options(types, value) do
    if missing?(types, value),
      do: [{instance_words(types), value} | options(types)],
      else: [{instance_words(types), "default"} | options(types)] |> with_value(value)
  end

  @doc """
  entry_options/3 is the options of a workflow entry's "Machine type": "Workspace default
  (Standard)", the empty value, where Standard is the name of the document's default
  type, or of the instance's for `default`; "Default (Standard)", `default`, for an entry
  whose value is `default`; then each type of `types`, whose value is its key. A key no
  type has (`missing?/2`) is the first option in place of the workspace default, with its
  words, so the picker shows the type the entry runs on and keeps the key until a person
  picks another. Another `value` no option has, one that breaks the key's pattern, is an
  option as it is.
  """
  @spec entry_options([MachineType.t()], String.t() | nil, String.t() | nil) ::
          [{String.t(), String.t()}]
  def entry_options(types, default, value) do
    if missing?(types, value),
      do: [{workspace_default(types, default), value} | options(types)],
      else:
        [{workspace_default(types, default), ""} | instance_default(types, value)]
        |> Kernel.++(options(types))
        |> with_value(value)
  end

  @doc """
  missing?/2 is whether `value`, a `machine` of a process document, is a key that no type
  of `types` has: a key of the pattern `^[a-z][a-z0-9-]{0,63}$`, not `default`, and none
  of their keys. A run of an entry with such a key starts on the workspace's default
  type, else on the instance's.
  """
  @spec missing?([MachineType.t()], term) :: boolean
  def missing?(types, value),
    do:
      is_binary(value) and value != "default" and MachineType.key?(value) and
        not Enum.any?(types, &(&1.key == value))

  @doc """
  fallback_name/2 is the name of the type a run of an entry with a missing key starts on:
  the document's default `default` where a type of `types` has that key, else the
  instance's default type.
  """
  @spec fallback_name([MachineType.t()], String.t() | nil) :: String.t()
  def fallback_name(types, default) do
    case Enum.find(types, &(is_binary(default) and &1.key == default)) do
      %MachineType{name: name} -> name
      nil -> default_name(types)
    end
  end

  @doc """
  default_words/2 is a document's "Default machine type" `value` in the words of its
  picker, for a reader who cannot change it: the name of the type of that key, else
  "Default (Standard)", for `default`, none, or a key no type has; a value that breaks
  the key's pattern as it is.
  """
  @spec default_words([MachineType.t()], String.t() | nil) :: String.t()
  def default_words(types, value) do
    case Enum.find(types, &(&1.key == value)) do
      %MachineType{name: name} -> name
      nil when value in [nil, "", "default"] -> instance_words(types)
      nil -> if missing?(types, value), do: instance_words(types), else: value
    end
  end

  defp instance_words(types), do: gettext("Default (%{name})", name: default_name(types))

  @doc """
  entry_words/3 is a workflow entry's "Machine type" `value` in the words of its picker,
  for a reader who cannot change it: "Workspace default (Standard)" for none or a key no
  type has, with the document's default `default`, "Default (Standard)" for `default`,
  else the type's name.
  """
  @spec entry_words([MachineType.t()], String.t() | nil, String.t() | nil) :: String.t()
  def entry_words(types, default, value) do
    if value in [nil, ""] or missing?(types, value),
      do: workspace_default(types, default),
      else: default_words(types, value)
  end

  defp workspace_default(types, default),
    do: gettext("Workspace default (%{name})", name: fallback_name(types, default))

  # An entry whose `machine` is `default` runs on the instance's default type, whatever the
  # document's default: the option keeps that value through the next save.
  defp instance_default(types, "default"), do: [{instance_words(types), "default"}]

  defp instance_default(_types, _value), do: []

  defp options(types), do: for(type <- types, do: {option(type), type.key})

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
  requested/2 is the type a run is queued on, with its spec, as rich text
  (`ApiaryWeb.RichText`), from the type, `%{key: key, name: name}` with the name of the
  type that has the key today, nil for none, and the spec as the provisioner contract
  writes it: "Large `large` (4 vCPUs, 16 GiB, 60 GiB disk)", and ", virtualization"
  before the parenthesis closes for a spec that has it. With no name, the key alone.
  """
  @spec requested(%{key: String.t(), name: String.t() | nil}, map) :: term
  def requested(type, %{} = spec) do
    name = fact_words(type)
    memory = memory(spec["memory_mib"])
    disk = disk(spec["disk_gib"])

    if spec["virtualization"] == true,
      do:
        rich_ngettext(
          "%{name} (%{count} vCPU, %{memory}, %{disk} disk, virtualization)",
          "%{name} (%{count} vCPUs, %{memory}, %{disk} disk, virtualization)",
          spec["vcpus"],
          name: name,
          memory: memory,
          disk: disk
        ),
      else:
        rich_ngettext(
          "%{name} (%{count} vCPU, %{memory}, %{disk} disk)",
          "%{name} (%{count} vCPUs, %{memory}, %{disk} disk)",
          spec["vcpus"],
          name: name,
          memory: memory,
          disk: disk
        )
  end

  @doc """
  fitted/3 is a type a run waits on, as rich text: its name, then its key in mono and its
  spec in parentheses, as "UI tests, large (`ui-tests-large`: 8 vCPUs, 32 GiB, 100 GiB
  disk)", and ", virtualization" before the parenthesis closes for a spec that has it.
  """
  @spec fitted(String.t(), String.t(), map) :: term
  def fitted(name, key, %{} = spec) do
    memory = memory(spec["memory_mib"])
    disk = disk(spec["disk_gib"])
    key = {:m, key, "font-mono"}

    if spec["virtualization"] == true,
      do:
        rich_ngettext(
          "%{name} (%{key}: %{count} vCPU, %{memory}, %{disk} disk, virtualization)",
          "%{name} (%{key}: %{count} vCPUs, %{memory}, %{disk} disk, virtualization)",
          spec["vcpus"],
          name: name,
          key: key,
          memory: memory,
          disk: disk
        ),
      else:
        rich_ngettext(
          "%{name} (%{key}: %{count} vCPU, %{memory}, %{disk} disk)",
          "%{name} (%{key}: %{count} vCPUs, %{memory}, %{disk} disk)",
          spec["vcpus"],
          name: name,
          key: key,
          memory: memory,
          disk: disk
        )
  end

  @doc """
  type_words/1 is a type a run used, as rich text: its name, then its key in mono, as
  "Browser tests `browser`"; the key alone where no type has it today (`name` nil).
  """
  @spec type_words(%{key: String.t(), name: String.t() | nil}) :: term
  def type_words(type), do: words(type, @key_class)

  @doc """
  fact_words/1 is `type_words/1` for a run's facts, as under Queue the run: the key at
  the size of the name.
  """
  @spec fact_words(%{key: String.t(), name: String.t() | nil}) :: term
  def fact_words(type), do: words(type, @fact_key_class)

  defp words(%{key: key, name: nil}, class), do: {:m, key, class}
  defp words(%{key: key, name: name}, class), do: [name, " ", {:m, key, class}]
end
