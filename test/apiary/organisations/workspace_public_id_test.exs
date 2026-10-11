defmodule Apiary.Organisations.WorkspacePublicIdTest do
  # A workspace's id in the server contract, `ws_` and 16 characters: set on creation by
  # `Apiary.Organisations.Workspace.create_changeset/2`, or by the column's default,
  # `workspace_public_id()`, for a row written without one.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{PublicId, Repo}
  alias Apiary.Organisations.{Slug, Workspace}

  @format ~r/\Aws_[0-9a-hjkmnp-tv-z]{16}\z/

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, organisation: scope.organisation}
  end

  defp raw_insert!(organisation, name) do
    Repo.insert!(%Workspace{
      organisation_id: organisation.id,
      name: name,
      slug: Slug.from_name(name, "workspace"),
      domain: "software"
    })
  end

  test "a new workspace has an id of the shape, and two have two", %{
    scope: scope,
    organisation: organisation
  } do
    one = workspace_fixture(organisation)
    other = workspace_fixture(organisation)

    for workspace <- [scope.workspace, one, other] do
      assert PublicId.valid?("ws", workspace.public_id)
      assert workspace.public_id =~ @format
      assert Repo.get!(Workspace, workspace.id).public_id == workspace.public_id
    end

    assert Enum.uniq([scope.workspace.public_id, one.public_id, other.public_id]) ==
             [scope.workspace.public_id, one.public_id, other.public_id]
  end

  test "an id given in the attributes is ignored, and a rename keeps the id", %{
    organisation: organisation
  } do
    given = "ws_0000000000000000"

    changeset =
      Workspace.create_changeset(%Workspace{organisation_id: organisation.id}, %{
        name: "Given",
        domain: "software",
        public_id: given
      })

    created = changeset |> Workspace.put_slug("given") |> Repo.insert!()
    assert created.public_id != given
    assert PublicId.valid?("ws", created.public_id)

    renamed =
      created
      |> Workspace.changeset(%{name: "Renamed", public_id: given})
      |> Repo.update!()

    assert renamed.public_id == created.public_id
    assert Repo.get!(Workspace, created.id).public_id == created.public_id
  end

  test "a row written without an id gets the column's default, which Ecto reads back", %{
    organisation: organisation
  } do
    one = raw_insert!(organisation, "Raw one")
    other = raw_insert!(organisation, "Raw two")

    assert one.public_id =~ @format
    assert other.public_id =~ @format
    assert one.public_id != other.public_id
    assert Repo.get!(Workspace, one.id).public_id == one.public_id
  end

  test "the database refuses an id of another shape, and a second workspace with the same id",
       %{organisation: organisation} do
    for bad <- ~w(ws_000000000000000 ws_000000000000000i nd_0000000000000000 WS_0000000000000000) do
      changeset =
        Workspace.create_changeset(%Workspace{organisation_id: organisation.id}, %{
          name: "Bad #{bad}",
          domain: "software"
        })
        |> Workspace.put_slug("bad-#{System.unique_integer([:positive])}")
        |> Ecto.Changeset.force_change(:public_id, bad)

      assert {:error, changeset} = Repo.insert(changeset)

      assert {"is invalid", [constraint: :check, constraint_name: "workspaces_public_id_format"]} =
               changeset.errors[:public_id]
    end

    taken = workspace_fixture(organisation)

    changeset =
      Workspace.create_changeset(%Workspace{organisation_id: organisation.id}, %{
        name: "Taken",
        domain: "software"
      })
      |> Workspace.put_slug("taken")
      |> Ecto.Changeset.force_change(:public_id, taken.public_id)

    assert {:error, changeset} = Repo.insert(changeset)
    assert {"has already been taken", _} = changeset.errors[:public_id]
  end

  test "workspace_public_id() makes ids of the shape, all different, over many calls" do
    %{rows: rows} =
      Repo.query!("SELECT workspace_public_id() FROM generate_series(1, 5000)")

    ids = List.flatten(rows)

    assert length(ids) == 5000
    assert Enum.all?(ids, &(&1 =~ @format))
    assert Enum.all?(ids, &PublicId.valid?("ws", &1))
    assert length(Enum.uniq(ids)) == 5000

    # Every character of the alphabet turns up, in the first place and the last alike:
    # every five bits are read.
    for position <- [3, 18] do
      seen = ids |> Enum.map(&String.at(&1, position)) |> Enum.uniq() |> length()
      assert seen == 32, "position #{position}"
    end
  end
end
