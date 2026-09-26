defmodule Apiary.Organisations.SlugsMigrationTest do
  @moduledoc """
  The slugs `20260930001000` gives the organisations and workspaces an installation
  holds: one from each name, oldest first, unique where it has to be and never a reserved
  name, as a new one gets at creation.
  """
  use ExUnit.Case, async: true

  Code.require_file(
    "priv/repo/migrations/20260930001000_add_slugs_to_organisations_and_workspaces.exs",
    File.cwd!()
  )

  alias Apiary.Organisations.Slug
  alias Apiary.Repo.Migrations.AddSlugsToOrganisationsAndWorkspaces, as: Migration

  test "organisations: from the name, numbered when taken or reserved" do
    rows = [[1, "Acme"], [2, "ACME!"], [3, "Settings"], [4, "…"], [5, "Café Société"]]

    assert Migration.organisation_slugs(rows) == [
             {1, "acme"},
             {2, "acme-2"},
             {3, "settings-2"},
             {4, "organisation"},
             {5, "cafe-societe"}
           ]
  end

  test "workspaces: unique within their organisation only, never an organisation page" do
    rows = [[1, :a, "Main"], [2, :a, "main"], [3, :a, "Members"], [4, :b, "Main"]]

    assert Migration.workspace_slugs(rows) == [
             {1, "main"},
             {2, "main-2"},
             {3, "members-2"},
             {4, "main"}
           ]
  end

  test "a long name is cut to 40 characters, and its numbered twin as well" do
    name = String.duplicate("platform ", 10)
    [{1, first}, {2, second}] = Migration.organisation_slugs([[1, name], [2, name]])

    assert first == Slug.from_name(name, "organisation")
    assert String.length(second) <= 40
    assert String.ends_with?(second, "-2")
  end
end
