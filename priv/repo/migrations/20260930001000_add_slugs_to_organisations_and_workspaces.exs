defmodule Apiary.Repo.Migrations.AddSlugsToOrganisationsAndWorkspaces do
  use Ecto.Migration

  # The organisation and the workspace are in the URL, `/:org/:workspace/…`, by their
  # slugs. `organisations.slug` is unique on the instance, `workspaces.slug` unique within
  # the organisation, and a check holds both to the rules of `Apiary.Organisations.Slug`:
  # 1 to 40 of `a`–`z`, `0`–`9` and hyphens, starting and ending with a letter or a digit.
  #
  # Every existing row gets its slug from its name, oldest first, as a new one gets it at
  # creation: accents dropped, lowercased, other characters a hyphen; a name with nothing
  # left gives `organisation` or `workspace`; a slug already given, or reserved, gets
  # `-2`, `-3`, …. The rules and the reserved names are copied here as they are today, so
  # a later change to the application does not change what this migration did. The
  # columns are filled one row at a time, in the migration's transaction: an installation
  # has a handful of organisations and workspaces. Reversible: rolling back drops both
  # columns and their indexes.

  @max_length 40

  @reserved_organisation ~w(
    .well-known about account accounts admin api app assets auth billing blog dev docs
    favicon-32.png favicon.ico favicon.svg fonts health help home images invitations live
    login logout new oauth operator organisations phoenix register robots.txt settings
    signin signout signup static status support users v1 workspace workspaces www
  )

  @reserved_workspace ~w(
    access api audit billing grants invitations keys members new settings workspaces
  )

  @format "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"

  def up do
    alter table(:organisations) do
      add :slug, :string
    end

    alter table(:workspaces) do
      add :slug, :string
    end

    flush()

    backfill_organisations()
    backfill_workspaces()

    alter table(:organisations) do
      modify :slug, :string, null: false
    end

    alter table(:workspaces) do
      modify :slug, :string, null: false
    end

    create unique_index(:organisations, [:slug])
    create unique_index(:workspaces, [:organisation_id, :slug])

    create constraint(:organisations, :organisations_slug_format,
             check: "slug ~ '#{@format}' AND char_length(slug) <= #{@max_length}"
           )

    create constraint(:workspaces, :workspaces_slug_format,
             check: "slug ~ '#{@format}' AND char_length(slug) <= #{@max_length}"
           )
  end

  def down do
    alter table(:workspaces) do
      remove :slug
    end

    alter table(:organisations) do
      remove :slug
    end
  end

  defp backfill_organisations do
    %{rows: rows} = repo().query!("SELECT id, name FROM organisations ORDER BY inserted_at, id")

    for {id, slug} <- organisation_slugs(rows) do
      repo().query!("UPDATE organisations SET slug = $1 WHERE id = $2", [slug, id])
    end
  end

  defp backfill_workspaces do
    %{rows: rows} =
      repo().query!("SELECT id, organisation_id, name FROM workspaces ORDER BY inserted_at, id")

    for {id, slug} <- workspace_slugs(rows) do
      repo().query!("UPDATE workspaces SET slug = $1 WHERE id = $2", [slug, id])
    end
  end

  @doc false
  # The slug of each organisation, from rows of `[id, name]`, oldest first.
  def organisation_slugs(rows) do
    {slugs, _taken} =
      Enum.map_reduce(rows, MapSet.new(@reserved_organisation), fn [id, name], taken ->
        slug = pick(from_name(name, "organisation"), taken)
        {{id, slug}, MapSet.put(taken, slug)}
      end)

    slugs
  end

  @doc false
  # The slug of each workspace, from rows of `[id, organisation_id, name]`, oldest first:
  # unique within the organisation.
  def workspace_slugs(rows) do
    {slugs, _taken} =
      Enum.map_reduce(rows, %{}, fn [id, organisation_id, name], taken ->
        in_organisation = Map.get(taken, organisation_id, MapSet.new(@reserved_workspace))
        slug = pick(from_name(name, "workspace"), in_organisation)
        {{id, slug}, Map.put(taken, organisation_id, MapSet.put(in_organisation, slug))}
      end)

    slugs
  end

  defp from_name(name, fallback) do
    slug =
      name
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/[^\x00-\x7F]/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> trim()

    if slug == "", do: fallback, else: slug
  end

  defp pick(base, taken) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&candidate(base, &1))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp candidate(base, 1), do: base

  defp candidate(base, n) do
    suffix = "-#{n}"
    trim(String.slice(base, 0, @max_length - String.length(suffix))) <> suffix
  end

  defp trim(slug), do: slug |> String.slice(0, @max_length) |> String.trim("-")
end
