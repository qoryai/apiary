defmodule ApiaryPro.FeatureGrantsTest do
  # Not async: the instance's features are the node's, and every test here asks on an
  # instance with all of them. The features are compared as a page shows them, the built
  # ones a grant can name (`built/1`): one not built yet keeps whatever its grants say, and
  # one only the instance switches is no grant's.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Repo}
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Grants, Operators, Suspensions}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  @built [
    :observability,
    :security,
    :managed_organisations,
    :organisation_policy,
    :organisation_variables
  ]

  defp built(features) do
    shown = Features.built() -- ApiaryPro.Features.instance_switched()
    Enum.filter(features, &(&1 in shown))
  end

  defp of(organisation), do: built(ApiaryPro.Features.of(organisation))

  # What the instance has, without its switch of the whole instance, which no organisation
  # is shown.
  defp instance_features, do: Features.enabled() -- [:feature_visibility]

  describe "the chain" do
    test "an organisation with no operator follows the instance, but for what is taken away" do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      admin = instance_admin_fixture()

      assert of(organisation) == @built
      assert Access.can?(owner, :"security_policy.edit", owner.workspace)

      assert {:ok, features} =
               Grants.set_organisation(admin.instance_scope, organisation.id, [
                 "observability",
                 "managed_organisations"
               ])

      assert built(features) == [:observability, :managed_organisations]
      assert of(organisation) == [:observability, :managed_organisations]

      # A scope loaded before asks again: the security policy is absent there now.
      assert {:error, :not_found} =
               Access.authorize(owner, :"security_policy.edit", owner.workspace)

      refute Access.can?(
               scope_in(owner.user, organisation, owner.workspace),
               :"security_policy.read",
               owner.workspace
             )
    end

    test "an operator has what it is granted; an organisation it operates in follows the instance" do
      operator = operator_fixture()
      admin = instance_admin_fixture()
      client = client_fixture(operator.scope)

      # Made an operator, it is granted what it had. The organisation whose workspace it
      # operates is shown what the instance has, as any organisation.
      assert of(operator.organisation) == @built
      assert of(client.organisation) == @built

      # An operator keeps `managed_organisations` whatever the form says of it, and the
      # organisation whose workspace it operates is not narrowed with it.
      assert {:ok, features} =
               Grants.set_organisation(admin.instance_scope, operator.organisation.id, [
                 :observability
               ])

      assert built(features) == [:observability, :managed_organisations]
      assert of(operator.organisation) == [:observability, :managed_organisations]
      assert of(client.organisation) == @built

      # An instance admin takes features away from it as from any organisation.
      assert {:ok, features} =
               Grants.set_organisation(admin.instance_scope, client.organisation.id, [
                 "observability"
               ])

      assert built(features) == [:observability]
      assert of(client.organisation) == [:observability]
    end

    test "an operator's managed_organisations is not the grants': it is its kind" do
      operator = operator_fixture()
      admin = instance_admin_fixture()

      assert {:error, :above} =
               Grants.set_organisation(admin.instance_scope, operator.organisation.id, [
                 "observability",
                 "managed_organisations"
               ])

      refute :managed_organisations in Grants.shown(operator.organisation)
      assert :managed_organisations in of(operator.organisation)
    end

    test "a suspended organisation is granted nothing" do
      %{organisation: organisation} = sign_up_fixture()
      admin = instance_admin_fixture()

      {:ok, _} = Suspensions.suspend_organisation(admin.instance_scope, organisation.id)

      assert {:error, :suspended} =
               Grants.set_organisation(admin.instance_scope, organisation.id, ["observability"])

      assert of(organisation) == @built
    end

    test "a feature is kept only with what it needs" do
      %{organisation: organisation} = sign_up_fixture()
      admin = instance_admin_fixture()

      assert {:error, :needs} =
               Grants.set_organisation(admin.instance_scope, organisation.id, ["security"])

      # The organisation's policy needs the security policy, which needs observability.
      assert {:error, :needs} =
               Grants.set_organisation(admin.instance_scope, organisation.id, [
                 "observability",
                 "organisation_policy"
               ])

      # The organisation's variables need the security policy, and `secrets`, which no
      # form names: the instance has it, so a form without it keeps them.
      assert {:error, :needs} =
               Grants.set_organisation(admin.instance_scope, organisation.id, [
                 "observability",
                 "organisation_variables"
               ])

      assert {:ok, features} =
               Grants.set_organisation(admin.instance_scope, organisation.id, [
                 "observability",
                 "security",
                 "organisation_variables"
               ])

      assert built(features) == [:observability, :security, :organisation_variables]

      assert {:ok, features} =
               Grants.set_organisation(admin.instance_scope, organisation.id, [
                 "observability",
                 "security",
                 "organisation_policy"
               ])

      assert built(features) == [:observability, :security, :organisation_policy]

      assert {:error, :above} =
               Grants.set_organisation(admin.instance_scope, organisation.id, ["no_such"])
    end

    test "the instance organisation has everything, and is granted nothing" do
      admin = instance_admin_fixture()
      assert ApiaryPro.Features.of(instance_organisation()) == instance_features()

      assert {:error, :forbidden} =
               Grants.set_organisation(admin.instance_scope, instance_organisation().id, [
                 "observability"
               ])
    end
  end

  # No grant can name an opt-in feature: the core's `registry`, the one left, only the
  # instance switches. So the stored grant here is of a feature the instance lacks, which
  # a page does not show either.
  @tag with_features: Features.all() -- [:organisation_variables]
  test "a stored grant of a feature the instance lacks is kept and not shown: a page does not change it" do
    operator = operator_fixture()
    admin = instance_admin_fixture()
    organisation = operator.organisation
    stored = from(g in Grant, where: g.organisation_id == ^organisation.id)

    Repo.delete_all(from g in stored, where: g.feature == :organisation_variables)

    Repo.insert!(%Grant{
      organisation_id: organisation.id,
      feature: :organisation_variables,
      granted: true
    })

    refute :organisation_variables in Grants.offered(organisation)
    refute :organisation_variables in Grants.shown(organisation)

    {:ok, _} = Grants.set_organisation(admin.instance_scope, organisation.id, ["observability"])

    assert [true] =
             Repo.all(
               from g in stored,
                 where: g.feature == :organisation_variables,
                 select: g.granted
             )
  end

  describe "a feature no grant can name" do
    test "secrets is shown to an operator and an organisation it operates in, and their people, with no row" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      refute :secrets in Ecto.Enum.values(Grant, :feature)

      for organisation <- [operator.organisation, client.organisation] do
        assert :secrets in ApiaryPro.Features.of(organisation)
        refute :secrets in Grants.shown(organisation)
      end

      all = ApiaryPro.Features.of_all([operator.organisation, client.organisation])
      assert :secrets in all[operator.organisation.id]
      assert :secrets in all[client.organisation.id]

      # The operator's people at home and in the operated workspace, and the owner of the
      # organisation operated. In the operated workspace, its secrets are not there for the
      # operator's people.
      for scope <- [operator.scope, client.scope, client.owner.scope] do
        refute :secrets in scope.hidden
      end

      for scope <- [operator.scope, client.owner.scope],
          do: assert(Access.can?(scope, :"secret.read", scope.workspace))

      refute Access.can?(client.scope, :"secret.read", client.scope.workspace)

      assert Access.can?(client.owner.scope, :"secret.write", client.workspace)
    end

    test "with secrets shown, organisation_variables follows the grants of each organisation" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      # The organisation whose workspace the operator operates is shown the organisation's
      # variables, as the instance has them; a page offers a box for them.
      assert :organisation_variables in ApiaryPro.Features.of(operator.organisation)
      assert :organisation_variables in ApiaryPro.Features.of(client.organisation)
      assert :organisation_variables in Grants.offered(client.organisation)
      assert :organisation_variables in Grants.shown(client.organisation)
      refute :organisation_variables in client.owner.scope.hidden

      assert Access.can?(
               client.owner.scope,
               :"organisation_variable.edit",
               client.organisation
             )

      # Not granted to the operator, it is hidden from the operator alone.
      Repo.delete_all(
        from g in Grant,
          where:
            g.organisation_id == ^operator.organisation.id and
              g.feature == :organisation_variables
      )

      refute :organisation_variables in ApiaryPro.Features.of(operator.organisation)
      assert :organisation_variables in ApiaryPro.Features.of(client.organisation)
      assert :secrets in ApiaryPro.Features.of(client.organisation)
    end

    @tag with_features: [:observability, :security, :managed_organisations, :organisation_policy]
    test "without secrets on the instance, nothing changes" do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      shown = [:observability, :security, :managed_organisations, :organisation_policy]
      assert ApiaryPro.Features.of(operator.organisation) == shown
      assert ApiaryPro.Features.of(client.organisation) == shown

      for scope <- [operator.scope, client.scope, client.owner.scope] do
        assert {:error, :not_found} = Access.authorize(scope, :"secret.read", scope.workspace)
      end
    end
  end

  describe "who may" do
    test "an owner of an organisation may not grant it features" do
      %{scope: owner, organisation: organisation} = sign_up_fixture()

      assert {:error, :not_found} =
               Grants.set_organisation(owner, organisation.id, ["observability"])
    end
  end

  describe "where an organisation sits" do
    test "made an organisation again, an operator keeps what it had, opt-out" do
      operator = operator_fixture()
      admin = instance_admin_fixture()

      {:ok, _} =
        Grants.set_organisation(admin.instance_scope, operator.organisation.id, [
          "observability"
        ])

      {:ok, organisation} =
        Operators.change_kind(admin.instance_scope, operator.organisation.id, :organisation)

      assert of(organisation) == [:observability, :managed_organisations]
    end

    test "made an operator, an organisation is granted what it has, managed_organisations too" do
      %{organisation: organisation} = sign_up_fixture()
      admin = instance_admin_fixture()

      {:ok, _} = Grants.set_organisation(admin.instance_scope, organisation.id, ["observability"])

      {:ok, operator} = Operators.change_kind(admin.instance_scope, organisation.id, :operator)

      assert of(operator) == [:observability, :managed_organisations]

      # A feature not built yet reaches no operator until it is granted.
      assert Enum.all?(
               Features.all() -- Features.built(),
               &(&1 not in ApiaryPro.Features.of(operator))
             )

      # A new operator is granted what the instance has, the organisation's variables
      # among it, and is shown `secrets`, `path_rules`, `factory`, `registry` and
      # `workflow_model`, which no grant names.
      assert ApiaryPro.Features.of(operator_fixture().organisation) -- @built ==
               [:secrets, :path_rules, :factory, :registry, :workflow_model]
    end
  end

  describe "the trail" do
    test "each change is one entry, of the built features, of what it changed; none for no change" do
      %{organisation: organisation} = sign_up_fixture()
      admin = instance_admin_fixture()

      {:ok, _} = Grants.set_organisation(admin.instance_scope, organisation.id, ["observability"])
      {:ok, _} = Grants.set_organisation(admin.instance_scope, organisation.id, ["observability"])

      assert [entry] =
               Repo.all(
                 from e in Entry,
                   where:
                     e.organisation_id == ^organisation.id and
                       e.action == "instance.grant_features"
               )

      assert entry.before["features"] == [
               "observability",
               "security",
               "managed_organisations",
               "organisation_policy",
               "organisation_variables"
             ]

      assert entry.after["features"] == ["observability"]
      assert entry.remote_ip == nil
    end
  end
end
