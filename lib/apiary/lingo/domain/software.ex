defmodule Apiary.Lingo.Domain.Software do
  @moduledoc """
  The software domain: a target is a repository, its system a forge. Its labelling rule is
  the one `qory run` follows when it takes the labels from the origin remote: the
  `forge` label is the system and the `repository` label the path. Both must be labels
  that can name a target (`Apiary.Runs.Target.label/1`), or the run names none. Any
  other label, sent by Forager beside them, names nothing here. The `repositories` label,
  which Qory may add to a run (`paths_label/0`), names nothing here either.

  A work item needs a target, its repository, which has an address: a target without
  one breaks the domain's rules. The address's rules are those of the run variables
  `QORY_RUN_SYSTEM` and `QORY_RUN_REPOSITORIES`: the system a host name, the path
  `owner/name` with no segment that starts with a dash. Take in checks them, and a
  claim checks them again with the further repositories. A collection's environment
  is prebuilt, and a target may have a harness file at its root.

  Its workspace type is Qory's `qory.software` (`definition/0`). The type settings of a
  session of a stage's run have `full_suite`, whether the full test suite runs after the
  session (`type_settings/1`).
  """
  # Qory adds the `repositories` label to a run a claim registers, with the `factory` feature.
  @behaviour Apiary.Lingo.Domain

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Runs.{RunVariables, Target}

  @system_label "forge"
  @path_label "repository"
  @paths_label "repositories"

  @impl true
  def target(%{} = labels) do
    with system when is_binary(system) <- Target.label(labels[@system_label]),
         path when is_binary(path) <- Target.label(labels[@path_label]) do
      {:ok, %{system: system, path: path}}
    else
      _ -> :none
    end
  end

  @impl true
  def target_labels, do: [@system_label, @path_label]

  @impl true
  def paths_label, do: @paths_label

  @impl true
  def name, do: "software"

  @impl true
  def label, do: gettext("Software workspace")

  # A person reads the line where they pick a type, in any locale, so it says repository in
  # every domain: the `workspace type` context lets it keep the software words.
  @impl true
  def description,
    do:
      pgettext(
        "workspace type",
        "For work on code. Each ticket needs a repository, and Qory reads the repository's code."
      )

  @impl true
  def type_name, do: pgettext("workspace type", "Software factory")

  @impl true
  def type_line,
    do: pgettext("workspace type", "For work on code. Each ticket needs a repository.")

  @impl true
  def target_required?, do: true

  @impl true
  def check_target(%{system: system, path: path}) when is_binary(system) and is_binary(path) do
    case RunVariables.for_target(%{system: system, path: path}) do
      {:ok, _variables} -> :ok
      {:error, _rule} -> {:error, :target_invalid}
    end
  end

  # A repository has an address: a target without one is no repository.
  def check_target(_no_address), do: {:error, :target_invalid}

  @impl true
  def run_variables(target, picked), do: RunVariables.for_target(target, picked)

  @impl true
  def prebuilds?, do: true

  @impl true
  def harness_file?, do: true

  @impl true
  def pushes?, do: true

  @impl true
  def target_noun, do: "repository"

  @impl true
  def copy_noun, do: "checkout"

  @impl true
  def definition, do: Definition.qory("qory.software")

  # `full_suite` is true for a run with `write` access, for an entry of a loop's body
  # (`loop_entry` an index), a loop, or an entry with `first_attempt: true`. A run that
  # reads or does not push runs none. A run of Explore follows the same rule.
  @impl true
  def type_settings(%{level: level, entry: entry, loop_entry: loop_entry}),
    do: %{"full_suite" => full_suite?(level, entry, loop_entry)}

  @impl true
  def type_settings_values, do: [%{"full_suite" => true}, %{"full_suite" => false}]

  defp full_suite?(level, _entry, _loop_entry) when level != :write, do: false
  defp full_suite?(_level, _entry, loop_entry) when is_integer(loop_entry), do: true
  defp full_suite?(_level, %{"loop" => _loop}, nil), do: true
  defp full_suite?(_level, %{"first_attempt" => true}, nil), do: true
  defp full_suite?(_level, _entry, nil), do: false
end
