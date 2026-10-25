defmodule Apiary.Lingo.Domain.Software do
  @moduledoc """
  The software domain: a target is a repository, its system a forge. Its labelling rule is
  the one `qory run` follows when it takes the labels from the origin remote: the
  `forge` label is the system and the `repository` label the path. Both must be labels
  that can name a target (`Apiary.Runs.Target.label/1`), or the run names none. Any
  other label, sent by Forager beside them, names nothing here. The `repositories` label,
  which Qory may add to a run (`paths_label/0`), names nothing here either.

  A work item needs a target, its repository. The target's rules are those of the run
  variables `QORY_RUN_SYSTEM` and `QORY_RUN_REPOSITORIES`: the system a host name, the
  path `owner/name` with no segment that starts with a dash. Take in checks them, and a
  claim checks them again with the further repositories. A collection's environment
  is prebuilt, and a target may have a harness file at its root.
  """
  # Qory adds the `repositories` label to a run a claim registers, with the `factory` feature,
  # which the documentation leaves out.
  @behaviour Apiary.Lingo.Domain

  use Gettext, backend: ApiaryWeb.Gettext

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
  def target_required?, do: true

  @impl true
  def check_target(target) do
    case RunVariables.for_target(target) do
      {:ok, _variables} -> :ok
      {:error, _rule} -> {:error, :target_invalid}
    end
  end

  @impl true
  def run_variables(target, picked), do: RunVariables.for_target(target, picked)

  @impl true
  def prebuilds?, do: true

  @impl true
  def harness_file?, do: true
end
