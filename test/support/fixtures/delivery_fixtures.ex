defmodule Apiary.DeliveryFixtures do
  @moduledoc """
  Test helpers for the delivery of a version to an adapter (`Apiary.Artifacts.Delivery`):
  an artifact and its versions written straight into the tables, with the delivery columns
  of `attrs`.
  """

  alias Apiary.Artifacts.{Artifact, Version}
  alias Apiary.Repo

  @doc "An artifact of `type` and `name` on `work_item`."
  def artifact_fixture(work_item, type, name) do
    Repo.insert!(%Artifact{
      public_id: Apiary.PublicId.generate("af"),
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      type: type,
      name: name,
      inserted_at: ~U[2026-11-20 08:00:00.000000Z]
    })
  end

  @doc "Version `number` of `artifact`, a person's, with the fields of `attrs`."
  def version_fixture(%Artifact{} = artifact, number, attrs \\ []) do
    Repo.insert!(
      struct!(
        %Version{
          public_id: Apiary.PublicId.generate("av"),
          organisation_id: artifact.organisation_id,
          workspace_id: artifact.workspace_id,
          artifact_id: artifact.id,
          number: number,
          writer: :person,
          inserted_at: ~U[2026-11-20 09:00:00.000000Z]
        },
        attrs
      )
    )
  end
end
