defmodule ApiaryWeb.StagesLive.ArtifactTypes do
  # Temporary until Apiary.Artifacts.types/1 lands (piece A): the standard artifact types
  # of the workflow model's spec (§ 11), with the name and the base view
  # `Apiary.Artifacts.types/1` gives, and the path of the Artifact types section of the
  # workspace's settings (section `artifact_types`). When piece A lands, the Stages page
  # calls `Apiary.Artifacts.types/1` and the verified route, and this module goes.
  @moduledoc false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace

  @standard [
    {"acceptance-criteria", :document},
    {"explainer", :document},
    {"decision-record", :document},
    {"mockup", :image},
    {"screenshot", :image},
    {"demo-video", :video},
    {"change", :structured},
    {"proposal", :structured},
    {"questions", :structured},
    {"verdict", :structured}
  ]

  @doc false
  def types(%Workspace{}), do: for({name, view} <- @standard, do: %{name: name, base_view: view})

  # Temporary until piece A's route lands: the one place that writes the path of the
  # section `artifact_types`, `/:org/:workspace/settings/artifact-types`. Then it becomes
  # the verified route `~p"/#{org}/#{workspace}/settings/artifact-types"`.
  @doc false
  def path(%Scope{organisation: organisation, workspace: workspace}),
    do:
      "/" <>
        Phoenix.Param.to_param(organisation) <>
        "/" <> Phoenix.Param.to_param(workspace) <> "/settings/artifact-types"
end
