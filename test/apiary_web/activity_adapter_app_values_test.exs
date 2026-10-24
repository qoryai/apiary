defmodule ApiaryWeb.ActivityAdapterAppValuesTest do
  # The Activity lines of an adapter's key storing the secrets the adapter keeps in Qory
  # Apiary (`adapter.app_values_set`) and reading them back (`adapter.app_values_seal`):
  # their labels in the filter, offered there, and their sentences, which have the
  # revision and no value.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  test "the label of the app values stored, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"adapter.app_values_set") == "Adapter app values stored"
    assert Core.label(:"adapter.app_values_set", scope) == "Adapter app values stored"
    assert Core.offered?(scope, :"adapter.app_values_set")
  end

  test "the sentence" do
    entry = %Entry{
      action: "adapter.app_values_set",
      actor_kind: :access_key,
      details: %{
        "reference" => "builtin:sec_0123456789abcdef",
        "names" => ["signing-key"],
        "revision" => 2,
        "replaced" => true
      }
    }

    assert Enum.find_value(
             Describer.describers(),
             & &1.sentence(:"adapter.app_values_set", entry, %{})
           ) == "Stored the adapter's app values, revision 2"
  end

  test "the label of the app values sent, offered in the filter, and its sentence" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"adapter.app_values_seal") == "Adapter app values sent"
    assert Core.offered?(scope, :"adapter.app_values_seal")

    entry = %Entry{
      action: "adapter.app_values_seal",
      actor_kind: :access_key,
      details: %{"access_key_id" => "ak_0123456789abcdef", "names" => [], "revision" => 3}
    }

    assert Enum.find_value(
             Describer.describers(),
             & &1.sentence(:"adapter.app_values_seal", entry, %{})
           ) == "Sent the adapter its app values, sealed to its key, revision 3"

    # A read with no secret stored has no revision, and no sentence.
    assert Enum.find_value(
             Describer.describers(),
             & &1.sentence(
               :"adapter.app_values_seal",
               %{entry | details: %{"revision" => nil}},
               %{}
             )
           ) == nil
  end
end
