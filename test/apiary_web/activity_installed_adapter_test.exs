defmodule ApiaryWeb.ActivityInstalledAdapterTest do
  # The Activity lines of an adapter installed with Qory Apiary: `adapter.install`, its
  # label in the filter, offered there, and its sentence; the first code the instance
  # gives it (`access_key.create_code` with `installed`); and a code the instance cancels
  # (`access_key.cancel_code` by the instance), beside a person's, which say as before.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer
  alias ApiaryWeb.Activity.Describer.Core

  defp shown(action, actor, details),
    do:
      Enum.find_value(
        Describer.describers(),
        & &1.sentence(
          action,
          %Entry{action: to_string(action), actor_kind: actor, details: details},
          %{}
        )
      )

  test "the label of an install, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"adapter.install") == "Adapter installed"
    assert Core.label(:"adapter.install", scope) == "Adapter installed"
    assert Core.offered?(scope, :"adapter.install")
  end

  test "the sentences" do
    assert shown(:"adapter.install", :instance, nil) ==
             "Added an adapter installed with Qory Apiary"

    assert shown(:"access_key.create_code", :instance, %{"installed" => true}) ==
             "Gave an installed adapter a new one-time code"

    assert shown(:"access_key.cancel_code", :instance, %{"code_id" => Ecto.UUID.generate()}) ==
             "Cancelled an adapter's code it no longer needs"

    assert shown(:"access_key.create_code", :person, nil) == "Made a command to connect a node"

    assert shown(:"access_key.cancel_code", :person, %{"code_id" => Ecto.UUID.generate()}) ==
             "Cancelled a command to connect a node"
  end
end
