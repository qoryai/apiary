defmodule Apiary.Artifacts.TemplateTypes do
  # TemplateTypes reads the `artifact_types` list of a factory's `process.yaml`, as
  # `Apiary.Harnesses.Reader.template/1` returns it. An entry with a name alone is a
  # standard type (`Apiary.Artifacts.Type`), and any other entry is a custom type's
  # definition.
  #
  # `check/1` is `:ok`, or `{:error, refusals}` with a list of these, in this order:
  #
  #   1. `{:not_standard, type}`: an entry with a name alone is no standard type;
  #   2. `{:standard_name, type}`: a custom type has a standard type's name;
  #   3. `{:not_listed, stage, type}`: a stage has a type in its inputs or outputs that
  #      the list does not have and that is not always on (`Type.always_on/0`);
  #   4. `{:invalid, type, error}`: a definition fails `Type.create_changeset/2` or
  #      `Apiary.Artifacts.CustomSchema.check/1`. `error` is the field that failed, with
  #      the base view for a limit. The check stops at the first such definition.
  #
  # A nil list is `:ok` with no check, so a template written before the key works
  # unchanged. A template's `process` has passed a loose schema only, and `check/1` runs
  # before `Apiary.Processes.validate/1`: it skips a stage that is not a map, a stage
  # whose name is not text, and an `inputs` or `outputs` that is not a list, and
  # `Apiary.Processes.validate/1` returns an error for each of those.
  #
  # `check/1` does not see a custom name listed twice. The second insert of `apply/3`
  # fails with `{:error, {:invalid, type, :name_taken}}`.
  #
  # `message/1` is a refusal's text, translated in the locale of the caller's process.
  # For `{:invalid, type, error}`, the text ends with the line the Artifact types form
  # shows for that field (`Apiary.Artifacts.TypeRules`).
  #
  # `apply/3` sets up a new workspace from a checked template, inside the caller's
  # transaction, and opens none. It does not check `artifact_type.edit`, as its caller
  # holds `workspace.create`. It does not run `CustomSchema.check/1` again, because that
  # check can take seconds and the caller holds the organisation's lock: the caller runs
  # `check/1` before the transaction. A nil list writes nothing, so the workspace shows
  # every standard type. Any other list inserts each custom type with one audit entry and
  # writes `shown_standard_types`: the listed standard types less the always-on ones, in
  # the order of `Type.standard/0`. An `{:error, reason}` leaves rows written, so the
  # caller rolls back.
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the work items are.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Kernel, except: [apply: 3]

  alias Apiary.{Artifacts, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.{CustomSchema, Type, TypeRules}
  alias Apiary.Harnesses.Reader
  alias Apiary.Organisations.Workspace

  # The fields of a definition, in the order the Artifact types form shows them.
  @fields [:name, :base_view, :size_limit, :max_files, :json_schema]

  @typedoc "What is wrong with a custom type's definition."
  @type error ::
          :name
          | :name_taken
          | :base_view
          | {:size_limit | :max_files, Type.base_view()}
          | :json_schema

  @typedoc "Why a template's types are refused."
  @type refusal ::
          {:not_standard, String.t()}
          | {:standard_name, String.t()}
          | {:not_listed, String.t(), String.t()}
          | {:invalid, String.t(), error}

  # check/1: see the head of this module.
  @doc false
  @spec check(Reader.template()) :: :ok | {:error, [refusal]}
  def check(%{artifact_types: nil}), do: :ok

  def check(%{artifact_types: listed, process: process}) when is_list(listed) do
    {alone, custom} = Enum.split_with(listed, &alone?/1)

    case Enum.uniq(
           not_standard(alone) ++
             standard_names(custom) ++ not_listed(process, listed) ++ invalid(custom)
         ) do
      [] -> :ok
      refusals -> {:error, refusals}
    end
  end

  defp alone?(entry), do: map_size(entry) == 1

  defp not_standard(alone) do
    for %{"name" => name} <- alone, name not in Type.standard_names(), do: {:not_standard, name}
  end

  defp standard_names(custom) do
    for %{"name" => name} <- custom, name in Type.standard_names(), do: {:standard_name, name}
  end

  defp not_listed(process, listed) do
    known = Enum.map(listed, & &1["name"]) ++ Type.always_on()

    for %{"name" => name} = stage when is_binary(name) <- stages(process),
        type <- stage_types(stage),
        type not in known,
        do: {:not_listed, name, type}
  end

  defp stages(%{"stages" => stages}) when is_list(stages), do: stages
  defp stages(_process), do: []

  defp stage_types(stage), do: Enum.uniq(types_in(stage["inputs"]) ++ types_in(stage["outputs"]))

  defp types_in(entries) when is_list(entries) do
    for %{"type" => type} when is_binary(type) <- entries, do: type
  end

  defp types_in(_entries), do: []

  # The first failing definition. A later definition is not checked, as each check of a
  # schema can use a budget of up to 10 s.
  defp invalid(custom) do
    custom
    |> Enum.reject(&(&1["name"] in Type.standard_names()))
    |> Enum.find_value([], fn entry ->
      with {:error, error} <- definition(entry), do: [{:invalid, entry["name"], error}]
    end)
  end

  # nil for a definition that passes, as `Enum.find_value/3` takes it.
  defp definition(entry) do
    changeset = Type.create_changeset(%Type{}, entry)
    schema = entry["json_schema"]

    cond do
      not changeset.valid? -> {:error, error(changeset)}
      is_nil(schema) or CustomSchema.check(schema) == :ok -> nil
      true -> {:error, :json_schema}
    end
  end

  defp error(%Ecto.Changeset{errors: errors} = changeset) do
    case Enum.find(@fields, :json_schema, &Keyword.has_key?(errors, &1)) do
      :name ->
        if unique?(errors[:name]), do: :name_taken, else: :name

      field when field in [:size_limit, :max_files] ->
        {field, Ecto.Changeset.get_field(changeset, :base_view)}

      field ->
        field
    end
  end

  defp unique?({_message, opts}), do: opts[:constraint] == :unique

  # message/1: see the head of this module.
  @doc false
  @spec message(refusal) :: String.t()
  def message({:not_standard, type}),
    do: gettext("%{type} is not a standard type, so it needs a definition", type: type)

  def message({:standard_name, type}),
    do: gettext("the custom type %{type} has a standard type's name", type: type)

  def message({:not_listed, stage, type}),
    do:
      gettext("the stage %{stage} uses %{type}, which artifact_types does not list",
        stage: stage,
        type: type
      )

  def message({:invalid, type, error}),
    do:
      gettext("the custom type %{type} is not valid: %{error}",
        type: type,
        error: line(error, type)
      )

  defp line(:name, _type), do: TypeRules.name()
  defp line(:name_taken, type), do: TypeRules.taken(type)
  defp line(:base_view, _type), do: TypeRules.base_view()
  defp line({:size_limit, base_view}, _type), do: TypeRules.size(base_view)
  defp line({:max_files, base_view}, _type), do: TypeRules.files(base_view)
  defp line(:json_schema, _type), do: TypeRules.schema()

  # apply/3: see the head of this module.
  @doc false
  @spec apply(Workspace.t(), Reader.template(), Scope.t()) ::
          {:ok, Workspace.t()} | {:error, term}
  def apply(%Workspace{} = workspace, %{artifact_types: nil}, %Scope{}), do: {:ok, workspace}

  def apply(%Workspace{} = workspace, %{artifact_types: listed}, %Scope{} = scope)
      when is_list(listed) do
    with :ok <- insert_custom(workspace, Enum.reject(listed, &alone?/1), scope) do
      workspace
      |> Ecto.Changeset.change(shown_standard_types: shown(listed))
      |> Repo.update()
    end
  end

  defp insert_custom(workspace, custom, scope) do
    Enum.reduce_while(custom, :ok, fn entry, :ok ->
      case Artifacts.insert_template_type(scope, workspace, entry) do
        {:ok, _type} ->
          {:cont, :ok}

        {:error, changeset} ->
          {:halt, {:error, {:invalid, entry["name"], error(changeset)}}}
      end
    end)
  end

  defp shown(listed) do
    names = Enum.map(listed, & &1["name"])
    Enum.filter(Type.standard_names() -- Type.always_on(), &(&1 in names))
  end
end
