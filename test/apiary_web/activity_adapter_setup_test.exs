defmodule ApiaryWeb.ActivityAdapterSetupTest do
  # The Activity line of an adapter's set-up started by an instance admin
  # (`adapter.setup`): its label in the filter, offered there, and its sentence.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  test "the label of a set-up started, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"adapter.setup") == "Adapter set-up started"
    assert Core.label(:"adapter.setup", scope) == "Adapter set-up started"
    assert Core.offered?(scope, :"adapter.setup")
  end

  test "the sentence" do
    entry = %Entry{
      action: "adapter.setup",
      actor_kind: :person,
      details: %{"name" => "Acme tracker", "public_id" => "na_0123456789abcdef"}
    }

    assert Enum.find_value(Describer.describers(), & &1.sentence(:"adapter.setup", entry, %{})) ==
             "Started setting up an adapter"
  end
end
