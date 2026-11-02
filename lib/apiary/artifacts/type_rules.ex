defmodule Apiary.Artifacts.TypeRules do
  # TypeRules has the lines that state the rules of a custom artifact type's fields,
  # translated in the locale of the caller's process: the Artifact types form shows them
  # beside a field, and `Apiary.Artifacts.TemplateTypes` in a refusal of a template.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Artifacts.Type
  alias ApiaryWeb.Format

  @mib 1_048_576

  @doc false
  @spec name() :: String.t()
  def name,
    do:
      gettext(
        "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."
      )

  # taken/1 is the line for a name that a type of the workspace has.
  @doc false
  @spec taken(String.t()) :: String.t()
  def taken(name),
    do: gettext("Choose another name: this workspace has a type called %{name}.", name: name)

  @doc false
  @spec base_view() :: String.t()
  def base_view, do: gettext("Choose a base view.")

  @doc false
  @spec size(Type.base_view()) :: String.t()
  def size(base_view),
    do:
      gettext("Set a size limit above 0 and at most %{size}.",
        size: form_size(Type.max_size_limit(base_view))
      )

  @doc false
  @spec files(Type.base_view()) :: String.t()
  def files(:structured), do: gettext("A structured type has one file.")

  def files(_base_view),
    do:
      gettext("Set most files to a whole number from 1 to %{number}.",
        number: Type.max_files_limit()
      )

  @doc false
  @spec schema() :: String.t()
  def schema,
    do:
      gettext(
        "Paste a JSON Schema: one JSON object of at most 64 KiB that Qory Apiary can build."
      )

  # form_size/1 is a size in MiB, the unit the form takes, as its hint and its lines show
  # it: "2,048 MiB".
  @doc false
  @spec form_size(pos_integer) :: String.t()
  def form_size(bytes) when rem(bytes, @mib) == 0,
    do: gettext("%{number} MiB", number: Format.number(div(bytes, @mib)))

  def form_size(bytes), do: gettext("%{number} MiB", number: mib(bytes))

  # mib/1 is a size limit in MiB, as the form shows it: at most four decimals, without
  # trailing zeros.
  @doc false
  @spec mib(pos_integer) :: String.t()
  def mib(bytes) do
    (bytes / @mib)
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
