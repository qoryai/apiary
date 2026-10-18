defmodule Apiary.Lingo.Domain.Software do
  @moduledoc """
  The software domain: a target is a repository, its system a forge. Its labelling rule is
  the one `qory run` follows when it takes the labels from the origin remote: the
  `forge` label is the system and the `repository` label the path. Both must be labels
  that can name a target (`Apiary.Runs.Target.label/1`), or the run names none. Any
  other label, sent by Forager beside them, names nothing here. The `repositories` label,
  which Qory may add to a run (`paths_label/0`), names nothing here either.
  """
  # Qory adds the `repositories` label to a run it hands over, with the `factory` feature,
  # which the documentation leaves out.
  @behaviour Apiary.Lingo.Domain

  alias Apiary.Runs.Target

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
end
