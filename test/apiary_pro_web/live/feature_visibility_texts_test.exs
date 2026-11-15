defmodule ApiaryProWeb.FeatureVisibilityTextsTest do
  # The words of Instance settings › Organisations › Features: of what is shown and hidden while
  # `ApiaryPro.Flags.feature_visibility?/0` is on, of what is granted and taken away while
  # it is off. Each case is asked both ways, for the test's process and the LiveViews it
  # starts (`ApiaryPro.Flags.put_feature_visibility/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  @words %{
    operator: {
      "An operator has only what you grant it. A feature a new release adds reaches it once you grant it here.",
      "Its people see only the features you show here. Hidden features still work for its machines and runs. A feature a new release adds is hidden from it until you show it here."
    },
    organisation: {
      "An organisation with no operator has what this instance has, but for what you take away here. A feature a new release adds reaches it.",
      "Its people see every feature this instance has, but those you hide here. Hidden features still work for its machines and runs. A feature a new release adds is shown to it."
    },
    client_on_instance: {
      "A client's features are its operator's to grant.",
      "A client's operator chooses which features it is shown."
    },
    needs_runs: {
      "Every other feature needs Runs: keep it, or take them all away.",
      "Every other feature needs Runs: show it, or hide them all."
    }
  }

  # The words for `key`, with the switch `on?`, and those it must not show.
  defp words(key, on?) do
    {off, on} = Map.fetch!(@words, key)
    if on?, do: {on, off}, else: {off, on}
  end

  for on? <- [false, true] do
    @on on?

    describe "with the switch #{if on?, do: "on", else: "off"}" do
      setup %{conn: conn} do
        Flags.put_feature_visibility(@on)
        admin = suite_instance_admin()
        %{conn: log_in_user(conn, admin.user), admin: admin}
      end

      test "Instance › Organisations › Features says what an operator is shown", ctx do
        operator = operator_fixture()
        {said, not_said} = words(:operator, @on)

        {:ok, lv, _html} =
          live(ctx.conn, ~p"/instance/organisations/#{operator.organisation.id}/features")

        render_async(lv)
        assert has_element?(lv, "#organisation-page", said)
        refute has_element?(lv, "#organisation-page", not_said)
      end

      test "Instance › Organisations › Features says what an organisation with no operator is shown",
           ctx do
        %{organisation: organisation} = sign_up_fixture()
        {said, not_said} = words(:organisation, @on)

        {:ok, lv, _html} =
          live(ctx.conn, ~p"/instance/organisations/#{organisation.id}/features")

        render_async(lv)
        assert has_element?(lv, "#organisation-page", said)
        refute has_element?(lv, "#organisation-page", not_said)
      end

      test "Instance › Organisations › Features says who chooses what a client is shown", ctx do
        operator = operator_fixture()
        client = client_fixture(operator.scope)
        {said, _not_said} = words(:client_on_instance, @on)

        {:ok, lv, _html} =
          live(ctx.conn, ~p"/instance/organisations/#{client.organisation.id}/features")

        render_async(lv)
        assert has_element?(lv, "#organisation-features-none", said)
      end

      test "Instance › Organisations › Features says why a save without Runs stays", ctx do
        %{organisation: organisation} = sign_up_fixture()
        {said, _not_said} = words(:needs_runs, @on)

        {:ok, lv, _html} =
          live(ctx.conn, ~p"/instance/organisations/#{organisation.id}/features")

        render_async(lv)

        lv
        |> form("#organisation-features-form", %{
          "features" => %{
            "observability" => "false",
            "security" => "true",
            "managed_organisations" => "false",
            "organisation_policy" => "false"
          }
        })
        |> render_submit()

        assert has_element?(lv, "#organisation-features-error", said)
      end
    end
  end
end
