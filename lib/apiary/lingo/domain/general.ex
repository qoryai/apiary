defmodule Apiary.Lingo.Domain.General do
  @moduledoc """
  The general domain, for any kind of work: its words are the engine's (target, system,
  collection, change request), so its locales have no catalogue and read the language's
  (`en@general` reads `en`). Its labelling rule: the `system` label is the system and
  the `path` label the path, both labels that can name a target
  (`Apiary.Runs.Target.label/1`), or the run names none.

  A work item needs no target. A target it has is a host name and a path of 1 to 200
  characters that can be a label; a run of it gets no run variables, and no collection's
  environment is prebuilt.
  """
  @behaviour Apiary.Lingo.Domain

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Lingo.Domain
  alias Apiary.Runs.Target

  @system_label "system"
  @path_label "path"
  @max_path 200

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
  def name, do: "general"

  @impl true
  def label, do: gettext("General workspace")

  @impl true
  def description,
    do:
      pgettext(
        "workspace type",
        "For any other work, such as marketing, incidents or customer care. Qory reads the ticket, its comments and the answers."
      )

  @impl true
  def target_required?, do: false

  @impl true
  def check_target(%{system: system, path: path}) do
    if Domain.host?(system) and is_binary(Target.label(path)) and
         String.length(path) <= @max_path,
       do: :ok,
       else: {:error, :target_invalid}
  end

  @impl true
  def run_variables(%{system: _system, path: _path}, picked) when is_list(picked),
    do: {:ok, nil}

  @impl true
  def prebuilds?, do: false
end
