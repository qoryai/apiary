defmodule ApiaryProWeb.OrganisationVariablesFeatureTest do
  @moduledoc """
  The organisation's variables, `organisation_variables`, on by default and needing the
  core's `secrets` (`ApiaryPro.Features`). Where `secrets` is off, as a `QORY_FEATURES`
  list without it leaves it, they are absent: their pages answer as paths that do not
  exist, and the settings, the palette and the Audit log's Action filter leave them out.
  A grant of them kept from before gives nothing there, and stays as it is stored when
  the client's Features page is saved again. On, each of them has them, and a new client
  of the instance organisation, which has every feature, is granted them as its operator
  has them.
  """
  # Not async: the tests switch the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias ApiaryPro.Grants.Grant
  alias ApiaryPro.OrganisationVariables
  alias ApiaryProWeb.ActivityDescriber

  # A `QORY_FEATURES` list without `secrets`: the organisation's variables are off with it.
  @off [:observability, :security, :managed_organisations, :organisation_policy]

  # The routes whose page belongs to the organisation's variables, each `{verb, path}`, and
  # the Secrets tab's, which belongs to `secrets` because it lists the keys of the model
  # providers too, where `secrets` is on (`ApiaryProWeb.SettingsLive.Secrets`).
  defp variables_routes do
    for {verb, path, module} <- ApiaryWeb.RoutesFeaturesCase.routes(ApiaryProWeb.Router),
        function_exported?(Code.ensure_loaded!(module), :__feature__, 0),
        module.__feature__() == :organisation_variables or
          module == ApiaryProWeb.SettingsLive.Secrets,
        do: {verb, path}
  end

  # A route's path with the organisation, and a value of its own for every other segment.
  defp concrete(path, organisation) do
    path
    |> String.replace(":org", organisation.slug)
    |> String.replace(~r/:[a-z_]+/, "00000000-0000-0000-0000-000000000000")
  end

  # What a request is answered: the status and the body, without the request's nonce. An
  # error the endpoint renders and raises again is taken as it was sent.
  defp answer(request) do
    conn = request.()
    {conn.status, without_nonce(conn.resp_body)}
  rescue
    _error ->
      {status, _headers, body} = assert_error_sent(:not_found, request)
      {status, without_nonce(body)}
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")

  defp go_to(conn, scope, q) do
    conn
    |> put_req_header("accept", "application/json")
    |> get(~p"/#{scope.organisation}/#{scope.workspace}/jump", %{"q" => q})
    |> json_response(200)
    |> Map.fetch!("groups")
    |> Enum.find(%{"items" => []}, &(&1["label"] == "Go to"))
    |> Map.fetch!("items")
    |> Enum.map(& &1["label"])
  end

  # The Audit log's Action filter's options, as their values.
  defp audit_actions(conn, organisation) do
    {:ok, view, _html} = live(conn, ~p"/#{organisation}/audit-log")
    render_async(view)

    actions =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#filter-action-form li input")
      |> LazyHTML.attribute("value")

    {actions, view}
  end

  # How the Audit log says a grant entry's change of features, as words.
  defp grant_change(from, to) do
    :"instance.grant_features"
    |> ActivityDescriber.change(%{"features" => from}, %{"features" => to}, %{})
    |> ApiaryWeb.RichText.plain_text(%{})
  end

  defp grant!(organisation) do
    Repo.insert!(%Grant{
      organisation_id: organisation.id,
      feature: :organisation_variables,
      granted: true
    })
  end

  defp grants(organisation) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id == ^organisation.id,
        select: {g.feature, g.granted}
    )
    |> Enum.sort()
  end

  describe "off, as a QORY_FEATURES list without secrets leaves it" do
    @describetag with_features: @off
    @describetag needs: :security

    setup :register_and_log_in_user

    test "is off", %{scope: scope} do
      refute Features.on?(:secrets)
      refute Features.on?(:organisation_variables)
      refute Features.visible?(scope, :organisation_variables)
      assert Features.visible?(scope, :security)
    end

    test "every page of it answers as a path that does not exist, to anyone",
         %{conn: conn, scope: scope} do
      routes = variables_routes()
      assert {:get, "/:org/settings/variables"} in routes
      assert {:get, "/:org/settings/variables/new"} in routes
      assert {:get, "/:org/settings/secrets"} in routes
      assert {:get, "/:org/settings/secrets/new"} in routes

      unknown = "/#{scope.organisation.slug}/settings/no-such-page"

      for {who, asker} <- [{"signed in", conn}, {"anonymous", build_conn()}],
          {:get, path} <- routes do
        path = concrete(path, scope.organisation)

        assert answer(fn -> get(asker, path) end) == answer(fn -> get(asker, unknown) end),
               "#{path}, #{who}"
      end
    end

    test "the settings and the palette leave them out", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")

      assert has_element?(view, "#settings-tab-organisation")
      refute has_element?(view, "#settings-tab-secrets")
      refute has_element?(view, "#settings-tab-variables")

      for q <- ["secrets", "variables"],
          do: refute("Organisation settings › Secrets and variables" in go_to(conn, scope, q))
    end

    test "the Audit log's Action filter offers none of their changes, and their entries still show",
         %{conn: conn, scope: scope} do
      # An entry made while they were on.
      Application.put_env(:apiary, :features, Features.all())

      {:ok, _} =
        OrganisationVariables.create(Apiary.Access.reload(scope), %{
          "name" => "LOG_LEVEL",
          "value" => "info"
        })

      Application.put_env(:apiary, :features, @off)

      refute ActivityDescriber.offered?(
               Apiary.Access.reload(scope),
               :"organisation_variable.edit"
             )

      {actions, view} = audit_actions(conn, scope.organisation)

      assert "workspace.rename" in actions
      refute "organisation_variable.edit" in actions
      assert render(view) =~ "Set a variable of the organisation, for every workspace"
    end

    # Built, they are named as every built feature is, whether the instance has them or
    # not, so the entry reads as it was written.
    test "an entry of a grant written while they were on names them" do
      assert grant_change(
               ["observability", "security", "organisation_variables"],
               ["observability", "security"]
             ) ==
               "Runs, Security policy, Organisation secrets and variables → Runs, Security policy"
    end

    test "a grant of them kept from before gives a client nothing", %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      grant!(operator.organisation)
      grant!(client.organisation)

      refute :organisation_variables in ApiaryPro.Features.of(client.organisation)
      refute ActivityDescriber.offered?(client.owner.scope, :"organisation_variable.edit")

      conn = log_in_user(conn, client.owner.user)
      unknown = "/#{client.organisation.slug}/settings/no-such-page"

      assert answer(fn -> get(conn, ~p"/#{client.organisation}/settings/variables") end) ==
               answer(fn -> get(conn, unknown) end)

      {:ok, view, _html} = live(conn, ~p"/#{client.organisation}/settings")
      refute has_element?(view, "#settings-tab-secrets")

      refute "Organisation settings › Secrets and variables" in go_to(
               conn,
               client.owner.scope,
               "variables"
             )

      {actions, _view} = audit_actions(conn, client.organisation)
      assert "workspace.rename" in actions
      refute "organisation_variable.edit" in actions
    end

    test "saving the client's Features page again keeps that grant as it is stored",
         %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      grant!(client.organisation)
      stored = grants(client.organisation)
      assert {:organisation_variables, true} in stored

      conn = log_in_user(conn, operator.user)

      {:ok, lv, _html} =
        live(conn, ~p"/#{operator.organisation}/clients/#{client.organisation.id}/features")

      render_async(lv)
      refute has_element?(lv, "#client-features-organisation_variables")

      lv
      |> form("#client-features-form", %{
        "features" => %{
          "observability" => "true",
          "security" => "true",
          "organisation_policy" => "false"
        }
      })
      |> render_submit()

      assert_patch(lv, ~p"/#{operator.organisation}/clients")
      refute has_element?(lv, "#flash-error")

      assert grants(client.organisation) ==
               Enum.sort(List.delete(stored, {:organisation_policy, true}))

      assert {:organisation_variables, true} in grants(client.organisation)
    end
  end

  describe "on, with secrets" do
    @describetag with_features: Features.all()
    @describetag needs: :organisation_variables

    setup :register_and_log_in_user

    test "its pages, its settings entry, the palette and the Action filter have them",
         %{conn: conn, scope: scope} do
      assert {:ok, _view, _html} = live(conn, ~p"/#{scope.organisation}/settings/variables")
      assert {:ok, _view, _html} = live(conn, ~p"/#{scope.organisation}/settings/secrets")

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/settings")
      assert has_element?(view, "#settings-tab-secrets")
      assert "Organisation settings › Secrets and variables" in go_to(conn, scope, "variables")

      assert ActivityDescriber.offered?(scope, :"organisation_variable.edit")
      {actions, _view} = audit_actions(conn, scope.organisation)
      assert "organisation_variable.edit" in actions
    end

    test "an entry of a grant written while they were built names them" do
      assert grant_change(
               ["observability", "security", "organisation_variables"],
               ["observability", "security"]
             ) ==
               "Runs, Security policy, Organisation secrets and variables → Runs, Security policy"

      # A feature with no label of the edition's, such as the core's `secrets`, is not named.
      assert grant_change(["observability", "secrets"], ["observability"]) == "Runs → Runs"
    end

    test "a new client of the instance organisation is granted them, as its operator has them" do
      admin = instance_admin_fixture()
      instance_scope = make_instance_organisation_an_operator(admin)
      assert :organisation_variables in ApiaryPro.Features.of(instance_scope.organisation)

      client = client_fixture(instance_scope, "Acme")

      assert grants(client.organisation) ==
               Enum.sort([
                 {:observability, true},
                 {:security, true},
                 {:organisation_policy, true},
                 {:organisation_variables, true}
               ])
    end
  end
end
