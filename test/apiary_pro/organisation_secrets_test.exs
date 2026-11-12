defmodule ApiaryPro.OrganisationSecretsTest do
  @moduledoc """
  The organisation's secrets, of the `organisation_variables` feature, the edition's
  answer to the core (`ApiaryPro.OrganisationSecrets`,
  `c:Apiary.Edition.organisation_secrets/2`): who reads, changes and links them, each role
  at each verb, a member at any reach among them; the feature taken away from the
  organisation, and off for the instance; sealing, which the instance alone answers; a
  suspended organisation; and the core's entry of each change in the organisation's
  trail.
  """
  # Not async: the instance's features are the node's, and an instance admin is an owner
  # of the suite's one instance organisation.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{OrganisationSecrets, Suspensions}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()
  @moduletag needs: :organisation_variables

  @verbs [:read, :write, :use]

  setup do
    %{scope: owner, organisation: organisation, workspace: shop, user: owner_user} =
      sign_up_fixture()

    %{owner: owner, owner_user: owner_user, organisation: organisation, shop: shop}
  end

  # The scope of `user` in the organisation, as a page of its settings loads it.
  defp in_org(user, organisation), do: scope_in(user, Repo.get!(Organisation, organisation.id))

  defp answers(scope), do: Map.new(@verbs, &{&1, OrganisationSecrets.may(scope, &1)})

  defp create!(scope, name, value \\ "token-value") do
    {:ok, secret} = Secrets.create_organisation_secret(scope, %{"name" => name, "value" => value})
    secret
  end

  describe "each role at each verb" do
    test "owners and admins read, change and link them", ctx do
      %{user: admin} = member_fixture(ctx.owner, :admin)

      for scope <- [in_org(ctx.owner_user, ctx.organisation), in_org(admin, ctx.organisation)] do
        assert answers(scope) == %{read: :ok, write: :ok, use: :ok}
      end
    end

    test "a member neither reads nor changes them, whatever workspaces they reach", ctx do
      %{user: member, membership: membership} = member_fixture(ctx.owner, :member)
      create!(ctx.owner, "FORGE_TOKEN")
      platform = workspace_fixture(ctx.organisation, "Platform")

      # Added to Shop only, then to every workspace: the same answer.
      for reach <- [:some, :every] do
        if reach == :every,
          do: {:ok, _} = ApiaryPro.WorkspaceAccess.add(ctx.owner, membership.id, platform.id)

        scope = in_org(member, ctx.organisation)

        assert answers(scope) == %{
                 read: {:error, :forbidden},
                 write: {:error, :forbidden},
                 use: {:error, :forbidden}
               },
               "#{reach}"

        assert {:error, _reason} = Secrets.list_organisation_secrets(scope)
        refute OrganisationSecrets.shown?(scope)

        assert {:error, :forbidden} =
                 Secrets.create_organisation_secret(scope, %{"name" => "OTHER", "value" => "x"})
      end
    end

    test "an instance admin reads them, and changes nothing", ctx do
      %{user: admin} = instance_admin_fixture()
      scope = in_org(admin, ctx.organisation)

      assert answers(scope) == %{
               read: :ok,
               write: {:error, :forbidden},
               use: {:error, :forbidden}
             }
    end

    test "another organisation's owner reaches none of them", ctx do
      other = sign_up_fixture()
      create!(ctx.owner, "FORGE_TOKEN")

      assert scope_in(other.user, ctx.organisation) == nil
      assert {:ok, []} = Secrets.list_organisation_secrets(other.scope)
    end

    @tag needs: :managed_organisations
    test "in a client, the operator's people read them, and change nothing" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      for organisation <- [operator.organisation, client.organisation], do: grant!(organisation)
      %{user: operator_member} = member_fixture(operator.scope, :member)

      for user <- [operator.user, operator_member] do
        assert answers(scope_in(user, client.organisation)) == %{
                 read: :ok,
                 write: {:error, :forbidden},
                 use: {:error, :forbidden}
               }
      end

      assert answers(in_org(client.owner.user, client.organisation)) ==
               %{read: :ok, write: :ok, use: :ok}
    end
  end

  # The organisation's row for the feature, granted or not, written here as a grant page
  # writes it (`ApiaryPro.Grants`).
  defp grant!(%Organisation{id: id}, granted \\ true) do
    Repo.insert!(%Grant{organisation_id: id, feature: :organisation_variables, granted: granted},
      on_conflict: [set: [granted: granted]],
      conflict_target: [:organisation_id, :feature]
    )
  end

  describe "a suspended organisation" do
    test "is read only", ctx do
      secret = create!(ctx.owner, "FORGE_TOKEN")
      %{instance_scope: instance} = instance_admin_fixture()
      {:ok, _} = Suspensions.suspend_organisation(instance, ctx.organisation.id)
      scope = in_org(ctx.owner_user, ctx.organisation)

      assert answers(scope) == %{
               read: :ok,
               write: {:error, :forbidden},
               use: {:error, :forbidden}
             }

      assert {:ok, [_secret]} = Secrets.list_organisation_secrets(scope)
      assert {:error, :forbidden} = Secrets.delete_secret(scope, secret)
    end
  end

  describe "the feature not the organisation's" do
    # An operator has only what it is granted: without a grant of the feature, its people
    # neither read nor change its secrets. Its secrets were made while it had one.
    @describetag needs: :managed_organisations
    setup do
      operator = operator_fixture()
      grant!(operator.organisation)
      secret = create!(operator.scope, "FORGE_TOKEN", "kept")
      grant!(operator.organisation, false)
      refute :organisation_variables in ApiaryPro.Features.of(operator.organisation)
      %{operator: operator, secret: secret}
    end

    test "its people neither read nor change them", %{operator: operator} do
      scope = in_org(operator.user, operator.organisation)

      assert answers(scope) == %{
               read: {:error, :not_found},
               write: {:error, :not_found},
               use: {:error, :not_found}
             }

      assert {:error, :not_found} = Secrets.list_organisation_secrets(scope)
      refute OrganisationSecrets.shown?(scope)
    end

    test "its secrets are still sealed", %{operator: operator, secret: secret} do
      assert OrganisationSecrets.may(nil, :seal) == :ok

      assert {:ok, "kept"} =
               Secrets.reveal_for_sealing(operator.organisation, secret.public_id, nil)
    end
  end

  describe "sealing" do
    test "is the instance's alone: with the feature every organisation's secret is sealed",
         ctx do
      secret = create!(ctx.owner, "FORGE_TOKEN", "sealed")
      assert OrganisationSecrets.may(nil, :seal) == :ok
      assert {:ok, "sealed"} = Secrets.reveal_for_sealing(ctx.organisation, secret.public_id, nil)
    end

    test "without the feature on the instance, none is, and nobody reads them", ctx do
      secret = create!(ctx.owner, "FORGE_TOKEN")
      Application.put_env(:apiary, :features, Features.all() -- [:organisation_variables])

      assert OrganisationSecrets.may(nil, :seal) == {:error, :not_found}

      assert {:error, :not_found} =
               Secrets.reveal_for_sealing(ctx.organisation, secret.public_id, nil)

      assert answers(in_org(ctx.owner_user, ctx.organisation)) == %{
               read: {:error, :not_found},
               write: {:error, :not_found},
               use: {:error, :not_found}
             }
    end

    test "is asked with no scope only", ctx do
      assert OrganisationSecrets.may(ctx.owner, :seal) == {:error, :not_found}
      assert OrganisationSecrets.may(nil, :read) == {:error, :not_found}
    end
  end

  describe "the trail" do
    test "each change is the core's stored secret entry, at the organisation's level", ctx do
      secret = create!(ctx.owner, "FORGE_TOKEN")

      {:ok, secret} =
        Secrets.add_value(ctx.owner, secret, %{
          "first_value_id" => "main-app",
          "value_id" => "bot-app",
          "value" => "x"
        })

      {:ok, _secret} = Secrets.delete_value(ctx.owner, secret, "bot-app")

      entries =
        Repo.all(
          from e in Entry,
            where: e.organisation_id == ^ctx.organisation.id and e.action == "secret.write",
            order_by: [asc: e.inserted_at, asc: e.id]
        )

      assert [
               %{details: %{"change" => "created", "level" => "organisation"}},
               %{details: %{"change" => "value_added", "level" => "organisation"}},
               %{details: %{"change" => "value_deleted", "level" => "organisation"}}
             ] = entries

      assert Enum.all?(entries, &is_nil(&1.workspace_id))
      refute Enum.any?(entries, &(inspect(&1) =~ "token-value"))
    end
  end

  # Each action asked of `Apiary.Access.check/3` itself, with no `may/2` in between.
  defp checks(scope, subject) do
    Map.new(@verbs, &{&1, Apiary.Access.check(scope, :"organisation_secret.#{&1}", subject)})
  end

  describe "the place rule in Apiary.Access.check/3" do
    @not_found %{
      read: {:error, :not_found},
      write: {:error, :not_found},
      use: {:error, :not_found}
    }

    @forbidden %{
      read: {:error, :forbidden},
      write: {:error, :forbidden},
      use: {:error, :forbidden}
    }

    # While features are shown by who asks, an instance admin is shown every feature, so
    # the core's feature step passes: only the rule returns not found.
    test "an instance admin reads where the organisation has the feature, else not found",
         ctx do
      ApiaryPro.Flags.put_feature_visibility(true)
      %{user: admin} = instance_admin_fixture()

      assert checks(in_org(admin, ctx.organisation), ctx.organisation) ==
               %{read: :ok, write: {:error, :forbidden}, use: {:error, :forbidden}}

      grant!(ctx.organisation, false)
      scope = in_org(admin, ctx.organisation)
      refute :organisation_variables in scope.hidden

      assert Apiary.Access.check(scope, :"organisation_variable.read", ctx.organisation) == :ok
      assert checks(scope, ctx.organisation) == @not_found
      assert OrganisationSecrets.may(scope, :read) == {:error, :not_found}
    end

    @tag needs: :managed_organisations
    test "a client without the feature is not found to the operator's people", _ctx do
      ApiaryPro.Flags.put_feature_visibility(true)
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      grant!(operator.organisation)
      grant!(client.organisation, false)

      scope = scope_in(operator.user, client.organisation)
      refute :organisation_variables in scope.hidden
      assert checks(scope, client.organisation) == @not_found

      grant!(client.organisation)
      scope = scope_in(operator.user, client.organisation)

      assert checks(scope, client.organisation) ==
               %{read: :ok, write: {:error, :forbidden}, use: {:error, :forbidden}}
    end

    @tag needs: :managed_organisations
    test "an operator's organisation has what it is granted", _ctx do
      operator = operator_fixture()
      grant!(operator.organisation)
      scope = scope_in(operator.user, operator.organisation)
      assert checks(scope, operator.organisation) == %{read: :ok, write: :ok, use: :ok}

      grant!(operator.organisation, false)
      scope = scope_in(operator.user, operator.organisation)
      assert checks(%{scope | hidden: []}, operator.organisation) == @not_found
    end

    test "comes before the role and the scope's kind", ctx do
      %{user: member} = member_fixture(ctx.owner, :member)
      instance = Apiary.Accounts.Scope.for_instance(ctx.organisation)

      assert checks(in_org(member, ctx.organisation), ctx.organisation) == @forbidden
      assert checks(instance, ctx.organisation) == @forbidden

      grant!(ctx.organisation, false)
      member_scope = in_org(member, ctx.organisation)

      assert checks(%{member_scope | hidden: []}, ctx.organisation) == @not_found
      assert checks(instance, ctx.organisation) == @not_found
    end

    test "is not found for a subject that is no organisation", ctx do
      assert checks(ctx.owner, ctx.shop) == @not_found
    end

    # `Access.check_place/3` returns this before the rule runs, so this test passes without
    # the rule.
    test "a scope with no place is not found", ctx do
      assert checks(nil, ctx.organisation) == @not_found

      assert checks(Apiary.Accounts.Scope.for_user(ctx.owner_user), ctx.organisation) ==
               @not_found
    end
  end

  describe "may/2 and shown?/1 by every kind of scope" do
    # The results before the rule moved into `Apiary.Access.check/3`, and after.
    test "a scope with no organisation is not found, before any call to Access", ctx do
      scope = Apiary.Accounts.Scope.for_user(ctx.owner_user)
      assert answers(scope)[:read] == {:error, :not_found}
      assert answers(scope)[:write] == {:error, :not_found}
      assert answers(scope)[:use] == {:error, :not_found}
      refute OrganisationSecrets.shown?(scope)
      refute OrganisationSecrets.shown?(nil)
    end

    test "the instance's scope: forbidden with the feature, else not found", ctx do
      scope = Apiary.Accounts.Scope.for_instance(ctx.organisation)
      forbidden = {:error, :forbidden}
      assert answers(scope) == %{read: forbidden, write: forbidden, use: forbidden}

      grant!(ctx.organisation, false)
      not_found = {:error, :not_found}
      assert answers(scope) == %{read: not_found, write: not_found, use: not_found}
    end

    test "an access key's scope, whose organisation is not loaded, is not found", ctx do
      %{access_key: key} = Apiary.AccessKeysFixtures.access_key_fixture(ctx.owner)
      scope = Apiary.Accounts.Scope.for_access_key(key)
      not_found = {:error, :not_found}

      assert answers(scope) == %{read: not_found, write: not_found, use: not_found}
      assert answers(%{scope | organisation: ctx.organisation})[:read] == {:error, :forbidden}

      grant!(ctx.organisation, false)
      assert answers(%{scope | organisation: ctx.organisation})[:read] == not_found
    end

    test "an instance admin with features shown by who asks", ctx do
      ApiaryPro.Flags.put_feature_visibility(true)
      %{user: admin} = instance_admin_fixture()
      assert answers(in_org(admin, ctx.organisation))[:read] == :ok
      assert OrganisationSecrets.shown?(in_org(admin, ctx.organisation))

      grant!(ctx.organisation, false)
      assert answers(in_org(admin, ctx.organisation))[:read] == {:error, :not_found}
      refute OrganisationSecrets.shown?(in_org(admin, ctx.organisation))
    end

    @tag needs: :managed_organisations
    test "an operator's owner in the operator, and in a client with features by who asks" do
      ApiaryPro.Flags.put_feature_visibility(true)
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      grant!(operator.organisation)
      grant!(client.organisation, false)
      not_found = {:error, :not_found}

      assert answers(scope_in(operator.user, operator.organisation)) ==
               %{read: :ok, write: :ok, use: :ok}

      assert answers(scope_in(operator.user, client.organisation)) ==
               %{read: not_found, write: not_found, use: not_found}
    end
  end

  describe "the feature" do
    test "is the organisation's variables': no grant and no separate feature" do
      refute :organisation_secrets in Ecto.Enum.values(Grant, :feature)
      refute Keyword.has_key?(ApiaryPro.Features.features(), :organisation_secrets)
      refute :organisation_secrets in Features.all()

      for action <- [:read, :write, :use] do
        assert Apiary.Access.action(:"organisation_secret.#{action}").feature ==
                 :organisation_variables
      end
    end
  end
end
