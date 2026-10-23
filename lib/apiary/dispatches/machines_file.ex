defmodule Apiary.Dispatches.MachinesFile do
  @moduledoc false

  # The machines file: one JSON file on the instance, at the path `APIARY_MACHINES_FILE`
  # is set to (`config/runtime.exs`), with, per workspace, the type of machine a node
  # pool's starter creates for the workspace's runs and the stack the run starts. Read
  # once, at boot (`boot!/0`); a change to the file applies at the next start.
  #
  #     {
  #       "machines": ["small", "large"],
  #       "workspaces": {
  #         "acme/factory": {
  #           "machine": "small",
  #           "stack": "core",
  #           "workflow": "hello"
  #         }
  #       }
  #     }
  #
  # `machines` is the list of machine type names, each a lower-case letter, then up to 63
  # lower-case letters, digits and hyphens, each listed once. `workspaces` has one member
  # per workspace, `<organisation slug>/<workspace slug>`, each with an optional `machine`
  # from `machines`, and an optional `stack` with `workflow`: both or neither. `stack` is
  # the name of the stack the run uses when no level of the organisation sets one, the
  # instance default (`Apiary.Stacks`), and `workflow` the workflow of the stack the run
  # starts, each a name of the same form as a machine type's. Both members of the top
  # level are optional, and a key given twice in one object, or a member not listed here,
  # is refused.
  #
  # A workspace in the file that does not exist is no error: the entry applies when a
  # workspace of those slugs runs. The claim answer has `machine` from the entry of the
  # run's workspace (`machine/2`) for every step. The run's documents have the entry's
  # `workflow` (`stack/2`) for every step but prebuild, with the stack that
  # `Apiary.Stacks.for_run/3` resolves (`ApiaryWeb.Contract.DispatchAnswer`). With
  # `APIARY_MACHINES_FILE` unset or blank, or a workspace without an entry, the claim
  # answer has no `machine` and the run's documents have no stack.
  #
  # A file that is missing, cannot be read or breaks a rule above stops the boot with one
  # line that starts with the fix and contains the entry at fault.

  alias Apiary.Organisations.Slug

  @variable "APIARY_MACHINES_FILE"
  @top ~w(machines workspaces)
  @entry ~w(machine stack workflow)
  @name ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @name_rule "a lower-case letter, then up to 63 lower-case letters, digits and hyphens"

  @typedoc "The name of the stack a run uses, and the workflow of the stack the run starts."
  @type stack :: %{name: String.t(), workflow: String.t()}

  @typedoc "The entry of one workspace: its machine type and its stack, nil for none."
  @type entry :: %{machine: String.t() | nil, stack: stack | nil}

  @typedoc "The file read: the machine type names, and the entries by `org/workspace`."
  @type t :: %{machines: [String.t()], workspaces: %{String.t() => entry}}

  # boot!/0 reads the file at the path `APIARY_MACHINES_FILE` is set to, as
  # `config/runtime.exs` left the setting, and keeps what it read for the life of the
  # node; nil for a setting unset or blank, whitespace alone included. Raises `ArgumentError` with one line for a
  # file `read/1` refuses, so the instance does not start.
  @doc false
  @spec boot!() :: t | nil
  def boot! do
    file =
      case Application.get_env(:apiary, :machines_file_setting) do
        nil ->
          nil

        path ->
          if String.trim(path) == "" do
            nil
          else
            case read(path) do
              {:ok, file} -> file
              {:error, line} -> raise ArgumentError, line
            end
          end
      end

    Application.put_env(:apiary, :machines_file, file)
    file
  end

  # read/1 is the file at `path`, checked against the rules of the moduledoc, or the line
  # with the fix.
  @doc false
  @spec read(String.t()) :: {:ok, t} | {:error, String.t()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- contents(path),
         {:ok, json} <- decode(contents, path),
         {:ok, top} <- object(json, nil, path),
         :ok <- only(top, @top, nil, path),
         {:ok, machines} <- machines(Map.get(top, "machines", []), path),
         {:ok, workspaces} <-
           workspaces(Map.get(top, "workspaces", Jason.OrderedObject.new([])), machines, path) do
      {:ok, %{machines: machines, workspaces: workspaces}}
    end
  end

  # machine/2 is the machine type of the workspace `workspace_slug` of the organisation
  # `organisation_slug`, from the file read at boot: nil without a file or an entry, or
  # for an entry without a machine.
  @doc false
  @spec machine(String.t(), String.t()) :: String.t() | nil
  def machine(organisation_slug, workspace_slug) do
    case entry(organisation_slug, workspace_slug) do
      %{machine: machine} -> machine
      nil -> nil
    end
  end

  # stack/2 is the stack and the workflow of that workspace, as `machine/2` reads it: nil
  # without a file or an entry, or for an entry without a stack.
  @doc false
  @spec stack(String.t(), String.t()) :: stack | nil
  def stack(organisation_slug, workspace_slug) do
    case entry(organisation_slug, workspace_slug) do
      %{stack: stack} -> stack
      nil -> nil
    end
  end

  defp entry(organisation_slug, workspace_slug) do
    case Application.get_env(:apiary, :machines_file) do
      %{workspaces: workspaces} -> Map.get(workspaces, organisation_slug <> "/" <> workspace_slug)
      nil -> nil
    end
  end

  ## Reading

  defp contents(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error,
         "Set #{@variable} to the path of a file that exists, or unset it: #{path} does not exist."}

      {:error, reason} ->
        {:error,
         "Make #{path} a file Qory can read, or unset #{@variable}: " <>
           "the file cannot be read (#{:file.format_error(reason)})."}
    end
  end

  # The JSON, every object a `Jason.OrderedObject`, so a key given twice is found.
  defp decode(contents, path) do
    case Jason.decode(contents, objects: :ordered_objects) do
      {:ok, json} ->
        {:ok, json}

      {:error, %Jason.DecodeError{position: position}} ->
        fix(
          "Write the machines file as JSON",
          path,
          "the file is not valid JSON at byte #{position}."
        )
    end
  end

  # An object of the file as a map, at `at` (nil for the top level), its keys each given
  # once.
  defp object(%Jason.OrderedObject{values: values}, at, path) do
    keys = Enum.map(values, &elem(&1, 0))

    case keys -- Enum.uniq(keys) do
      [] ->
        {:ok, Map.new(values)}

      [twice | _rest] ->
        fix(
          "Remove the second #{inspect(twice)} from #{place(at)}",
          path,
          "a key is given twice."
        )
    end
  end

  defp object(_other, nil, path),
    do: fix("Write the machines file as one JSON object", path, "the file is not an object.")

  defp object(_other, at, path),
    do: fix("Write #{at} as a JSON object", path, "#{at} is not an object.")

  # Every member of `object` is one of `members`.
  defp only(object, members, at, path) do
    case Enum.sort(Map.keys(object) -- members) do
      [] ->
        :ok

      [extra | _rest] ->
        fix(
          "Remove the member #{inspect(extra)} from #{place(at)}",
          path,
          "#{place(at)} takes only #{Enum.join(members, ", ")}."
        )
    end
  end

  defp machines(names, path) when is_list(names) do
    names
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {name, index}, {:ok, seen} ->
      cond do
        not name?(name) ->
          {:halt,
           fix(
             "Correct machines[#{index}]",
             path,
             "#{shown(name)} is not a machine type name: #{@name_rule}."
           )}

        name in seen ->
          {:halt, fix("Remove machines[#{index}]", path, "#{name} is listed twice.")}

        true ->
          {:cont, {:ok, [name | seen]}}
      end
    end)
    |> case do
      {:ok, seen} -> {:ok, Enum.reverse(seen)}
      error -> error
    end
  end

  defp machines(_other, path),
    do: fix("Write machines as a list of names", path, "machines is not a list.")

  defp workspaces(json, machines, path) do
    with {:ok, workspaces} <- object(json, "workspaces", path) do
      workspaces
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, read} ->
        case workspace(key, value, machines, path) do
          {:ok, entry} -> {:cont, {:ok, Map.put(read, key, entry)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp workspace(key, value, machines, path) do
    at = member("workspaces", key)

    with :ok <- workspace_key(key, path),
         {:ok, entry} <- object(value, at, path),
         :ok <- only(entry, @entry, at, path),
         {:ok, machine} <- entry_machine(entry, machines, at, path),
         {:ok, stack} <- entry_stack(entry, at, path) do
      {:ok, %{machine: machine, stack: stack}}
    end
  end

  defp workspace_key(key, path) do
    case String.split(key, "/") do
      [organisation, workspace] ->
        if Slug.valid?(organisation) and Slug.valid?(workspace),
          do: :ok,
          else: bad_key(key, path)

      _other ->
        bad_key(key, path)
    end
  end

  defp bad_key(key, path) do
    fix(
      "Correct the workspace #{shown(key)}",
      path,
      "a workspace is <organisation slug>/<workspace slug>, each 1 to 40 lower-case " <>
        "letters, digits and hyphens."
    )
  end

  defp entry_machine(entry, machines, at, path) do
    case Map.fetch(entry, "machine") do
      :error ->
        {:ok, nil}

      {:ok, machine} ->
        if is_binary(machine) and machine in machines do
          {:ok, machine}
        else
          fix(
            "Add the machine to machines, or correct #{member(at, "machine")}",
            path,
            "#{shown(machine)} is not in machines."
          )
        end
    end
  end

  defp entry_stack(entry, at, path) do
    case {Map.fetch(entry, "stack"), Map.fetch(entry, "workflow")} do
      {:error, :error} ->
        {:ok, nil}

      {{:ok, _stack}, :error} ->
        fix("Add workflow to #{at}", path, "stack and workflow come together.")

      {:error, {:ok, _workflow}} ->
        fix("Add stack to #{at}", path, "stack and workflow come together.")

      {{:ok, stack}, {:ok, workflow}} ->
        with :ok <- stack(stack, member(at, "stack"), path),
             :ok <- workflow(workflow, member(at, "workflow"), path) do
          {:ok, %{name: stack, workflow: workflow}}
        end
    end
  end

  defp stack(stack, at, path) do
    if name?(stack),
      do: :ok,
      else: fix("Correct #{at}", path, "#{shown(stack)} is not a stack name: #{@name_rule}.")
  end

  defp workflow(workflow, at, path) do
    if name?(workflow),
      do: :ok,
      else:
        fix("Correct #{at}", path, "#{shown(workflow)} is not a workflow name: #{@name_rule}.")
  end

  defp name?(name), do: is_binary(name) and Regex.match?(@name, name)

  ## The line

  # The line of a refusal: the fix, the file, then the cause.
  defp fix(fix, path, cause), do: {:error, "#{fix} in the machines file #{path}: #{cause}"}

  defp place(nil), do: "the top level"
  defp place(at), do: at

  defp member(nil, key), do: key
  defp member(at, key), do: at <> "." <> key

  # A value in the line, cut short and on one line.
  defp shown(%Jason.OrderedObject{}), do: "an object"
  defp shown(value), do: inspect(value, limit: 5, printable_limit: 80)
end
