defmodule ApiaryPro.FeatureVisibilityAuditTest do
  # A change of what an organisation or a client is shown, as the audit trail records it
  # and the Activity page says it: while `ApiaryPro.Flags.feature_visibility?/0` is on, a
  # new entry carries `shown: true` in its details and is said as a change of what is
  # shown; an entry without the mark keeps the words it was written under, and with the
  # switch off every entry is said as before.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Features, Repo}
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryProWeb.ActivityDescriber

  @moduletag with_features: Features.all()

  @names %{organisations: %{}, workspaces: %{}, users: %{}}

  defp entries(organisation_id, action) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^organisation_id and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp said(action, entry), do: ActivityDescriber.sentence(action, entry, @names)

  describe "the entry of a change" do
    test "of an organisation is marked shown with the switch on, and not with it off" do
      %{instance_scope: admin} = suite_instance_admin()
      %{organisation: organisation} = sign_up_fixture()

      Flags.put_feature_visibility(false)
      {:ok, _} = Grants.set_organisation(admin, organisation.id, ["observability"])

      Flags.put_feature_visibility(true)
      {:ok, _} = Grants.set_organisation(admin, organisation.id, ["observability", "security"])

      assert [old, new] = entries(organisation.id, "instance.grant_features")
      refute Map.has_key?(old.details || %{}, "shown")
      assert new.details["shown"] == true
      assert new.after["features"] == ["observability", "security"]
    end

    test "of a client is marked shown with the switch on, and not with it off" do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")

      Flags.put_feature_visibility(false)
      {:ok, _} = Grants.set_client(operator.scope, client.organisation.id, ["observability"])

      Flags.put_feature_visibility(true)

      {:ok, _} =
        Grants.set_client(operator.scope, client.organisation.id, ["observability", "security"])

      assert [old, new] = entries(client.organisation.id, "client.grant_features")
      refute Map.has_key?(old.details || %{}, "shown")
      assert new.details["shown"] == true
    end
  end

  describe "the Activity page's words" do
    test "with the switch off, for every entry, as before" do
      Flags.put_feature_visibility(false)

      assert ActivityDescriber.label(:"client.grant_features") == "Client's features changed"

      assert ActivityDescriber.label(:"instance.grant_features") ==
               "Features changed"

      for details <- [nil, %{}, %{"shown" => true}] do
        assert said(:"client.grant_features", %Entry{details: details}) ==
                 "Changed the features its operator grants it"

        assert said(:"instance.grant_features", %Entry{details: details}) ==
                 "Changed the organisation's features"
      end
    end

    test "with the switch on, new for an entry marked shown, and old for one that is not" do
      Flags.put_feature_visibility(true)

      assert ActivityDescriber.label(:"client.grant_features") ==
               "Client's shown features changed"

      assert ActivityDescriber.label(:"instance.grant_features") ==
               "Shown features changed"

      shown = %Entry{details: %{"shown" => true}}

      assert said(:"client.grant_features", shown) ==
               "Changed the features its operator shows it"

      assert said(:"instance.grant_features", shown) ==
               "Changed the features the organisation is shown"

      for details <- [nil, %{}] do
        assert said(:"client.grant_features", %Entry{details: details}) ==
                 "Changed the features its operator grants it"

        assert said(:"instance.grant_features", %Entry{details: details}) ==
                 "Changed the organisation's features"
      end
    end
  end
end
