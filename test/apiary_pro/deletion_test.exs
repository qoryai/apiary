defmodule ApiaryPro.DeletionTest do
  # What the edition adds to a deletion, the core's (`Apiary.DeletionTest`): a member
  # added to a workspace alone, the instance organisation and an operator's clients, and
  # the release command's purge.
  # Not async: the purge is asked on an instance with every feature, so each table holds
  # rows, and the grace period's setting is the node's.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.OrganisationsFixtures

  alias Apiary.{Deletion, Features, Organisations}
  alias Apiary.Deletion.PurgedOrganisation
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}

  @moduletag with_features: Features.all()

  setup do
    owner = sign_up_fixture()
    %{owner: owner, scope: owner.scope}
  end

  describe "deleting a workspace" do
    test "a member added to it alone reaches no workspace, and stays in the organisation",
         %{scope: scope} do
      workspace = workspace_fixture(scope.organisation, "Staging")
      member = member_fixture(workspace_scope(scope.user, workspace), :member)

      {:ok, _} = Deletion.delete_workspace(scope, workspace.id, workspace.slug)

      assert [membership] = Organisations.list_memberships(member.user)
      assert membership.organisation_id == scope.organisation.id
      assert membership.workspaces == []
    end
  end

  describe "the purge" do
    test "the release command, by slug, asked by an instance admin", %{scope: scope} do
      %{user: admin} = sign_up_fixture()
      slug = scope.organisation.slug

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, :not_instance_admin} =
                 ApiaryPro.Release.purge_now(slug, "nobody@example.com")

        # An owner of an organisation is no instance admin.
        assert {:error, :not_instance_admin} = ApiaryPro.Release.purge_now(slug, admin.email)
        assert {:error, :not_instance_admin} = ApiaryPro.Release.purge_now(slug, scope.user.email)
        assert Repo.get(Organisation, scope.organisation.id)

        {:ok, _} = Apiary.Organisations.grant_instance_admin(admin)

        # The instance's own organisation is not purged.
        instance = ApiaryPro.Organisations.instance_organisation()

        assert {:error, :instance_organisation} =
                 ApiaryPro.Release.purge_now(instance.slug, admin.email)

        assert Repo.get(PeopleLock, scope.organisation.id)
        assert {:ok, :purged} = ApiaryPro.Release.purge_now(slug, admin.email)

        assert {:error, :not_found} =
                 ApiaryPro.Release.purge_now("no-such-organisation", admin.email)
      end)

      # The edition's rows of it go with it, its people lock and its tenant among them.
      refute Repo.get(PeopleLock, scope.organisation.id)
      refute Repo.get(Tenant, scope.organisation.id)

      assert Repo.get(Organisation, ApiaryPro.Organisations.instance_organisation().id)

      assert %PurgedOrganisation{requested_by_id: requested_by} =
               Repo.get(PurgedOrganisation, scope.organisation.id)

      assert requested_by == admin.id
    end
  end

  describe "the edition's part" do
    test "a refusal touches nothing: the instance organisation, an operator with clients" do
      instance = ApiaryPro.Organisations.instance_organisation()
      assert {:error, :instance_organisation} = Deletion.purge_now(instance)
      assert %Organisation{deletion_marked_at: nil} = Repo.get!(Organisation, instance.id)

      operator = ApiaryPro.OperatorsFixtures.operator_fixture()
      ApiaryPro.OperatorsFixtures.client_fixture(operator.scope)
      slug = operator.organisation.slug

      assert {:error, :has_clients} = Deletion.delete_organisation(operator.scope, slug)
      assert {:error, :has_clients} = Deletion.purge_now(operator.organisation)

      assert %Organisation{deletion_marked_at: nil} =
               Repo.get!(Organisation, operator.organisation.id)
    end

    test "the sweep's pages leave out what the edition refuses, and stay full" do
      # The instance organisation, marked and due behind the product's back.
      instance = ApiaryPro.Organisations.instance_organisation()

      Repo.update_all(from(o in Organisation, where: o.id == ^instance.id),
        set: [
          deletion_marked_at: DateTime.utc_now(),
          purge_after: DateTime.add(DateTime.utc_now(), -60, :second),
          purge_trigger: "grace_period"
        ]
      )

      due =
        for _ <- 1..3 do
          %{scope: scope} = sign_up_fixture()
          {:ok, _} = Deletion.delete_organisation(scope, scope.organisation.slug)
          overdue!(Organisation, scope.organisation.id)
          scope.organisation.id
        end

      pages = pages_due(nil, [])
      ids = List.flatten(pages)

      assert Enum.sort(ids) == Enum.sort(due)
      assert Enum.all?(Enum.drop(pages, -1), &(length(&1) == 1))
    end

    test "a client's operator hears of its marking and its cancelling, as its members do" do
      operator = ApiaryPro.OperatorsFixtures.operator_fixture()
      client = ApiaryPro.OperatorsFixtures.client_fixture(operator.scope)
      workspace = workspace_fixture(client.organisation)
      operator_id = operator.organisation.id
      client_id = client.organisation.id

      for user <- [operator.user, client.owner.user] do
        Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))
      end

      {:ok, _} = Deletion.delete_workspace(client.owner.scope, workspace.id, workspace.slug)
      assert_receive {:membership_changed, %{organisation_id: ^operator_id}}
      assert_receive {:membership_changed, %{organisation_id: ^client_id}}

      {:ok, _} = Deletion.restore_workspace(client.owner.scope, workspace.id)
      assert_receive {:membership_changed, %{organisation_id: ^operator_id}}
      assert_receive {:membership_changed, %{organisation_id: ^client_id}}

      # An organisation with no operator: its members alone.
      %{scope: other, user: user} = sign_up_fixture()
      Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))
      {:ok, _} = Deletion.delete_organisation(other, other.organisation.slug)
      other_id = other.organisation.id
      assert_receive {:membership_changed, %{organisation_id: ^other_id}}
      refute_received {:membership_changed, %{organisation_id: ^operator_id}}
    end
  end

  ## Helpers

  # Every page of the organisations due, one id a page, as the sweep walks them.
  defp pages_due(cursor, pages) do
    {ids, next} = Deletion.page_organisations_due(cursor, 1)
    pages = [ids | pages]
    if length(ids) < 1, do: Enum.reverse(pages), else: pages_due(next, pages)
  end

  defp overdue!(schema, id) do
    Repo.update_all(from(r in schema, where: r.id == ^id),
      set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
    )
  end
end
