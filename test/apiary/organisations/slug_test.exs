defmodule Apiary.Organisations.SlugTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.{Organisation, Slug, Workspace}
  alias Apiary.Repo

  doctest Slug

  describe "from_name/2" do
    test "keeps lowercase letters and digits, and makes every other run one hyphen" do
      assert Slug.from_name("Platform Team", "workspace") == "platform-team"
      assert Slug.from_name("  --Build & Release 2--  ", "workspace") == "build-release-2"
      assert Slug.from_name("first.last+tag", "organisation") == "first-last-tag"
      assert Slug.from_name("Zürich Øst", "workspace") == "zurich-st"
    end

    test "falls back when nothing is left, and cuts a long name to 40 without a hyphen at the end" do
      assert Slug.from_name("日本", "organisation") == "organisation"
      assert Slug.from_name("", "workspace") == "workspace"

      long = Slug.from_name(String.duplicate("abcd ", 20), "workspace")
      assert String.length(long) <= 40
      refute String.ends_with?(long, "-")
    end
  end

  describe "pick/3" do
    test "numbers a slug that is taken or reserved, within 40 characters" do
      assert Slug.pick("acme", [], fn _ -> false end) == "acme"
      assert Slug.pick("acme", [], &(&1 in ["acme", "acme-2"])) == "acme-3"
      assert Slug.pick("settings", ["settings"], fn _ -> false end) == "settings-2"

      base = String.duplicate("a", 40)
      assert Slug.pick(base, [], &(&1 == base)) == String.duplicate("a", 38) <> "-2"
    end
  end

  describe "a new organisation and workspace" do
    test "get their slugs from their names at sign-up, numbered when taken" do
      first = sign_up_fixture(%{organisation_name: "Dana Ops"})
      second = sign_up_fixture(%{organisation_name: "Dana.Ops"})

      assert first.organisation.slug == "dana-ops"
      assert second.organisation.slug == "dana-ops-2"
      # a workspace's slug is unique within its organisation only
      assert first.workspace.slug == "main"
      assert second.workspace.slug == "main"
    end

    test "never get a name the router reserves" do
      %{organisation: organisation} = sign_up_fixture(%{organisation_name: "Settings"})
      assert organisation.slug == "settings-2"

      %{organisation: organisation} = sign_up_fixture(%{organisation_name: "Users"})
      assert organisation.slug == "users-2"
    end
  end

  describe "a slug taken between the pick and the insert" do
    setup do
      %{taken: organisation_fixture().slug}
    end

    defp counts do
      for schema <- [
            Apiary.Accounts.User,
            Organisation,
            Workspace,
            Apiary.Organisations.Membership
          ],
          do: Repo.aggregate(schema, :count)
    end

    test "is picked again, and the sign-up goes on", %{taken: taken} do
      picks = :counters.new(1, [])

      # The first pick is the one another sign-up took meanwhile; the next asks again.
      pick = fn name ->
        :counters.add(picks, 1, 1)
        if :counters.get(picks, 1) == 1, do: taken, else: Slug.from_name(name, "x")
      end

      attrs = %{email: "fresh@example.com", organisation_name: "Fresh"}

      assert {:ok, %{organisation: organisation, workspace: workspace, membership: membership}} =
               Apiary.Organisations.sign_up_user(attrs, nil, pick_slug: pick)

      assert Repo.get!(Organisation, organisation.id).slug == "fresh"
      assert workspace.organisation_id == organisation.id
      assert membership.organisation_id == organisation.id
      assert :counters.get(picks, 1) == 2
    end

    test "every time: the sign-up is refused on the email, and leaves nothing", %{taken: taken} do
      before = counts()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Apiary.Organisations.sign_up_user(
                 %{email: "fresh@example.com", organisation_name: "Fresh"},
                 nil,
                 pick_slug: fn _ -> taken end
               )

      assert "could not be signed up just now; please try again" in errors_on(changeset).email
      assert counts() == before
      refute Repo.get_by(Apiary.Accounts.User, email: "fresh@example.com")
    end
  end

  describe "put_slug/2" do
    test "refuses a reserved name, a malformed slug and one another organisation holds" do
      taken = organisation_fixture().slug

      for {slug, message} <- [
            {"docs", "is reserved for a page of Qory Apiary"},
            {"Acme", "may hold lowercase letters"},
            {"-acme", "may hold lowercase letters"},
            {"acme-", "may hold lowercase letters"},
            {String.duplicate("a", 41), "should be at most"}
          ] do
        changeset = %Organisation{} |> Organisation.changeset(%{name: "Acme"}) |> put(slug)
        assert errors_on(changeset).slug |> Enum.any?(&(&1 =~ message)), slug
      end

      assert {:error, changeset} =
               %Organisation{}
               |> Organisation.changeset(%{name: "Acme"})
               |> Organisation.put_slug(taken)
               |> Repo.insert()

      assert "is already the slug of another organisation" in errors_on(changeset).slug
    end

    test "refuses an organisation page's name as a workspace slug, and one the organisation holds" do
      %{organisation: organisation, workspace: workspace} = sign_up_fixture()

      changeset =
        %Workspace{organisation_id: organisation.id}
        |> Workspace.changeset(%{name: "Members"})
        |> Workspace.put_slug("members")

      assert "is reserved for a page of Qory Apiary" in errors_on(changeset).slug

      assert {:error, changeset} =
               %Workspace{organisation_id: organisation.id}
               |> Workspace.changeset(%{name: "Main again"})
               |> Workspace.put_slug(workspace.slug)
               |> Repo.insert()

      assert "is already the slug of a workspace in this organisation" in errors_on(changeset).slug

      # the same slug in two organisations is two workspaces
      for organisation_id <- [organisation.id, organisation_fixture().id] do
        assert {:ok, %Workspace{slug: "platform"}} =
                 %Workspace{organisation_id: organisation_id}
                 |> Workspace.changeset(%{name: "Platform"})
                 |> Workspace.put_slug("platform")
                 |> Repo.insert()
      end
    end
  end

  defp put(changeset, slug), do: Organisation.put_slug(changeset, slug)
end
