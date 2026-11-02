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
  #   4. `{:repeated, type}`: an entry with a name alone has a standard name that another
  #      such entry has, one refusal per name;
  #   5. `{:invalid, type, :repeated}`: the list has a custom name more than once, one
  #      refusal per name. A custom type with a standard name is only
  #      `{:standard_name, type}`;
  #   6. `{:invalid, type, error}`: a definition fails `Type.create_changeset/2` or
  #      `Apiary.Artifacts.CustomSchema.check/1`. `error` is the field that failed, with
  #      the base view for a limit. The check stops at the first such definition;
  #   7. `:schemas_too_long`: the definitions' JSON Schemas passed the total of one
  #      template (`@total`), which `Apiary.Artifacts.CustomSchema.check_within/2` counts.
  #      A file of 64 KiB fits about 800 definitions, each with a budget of up to 10 s, so
  #      the total bounds how long one template holds a caller. A schema over its single
  #      budget stays `{:invalid, type, :json_schema}`. A template with no JSON Schema
  #      does no such work, and `check/2` is `check/1` with another total. `total/1` is
  #      the total for a caller with less time than `@total`.
  #
  # `{:schema, type}` is an eighth refusal, which `check/1` does not make: the entry `type`
  # did not pass the schema of `process.yaml`, so `Apiary.Harnesses.Reader.template/1`
  # returned no template to check, and `Apiary.Stacks.Sources` makes the refusal.
  #
  # A nil list is `:ok` with no check, so a template written before the key works
  # unchanged. `Apiary.Stacks.Sources` calls `check/2` on each template it reads, with the
  # time its read has left, last, after `Apiary.Harnesses.Reader.template/1`, the check of
  # the stack and `Apiary.Processes.validate/1`. A caller that has not validated the process gets no
  # crash: `check/1` skips a stage that is not a map, a stage whose name is not text, and
  # an `inputs` or `outputs` that is not a list.
  #
  # `message/1` is a refusal's text, translated in the locale of the caller's process.
  # For `{:invalid, type, error}`, the text ends with the line the Artifact types form
  # shows for that field (`Apiary.Artifacts.TypeRules`).
  #
  # `apply/3` sets up a new workspace from a checked template, inside the caller's
  # transaction, and opens none. It does not check `artifact_type.edit`, as its caller
  # holds `workspace.create`. It does not run `CustomSchema.check/1` again, because that
  # check can take up to 30 s and the caller holds the organisation's lock: the caller runs
  # `check/1` before the transaction. A nil list writes nothing, so the workspace shows
  # every standard type. Any other list inserts each custom type with one audit entry and
  # writes `shown_standard_types`: the listed standard types less the always-on ones, in
  # the order of `Type.standard/0`. An `{:error, reason}` leaves rows written, so the
  # caller rolls back. Given a list `check/1` did not pass, the second insert of a repeated
  # name fails with `{:error, {:invalid, type, :repeated}}`.
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

  # The total over the JSON Schemas of one template. Measured on OTP 29: the worst file
  # found, 64 KiB of 430 definitions that each refer to the JSON Schema metaschema, does
  # 26.95 million reductions in 242 ms, and 470 of the shortest such definitions do 29.4
  # million in 269 ms, about 100,000 reductions per ms. 300 million is 11 times the first
  # and 30 times a schema's budget of 10 million, so a definition that fits its budget
  # fits the total. The reductions are the bound: the same file gets the same result on
  # any machine. They take about 3 s at that rate, so the 30 s is only a bound on a run
  # that counts few reductions.
  @total [reductions: 300_000_000, ms: 30_000]

  @typedoc "What is wrong with a custom type's definition."
  @type error ::
          :name
          | :repeated
          | :base_view
          | {:size_limit | :max_files, Type.base_view()}
          | :json_schema

  @typedoc "What is wrong with a template's types."
  @type refusal ::
          {:not_standard, String.t()}
          | {:standard_name, String.t()}
          | {:not_listed, String.t(), String.t()}
          | {:repeated, String.t()}
          | {:invalid, String.t(), error}
          | :schemas_too_long
          | {:schema, String.t()}

  # check/1: see the head of this module.
  @doc false
  @spec check(Reader.template(), reductions: non_neg_integer, ms: non_neg_integer) ::
          :ok | {:error, [refusal]}
  def check(template, total \\ @total)

  def check(%{artifact_types: nil}, _total), do: :ok

  def check(%{artifact_types: listed, process: process}, total) when is_list(listed) do
    {alone, custom} = Enum.split_with(listed, &alone?/1)

    case Enum.uniq(
           not_standard(alone) ++
             standard_names(custom) ++
             not_listed(process, listed) ++
             repeated_standard(alone) ++ repeated(custom) ++ invalid(custom, total)
         ) do
      [] -> :ok
      refusals -> {:error, refusals}
    end
  end

  # total/1 is the total of a caller with `left` ms: the same reductions, and the smaller
  # of `@total`'s time and `left`.
  @doc false
  @spec total(integer) :: [reductions: pos_integer, ms: non_neg_integer]
  def total(left),
    do: [reductions: @total[:reductions], ms: left |> min(@total[:ms]) |> max(0)]

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

  # One refusal per standard name listed more than once by its name alone.
  defp repeated_standard(alone) do
    names = alone |> Enum.map(& &1["name"]) |> Enum.filter(&(&1 in Type.standard_names()))
    for name <- Enum.uniq(names -- Enum.uniq(names)), do: {:repeated, name}
  end

  # One refusal per custom name listed more than once.
  defp repeated(custom) do
    names = custom |> Enum.map(& &1["name"]) |> Enum.reject(&(&1 in Type.standard_names()))
    for name <- Enum.uniq(names -- Enum.uniq(names)), do: {:invalid, name, :repeated}
  end

  # The first failing definition, or the total's refusal. A later definition is not
  # checked, as each check of a schema can use a budget of up to 10 s.
  defp invalid(custom, total) do
    custom
    |> Enum.reject(&(&1["name"] in Type.standard_names()))
    |> Enum.reduce_while(CustomSchema.total(total), fn entry, left ->
      case definition(entry, left) do
        {:ok, left} -> {:cont, left}
        {:error, refusal} -> {:halt, [refusal]}
      end
    end)
    |> case do
      %{} = _left -> []
      refusal -> refusal
    end
  end

  defp definition(%{"name" => name} = entry, left) do
    changeset = Type.create_changeset(%Type{}, entry)
    schema = entry["json_schema"]

    cond do
      not changeset.valid? -> {:error, {:invalid, name, error(changeset)}}
      is_nil(schema) -> {:ok, left}
      true -> schema_within(schema, name, left)
    end
  end

  defp schema_within(schema, name, left) do
    case CustomSchema.check_within(schema, left) do
      {:ok, left} -> {:ok, left}
      {:error, :total} -> {:error, :schemas_too_long}
      {:error, _refusal} -> {:error, {:invalid, name, :json_schema}}
    end
  end

  defp error(%Ecto.Changeset{errors: errors} = changeset) do
    case Enum.find(@fields, :json_schema, &Keyword.has_key?(errors, &1)) do
      :name ->
        if unique?(errors[:name]), do: :repeated, else: :name

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
  def message(:schemas_too_long),
    do:
      gettext(
        "the JSON Schemas in artifact_types take too long to check: use fewer or smaller schemas"
      )

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

  def message({:repeated, type}),
    do: gettext("artifact_types lists %{type} more than once: list this name once", type: type)

  def message({:schema, type}),
    do:
      gettext("the entry %{type} in artifact_types does not match process.schema.json",
        type: type
      )

  def message({:invalid, type, error}),
    do:
      gettext("the custom type %{type} is not valid: %{error}",
        type: type,
        error: line(error)
      )

  defp line(:name), do: TypeRules.name()
  defp line(:repeated), do: TypeRules.repeated()
  defp line(:base_view), do: TypeRules.base_view()
  defp line({:size_limit, base_view}), do: TypeRules.size(base_view)
  defp line({:max_files, base_view}), do: TypeRules.files(base_view)
  defp line(:json_schema), do: TypeRules.schema()

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
