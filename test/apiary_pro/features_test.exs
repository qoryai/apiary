defmodule ApiaryPro.FeaturesTest do
  # The edition's features (`ApiaryPro.Features`) among the core's
  # (`Apiary.FeaturesTest`): listed after them, and named in `QORY_FEATURES` as any other.
  use ExUnit.Case, async: true

  alias Apiary.Features

  describe "the edition's features" do
    test "managed_organisations and the organisation's policy and variables are the edition's, built and on by default" do
      edition = Enum.map(Apiary.Edition.features(), &elem(&1, 0))

      assert :managed_organisations in edition
      assert :organisation_policy in edition
      assert :organisation_variables in edition

      assert Features.built() == [
               :observability,
               :security,
               :secrets,
               :path_rules,
               :factory,
               :workflow_model,
               :managed_organisations,
               :organisation_policy,
               :organisation_variables
             ]

      refute :organisation_variables in Features.opt_in()
    end

    test "every feature is a grant's or the instance's alone, never both nor neither" do
      grantable = Ecto.Enum.values(ApiaryPro.Grants.Grant, :feature)
      instance_switched = ApiaryPro.Features.instance_switched()

      for feature <- Features.all() do
        assert feature in grantable != feature in instance_switched, "#{feature}"
      end

      assert instance_switched -- Features.all() == []
    end

    test "the organisation's policy needs the security policy" do
      assert Features.needs(:organisation_policy) == [:security]
      assert Features.closed([:observability, :organisation_policy]) == [:observability]

      assert Features.closed([:observability, :security, :organisation_policy]) == [
               :observability,
               :security,
               :organisation_policy
             ]
    end

    test "the organisation's variables need the security policy and secrets" do
      assert Features.needs(:organisation_variables) == [:security, :secrets]

      assert Features.closed([:observability, :organisation_variables]) == [:observability]

      assert Features.closed([:observability, :security, :organisation_variables]) == [
               :observability,
               :security
             ]

      assert Features.closed([:observability, :security, :secrets, :organisation_variables]) ==
               [:observability, :security, :secrets, :organisation_variables]
    end

    test "QORY_FEATURES names them as any other feature, and an error does not" do
      assert Features.parse("observability,security,managed_organisations,organisation_policy") ==
               {:ok, [:observability, :security, :managed_organisations, :organisation_policy]}

      assert {:ok, all} = Features.parse("all")

      assert Features.parse(
               "all-managed_organisations,organisation_policy,organisation_variables"
             ) ==
               {:ok,
                all -- [:managed_organisations, :organisation_policy, :organisation_variables]}

      # Without security, every feature that needs it is left out too: the core's, then
      # the organisation's policy, the last one left.
      assert {:error, reason} = Features.parse("all-security")
      assert reason =~ "secrets needs security"

      assert {:error, reason} =
               Features.parse(
                 "all-security,secrets,path_rules,factory,registry,workflow_model,organisation_variables"
               )

      assert reason =~ "organisation_policy needs security"

      assert {:error, reason} = Features.parse("observability,organisation_variables")
      assert reason =~ "organisation_variables needs security"

      # On by default: `all` turns it on, with what it needs; a list turns it on only where
      # it names it, with what it needs.
      assert :organisation_variables in all
      assert :secrets in all

      assert {:error, reason} =
               Features.parse("observability,security,organisation_variables")

      assert reason =~ "organisation_variables needs secrets"

      assert Features.parse("observability,security,secrets,organisation_variables") ==
               {:ok, [:observability, :security, :secrets, :organisation_variables]}

      assert {:error, reason} = Features.parse("observability,dispatch")
      refute reason =~ "managed_organisations"
      refute reason =~ "organisation_policy"
      refute reason =~ "organisation_variables"
    end
  end
end
