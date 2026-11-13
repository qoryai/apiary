defmodule ApiaryProWeb.FeatureGrantsLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features

  @moduletag with_features: Features.all()

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # The features of `organisation` that are built and that a grant names, the ones the form
  # offers: a feature not built yet, and one only the instance switches, are left out of
  # what the tests compare.
  defp built_of(organisation),
    do: Enum.filter(ApiaryPro.Features.of(organisation), &(&1 in offered()))

  defp offered, do: Features.built() -- ApiaryPro.Features.instance_switched()

  test "every built feature a grant names has a name and a sentence, so no checkbox and no list is left without one" do
    for feature <- offered() do
      assert is_binary(ApiaryProWeb.FeatureComponents.label(feature)), "#{feature} has no name"

      assert is_binary(ApiaryProWeb.FeatureComponents.description(feature)),
             "#{feature} has no sentence"
    end
  end

  describe "a client's features, on its operator's Clients page" do
    setup %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      %{conn: log_in_user(conn, operator.user), operator: operator, client: client}
    end

    test "an owner of the operator grants a client its features", ctx do
      %{operator: operator, client: client} = ctx
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{operator.organisation}/clients")
      render_async(lv)

      assert has_element?(lv, "#client-#{client.organisation.id}-features", "Security policy")
      words = lv |> element("#client-#{client.organisation.id}-features") |> render()
      refute words =~ ~r/,\s*<\/span>/

      lv |> element("#client-#{client.organisation.id}-features-button") |> render_click()
      assert_patch(lv, ~p"/#{operator.organisation}/clients/#{client.organisation.id}/features")
      # A page of the clients, never a dialog: the list is not under it.
      refute has_element?(lv, "#clients")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Features")
      assert has_element?(lv, "#client-features-save a#client-features-save-cancel", "Cancel")

      # Each box is named by its feature.
      assert has_element?(
               lv,
               "label[for=client-features-organisation_policy]",
               "Organisation policy"
             )

      # A client is never offered what makes an operator.
      assert has_element?(lv, "#client-features-observability")
      refute has_element?(lv, "#client-features-managed_organisations")
      # The organisation's variables have a box, as every feature a grant names.
      assert has_element?(lv, "#client-features-organisation_variables")

      lv
      |> form("#client-features-form", %{
        "features" => %{
          "observability" => "true",
          "security" => "false",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/#{operator.organisation}/clients")
      assert built_of(client.organisation) == [:observability]
      render_async(lv)
      refute has_element?(lv, "#client-#{client.organisation.id}-features", "Security policy")
    end

    test "a save that would leave a feature without Runs stays, why under the checkboxes",
         ctx do
      %{operator: operator, client: client} = ctx
      id = client.organisation.id
      path = ~p"/#{operator.organisation}/clients/#{id}/features"
      {:ok, lv, _html} = live(ctx.conn, path)
      render_async(lv)

      # Nothing refused yet: the group is neither invalid nor described by an error.
      refute has_element?(lv, "fieldset#client-features[aria-invalid]")
      refute has_element?(lv, "fieldset#client-features[aria-describedby]")
      refute has_element?(lv, "#client-features-error")

      lv
      |> form("#client-features-form", %{
        "features" => %{
          "observability" => "false",
          "security" => "true",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      # Refused, it stays: why is said under the checkboxes, not in a flash, and the group
      # is marked invalid and described by it, so the failed submit puts the caret in its
      # first checkbox and a screen reader reads why with the group.
      assert has_element?(
               lv,
               "fieldset#client-features > p#client-features-error:last-child",
               "Every other feature needs Runs: keep it, or take them all away."
             )

      assert has_element?(
               lv,
               ~s|fieldset#client-features[aria-invalid="true"][aria-describedby="client-features-error"]|
             )

      refute has_element?(lv, "#flash-error")
      assert has_element?(lv, "#client-features-form")
      # The boxes stay as they were sent, and nothing is saved.
      refute has_element?(lv, "#client-features-observability[checked]")
      assert has_element?(lv, "#client-features-security[checked]")
      refute has_element?(lv, "#client-features-organisation_policy[checked]")

      assert built_of(client.organisation) ==
               [:observability, :security, :organisation_policy, :organisation_variables]

      # The error stays until the next save: the client's row read again keeps it.
      send(lv.pid, {:membership_changed, operator.organisation.id})
      render_async(lv)
      assert has_element?(lv, "#client-features-error")
      refute has_element?(lv, "#client-features-observability[checked]")

      # Left and opened again, the page starts afresh.
      lv |> element("#client-features-save-cancel") |> render_click()
      assert_patch(lv, ~p"/#{operator.organisation}/clients")
      lv |> element("#client-#{id}-features-button") |> render_click()
      assert_patch(lv, path)
      refute has_element?(lv, "#client-features-error")
      assert has_element?(lv, "#client-features-observability[checked]")

      # Sent again as it should be, it saves and leaves.
      lv
      |> form("#client-features-form", %{
        "features" => %{
          "observability" => "true",
          "security" => "true",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/#{operator.organisation}/clients")
      assert built_of(client.organisation) == [:observability, :security]
    end

    test "a feature taken away is absent in the client: its page answers not found", ctx do
      %{operator: operator, client: client} = ctx

      {:ok, _} =
        ApiaryPro.Grants.set_client(operator.scope, client.organisation.id, [
          "observability"
        ])

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        live(ctx.conn, ~p"/#{client.organisation}/#{client.workspace}/policy")
      end
    end

    test "a client's page open on a feature taken away meanwhile says so and leaves", ctx do
      %{operator: operator, client: client} = ctx

      {:ok, policy, _html} =
        live(ctx.conn, ~p"/#{client.organisation}/#{client.workspace}/policy")

      {:ok, _} =
        ApiaryPro.Grants.set_client(operator.scope, client.organisation.id, ["observability"])

      assert {path, flash} = assert_redirect(policy)
      assert path == ~p"/#{client.organisation}"
      assert flash["error"] =~ "is no longer shown in"
    end

    test "an admin of the operator sees no Features button, and is refused the event", ctx do
      %{operator: operator, client: client} = ctx
      %{user: admin} = member_fixture(operator.scope, :admin)
      conn = log_in_user(build_conn(), admin)

      {:ok, lv, _html} = live(conn, ~p"/#{operator.organisation}/clients")
      render_async(lv)
      refute has_element?(lv, "#client-#{client.organisation.id}-features-button")

      render_click(lv, "save_client_features", %{
        "client_id" => client.organisation.id,
        "features" => %{"observability" => "true"}
      })

      assert built_of(client.organisation) ==
               [:observability, :security, :organisation_policy, :organisation_variables]
    end
  end

  describe "an organisation's and an operator's features, on Instance settings › Organisations" do
    setup %{conn: conn} do
      admin = suite_instance_admin()
      %{conn: log_in_user(conn, admin.user), admin: admin}
    end

    test "an instance admin takes a feature away from an organisation with no operator", ctx do
      %{organisation: organisation, scope: owner} = sign_up_fixture()

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)
      assert has_element?(lv, "#organisation-#{organisation.id}-features", "Security policy")

      lv |> element("#organisation-#{organisation.id}-features-button") |> render_click()
      assert_patch(lv, ~p"/instance/organisations/#{organisation.id}/features")
      render_async(lv)
      refute has_element?(lv, "#organisations")
      assert has_element?(lv, "#breadcrumb [aria-current=page]", "Features")

      lv
      |> form("#organisation-features-form", %{
        "features" => %{
          "observability" => "true",
          "security" => "false",
          "managed_organisations" => "true",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/instance/organisations")
      refute :security in ApiaryPro.Features.of(organisation)

      refute Apiary.Access.can?(
               Apiary.Access.reload(owner),
               :"security_policy.read",
               owner.workspace
             )
    end

    test "a save that would leave a feature without Runs stays, why under the checkboxes",
         ctx do
      %{organisation: organisation} = sign_up_fixture()
      had = built_of(organisation)
      path = ~p"/instance/organisations/#{organisation.id}/features"
      {:ok, lv, _html} = live(ctx.conn, path)
      render_async(lv)

      refute has_element?(lv, "fieldset#organisation-features[aria-invalid]")
      refute has_element?(lv, "#organisation-features-error")

      lv
      |> form("#organisation-features-form", %{
        "features" => %{
          "observability" => "false",
          "security" => "true",
          "managed_organisations" => "false",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      assert has_element?(
               lv,
               "fieldset#organisation-features > p#organisation-features-error:last-child",
               "Every other feature needs Runs: keep it, or take them all away."
             )

      assert has_element?(
               lv,
               ~s|fieldset#organisation-features[aria-invalid="true"][aria-describedby="organisation-features-error"]|
             )

      refute has_element?(lv, "#flash-error")
      assert has_element?(lv, "#organisation-features-form")
      refute has_element?(lv, "#organisation-features-observability[checked]")
      assert has_element?(lv, "#organisation-features-security[checked]")
      refute has_element?(lv, "#organisation-features-managed_organisations[checked]")
      assert built_of(organisation) == had

      # Left and opened again, the page starts afresh.
      lv |> element("#organisation-features-save-cancel") |> render_click()
      assert_patch(lv, ~p"/instance/organisations")
      lv |> element("#organisation-#{organisation.id}-features-button") |> render_click()
      assert_patch(lv, path)
      render_async(lv)
      refute has_element?(lv, "#organisation-features-error")
      assert has_element?(lv, "#organisation-features-observability[checked]")

      # Sent again as it should be, it saves and leaves.
      lv
      |> form("#organisation-features-form", %{
        "features" => %{
          "observability" => "true",
          "security" => "true",
          "managed_organisations" => "false",
          "organisation_policy" => "false",
          "organisation_variables" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/instance/organisations")
      assert built_of(organisation) == [:observability, :security]
    end

    test "a client offers no Features button: its operator grants it", ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      here = ctx.admin.instance_scope.organisation

      {:ok, lv, _html} = live(ctx.conn, ~p"/instance/organisations")
      render_async(lv)
      assert has_element?(lv, "#organisation-#{operator.organisation.id}-features-button")
      refute has_element?(lv, "#organisation-#{client.organisation.id}-features-button")
      refute has_element?(lv, "#organisation-#{here.id}-features-button")
    end

    test "a page open on a feature taken away meanwhile says so and leaves", ctx do
      %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()
      conn = log_in_user(build_conn(), user)
      {:ok, policy, _html} = live(conn, ~p"/#{organisation}/#{workspace}/policy")

      {:ok, _} =
        ApiaryPro.Grants.set_organisation(ctx.admin.instance_scope, organisation.id, [
          "observability"
        ])

      assert {path, flash} = assert_redirect(policy)
      assert path == ~p"/#{organisation}"
      assert flash["error"] =~ "is no longer shown in"
    end
  end

  describe "a workspace, on the organisation's settings" do
    # A workspace has its organisation's features: nobody takes them away from one.
    test "offers no Features, and the page that took them away is not found", %{conn: conn} do
      %{user: user, organisation: organisation, workspace: workspace} = sign_up_fixture()
      platform = workspace_fixture(organisation, "Platform")
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/#{organisation}/settings/workspaces")
      assert has_element?(lv, "#workspace-#{platform.id}-delete")
      refute has_element?(lv, "#workspace-#{workspace.id}-features-button")
      refute has_element?(lv, "#workspace-#{platform.id}-features-button")

      # No route has its address any more: the router's own answer, not found.
      assert conn
             |> get("/#{organisation.slug}/settings/workspaces/#{workspace.id}/features")
             |> html_response(404)
    end
  end
end
