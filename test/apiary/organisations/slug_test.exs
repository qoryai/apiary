defmodule Apiary.Organisations.SlugTest do
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.{Organisation, Slug, Workspace}
  alias Apiary.Repo

  doctest Slug

  describe "from_name/2" do
    test "keeps lowercase letters and digits, and makes every other run one hyphen" do
      assert Slug.from_name("Platform Team") == "platform-team"
      assert Slug.from_name("  --Build & Release 2--  ") == "build-release-2"
      assert Slug.from_name("first.last+tag") == "first-last-tag"
      assert Slug.from_name("Zürich Øst") == "zurich-st"
    end

    test "gives nil when nothing is left, and cuts a long name to 40 without a hyphen at the end" do
      for name <- ["日本", "株式会社", "Ωμέγα", "—", "", nil], do: assert(Slug.from_name(name) == nil)
      # Latin accents are dropped to their letters.
      assert Slug.from_name("Crème Brûlée Ångström") == "creme-brulee-angstrom"

      long = Slug.from_name(String.duplicate("abcd ", 20))
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
    # A later sign-up of `name`, the form's answer.
    defp sign_up(name, opts \\ []) do
      Apiary.Organisations.sign_up_user(
        %{email: unique_user_email(), organisation_name: name},
        nil,
        Keyword.put(opts, :open, true)
      )
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

    test "get their slugs from their names at sign-up; a taken one refuses the name" do
      first = sign_up_fixture(%{organisation_name: "Dana Ops"})
      assert first.organisation.slug == "dana-ops"
      # a workspace's slug is unique within its organisation only
      assert first.workspace.slug == "main"

      before = counts()
      assert {:error, changeset} = sign_up("Dana.Ops")

      assert %{
               organisation_name: [
                 "Choose another name. Another organisation has the address /dana-ops."
               ]
             } = errors_on(changeset)

      assert counts() == before

      # Marked for deletion, it still has the address, and is not said to be marked.
      now = DateTime.utc_now()

      Repo.update_all(
        Ecto.Query.from(o in Organisation, where: o.id == ^first.organisation.id),
        set: [
          deletion_marked_at: now,
          purge_after: DateTime.add(now, 30, :day),
          purge_trigger: "grace_period"
        ]
      )

      assert {:error, changeset} = sign_up("DANA OPS")

      assert %{
               organisation_name: [
                 "Choose another name. Another organisation has the address /dana-ops."
               ]
             } = errors_on(changeset)

      assert %{organisation: %{slug: "dana-ops-team"}} =
               sign_up_fixture(%{organisation_name: "Dana Ops Team"})
    end

    test "never get a name the router reserves or keeps back: the name is refused" do
      for {name, slug} <- [
            {"Docs", "docs"},
            {"Users", "users"},
            {"Admin", "admin"},
            {"API", "api"},
            {"New", "new"},
            {"Settings", "settings"},
            {"Integrations", "integrations"}
          ] do
        assert {:error, changeset} = sign_up(name)
        message = "Choose another name. Qory Apiary keeps the address /#{slug}."
        assert %{organisation_name: [^message]} = errors_on(changeset)
      end
    end

    test "a name with no letter or digit from A to Z or 0 to 9 is refused; accents are dropped" do
      before = counts()

      for name <- ["株式会社", "Ωμέγα"] do
        assert {:error, changeset} = sign_up(name)

        assert %{
                 organisation_name: [
                   "Choose a name with at least one letter or digit from A to Z or 0 to 9. " <>
                     "The address is made from those characters."
                 ]
               } = errors_on(changeset)
      end

      assert counts() == before

      assert {:ok, %{organisation: %Organisation{slug: "creme-brulee"}}} = sign_up("Crème Brûlée")
    end
  end

  describe "a slug taken between the check and the insert" do
    setup do
      %{taken: organisation_fixture().slug}
    end

    test "refuses the name, with the address, and leaves nothing", %{taken: taken} do
      before = counts()

      # The check reads "fresh" as free; the insert meets the slug another sign-up took
      # meanwhile.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Apiary.Organisations.sign_up_user(
                 %{email: "fresh@example.com", organisation_name: "Fresh"},
                 nil,
                 pick_slug: fn _ -> taken end,
                 open: true
               )

      assert %{
               organisation_name: [
                 "Choose another name. Another organisation has the address /" <> ^taken <> "."
               ]
             } = errors_on(changeset)

      assert counts() == before
      refute Repo.get_by(Apiary.Accounts.User, email: "fresh@example.com")
    end
  end

  describe "put_slug/2" do
    test "refuses a reserved name, a malformed slug and one another organisation holds" do
      taken = organisation_fixture().slug

      for {slug, message} <- [
            {"docs", "is kept by Qory Apiary"},
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

      assert "is kept by Qory Apiary" in errors_on(changeset).slug

      assert {:error, changeset} =
               %Workspace{organisation_id: organisation.id}
               |> Workspace.create_changeset(%{name: "Main again", domain: "software"})
               |> Workspace.put_slug(workspace.slug)
               |> Repo.insert()

      assert "is already the slug of a workspace in this organisation" in errors_on(changeset).slug

      # the same slug in two organisations is two workspaces
      for organisation_id <- [organisation.id, organisation_fixture().id] do
        assert {:ok, %Workspace{slug: "platform"}} =
                 %Workspace{organisation_id: organisation_id}
                 |> Workspace.create_changeset(%{name: "Platform", domain: "software"})
                 |> Workspace.put_slug("platform")
                 |> Repo.insert()
      end
    end
  end

  defp put(changeset, slug), do: Organisation.put_slug(changeset, slug)
end
