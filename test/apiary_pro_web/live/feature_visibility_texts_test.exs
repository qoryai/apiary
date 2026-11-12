defmodule ApiaryProWeb.FeatureVisibilityTextsTest do
  # The words of the Features pages and the Clients list: of what is shown and hidden while
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
      "An operator has only what you grant it, and grants its clients within that. A feature a new release adds reaches it once you grant it here.",
      "Its people see only the features you show here, and it shows its clients only those. Hidden features still work for its machines and runs. A feature a new release adds is hidden from it until you show it here."
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
    },
    above: {
      "Tervaskel Works can grant only what it has itself.",
      "Tervaskel Works can show only what it is shown."
    },
    refused: {
      "Only an owner of Tervaskel Works grants its clients their features.",
      "Only an owner of Tervaskel Works chooses what its clients are shown."
    },
    filter: {"It has every one chosen", "Shown all chosen"},
    chip: {"Has Security policy", "Security policy shown"}
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

      test "Clients › Features says what the client's people see", _ctx do
        operator = operator_fixture(%{organisation_name: "Tervaskel Works"})
        client = client_fixture(operator.scope, "Acme")
        conn = log_in_user(build_conn(), operator.user)

        {:ok, lv, _html} =
          live(conn, ~p"/#{operator.organisation}/clients/#{client.organisation.id}/features")

        render_async(lv)

        if @on do
          assert has_element?(
                   lv,
                   "#client-features-page",
                   "People in Acme see only the features you show here, of those Tervaskel Works is shown; people of Tervaskel Works see in it what Tervaskel Works sees. Hidden features still work for its machines and runs. A feature a new release adds is hidden from it until you show it here."
                 )
        else
          assert has_element?(
                   lv,
                   "#client-features-page",
                   "The client has only what Tervaskel Works grants it, of what Tervaskel Works has. A feature a new release adds reaches it once you grant it here."
                 )
        end

        # Sent a feature the operator is not shown, the save is refused.
        {said, _not_said} = words(:above, @on)

        render_click(lv, "save_client_features", %{
          "client_id" => client.organisation.id,
          "features" => %{"observability" => "true", "managed_organisations" => "true"}
        })

        assert render(lv) =~ Phoenix.HTML.html_escape(said) |> Phoenix.HTML.safe_to_string()
      end

      test "Clients › Features says why a save without Runs stays", _ctx do
        operator = operator_fixture()
        client = client_fixture(operator.scope, "Acme")
        conn = log_in_user(build_conn(), operator.user)
        {said, not_said} = words(:needs_runs, @on)

        {:ok, lv, _html} =
          live(conn, ~p"/#{operator.organisation}/clients/#{client.organisation.id}/features")

        render_async(lv)

        lv
        |> form("#client-features-form", %{
          "features" => %{
            "observability" => "false",
            "security" => "true",
            "organisation_policy" => "false"
          }
        })
        |> render_submit()

        assert has_element?(lv, "#client-features-error", said)
        refute has_element?(lv, "#client-features-error", not_said)
      end

      test "Clients › Features tells an admin of the operator who chooses", _ctx do
        operator = operator_fixture(%{organisation_name: "Tervaskel Works"})
        client = client_fixture(operator.scope, "Acme")
        %{user: admin} = member_fixture(operator.scope, :admin)
        conn = log_in_user(build_conn(), admin)
        {said, _not_said} = words(:refused, @on)

        {:ok, lv, _html} = live(conn, ~p"/#{operator.organisation}/clients")
        render_async(lv)
        render_patch(lv, ~p"/#{operator.organisation}/clients/#{client.organisation.id}/features")
        assert has_element?(lv, "#flash-error", said)
      end

      test "the Clients list names its filter and its chips", _ctx do
        operator = operator_fixture()
        _client = client_fixture(operator.scope, "Acme")
        conn = log_in_user(build_conn(), operator.user)
        {sub, not_sub} = words(:filter, @on)
        {chip, not_chip} = words(:chip, @on)

        {:ok, lv, _html} = live(conn, ~p"/#{operator.organisation}/clients?features=security")
        render_async(lv)

        assert has_element?(lv, "#clients-filter", sub)
        refute has_element?(lv, "#clients-filter", not_sub)
        assert has_element?(lv, "#clients-tokens", chip)
        refute has_element?(lv, "#clients-tokens", not_chip)
      end
    end
  end
end
