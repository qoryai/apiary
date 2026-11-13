defmodule ApiaryWeb.FeaturesEventGateTest do
  # An open page whose feature goes off (`ApiaryWeb.Features`): an event sent before the
  # page is moved away does nothing. The node's copy of the features changes here with no
  # broadcast, so the page stays open for the event. Not async: the features are the whole
  # node's, and a test of an instance admin hides the instance's organisation, a row every
  # test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.{MachineTypes, Policy}

  @moduletag needs: :factory
  @moduletag :feature_sets

  setup do
    previous = Application.get_env(:apiary, :features)
    Process.put(:previous_features, previous)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)
    :ok
  end

  # The node's copy as the test began, to read back what the page wrote.
  defp previous_features, do: Process.get(:previous_features)

  # The node's copy without `feature` and the features that need it.
  defp turn_off(feature) do
    enabled = Apiary.Features.enabled()

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(enabled, enabled -- [feature])
    )
  end

  describe "an Instance page" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "Machine types adds no type once factory is off, and moves to General",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/machine-types/new")
      turn_off(:factory)

      view
      |> form("#machine-type-form",
        type: %{
          name: "Large",
          key: "large",
          vcpus: "4",
          memory_gib: "16",
          disk_gib: "60",
          arch: "amd64"
        }
      )
      |> render_submit()

      flash = assert_redirect(view, ~p"/instance/general")

      assert flash["error"] ==
               "That page is no longer shown: its feature is off in Instance settings › Features."

      Application.put_env(:apiary, :features, previous_features())
      refute Enum.any?(MachineTypes.list(), &(&1.key == "large"))
    end
  end

  describe "an organisation page" do
    setup :register_and_log_in_user

    test "the policy's rule form adds no rule once security is off, and moves away",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, workspace_path(scope, "/policy/rules/new"))
      render_async(view, 5_000)
      turn_off(:security)

      view |> form("#policy-rule-form", rule: %{host: "api.example"}) |> render_submit()

      flash = assert_redirect(view, ~p"/#{scope.organisation}")
      assert flash["error"] == "That page is no longer shown in #{scope.organisation.name}."

      Application.put_env(:apiary, :features, previous_features())
      refute Enum.any?(Policy.list_rules(scope, nil), &(&1.host == "api.example"))
    end
  end
end
