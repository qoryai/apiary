defmodule ApiaryProWeb.IntegrationLive.OperatorRuntimesTest do
  @moduledoc """
  A client's Integrations page while the operator owns its clients
  (`ApiaryPro.Flags.operator_infrastructure?/0`): the operator sets the client's agents
  (`runtime.write`, while the client's switch is on the operator's providers), so the client's admin reads the agents, sees no card to add one and
  is told who sets them, and keeps the cards for APIs and programs (`connection.write`).
  """
  # The flag is set for this process.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Connections, Features}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  @operator_sentence "Set by your operator, Main Ops. Ask them to change it."

  # The operator Main Ops and its client Acme, made while the flag was off, then the flag
  # on. The operator sets up an agent in the client; the client's admin sets up an API.
  setup do
    Flags.put_operator_infrastructure(false)
    operator = operator_fixture(%{organisation_name: "Main Ops"})
    client = client_fixture(operator.scope, "Acme")
    client_admin = client_member_fixture(client, :admin)
    Flags.put_operator_infrastructure(true)
    client = model_chain_fixture(operator.scope, client, :operator)

    {:ok, agent} = Connections.create_runtime(client.scope, %{runtime: "claude"})
    {:ok, api} = Connections.create_service(client_admin.scope, %{service: "sentry"})

    %{operator: operator, client: client, client_admin: client_admin, agent: agent, api: api}
  end

  defp integrations_path(ctx, rest \\ ""),
    do:
      "/#{ctx.client.organisation.slug}/#{ctx.client.workspace.slug}/settings/integrations#{rest}"

  defp open(ctx, user, rest \\ "") do
    {:ok, lv, html} = live(log_in_user(build_conn(), user), integrations_path(ctx, rest))
    {lv, html}
  end

  describe "the client's admin, while the operator owns its clients" do
    test "reads the agent and the API that are set up", ctx do
      {lv, _html} = open(ctx, ctx.client_admin.user)

      assert has_element?(lv, "#connection-#{ctx.agent.public_id}", "Claude")
      assert has_element?(lv, "#connection-#{ctx.api.public_id}", "Sentry")
    end

    test "sees no card to set up an agent", ctx do
      {lv, _html} = open(ctx, ctx.client_admin.user)

      refute has_element?(lv, "#add-group-agent")
      refute has_element?(lv, "#add-card-runtime-claude")
    end

    test "keeps the cards for APIs and programs", ctx do
      {lv, _html} = open(ctx, ctx.client_admin.user)

      assert has_element?(lv, "#add-part")
      assert has_element?(lv, "#add-group-apis")
      assert has_element?(lv, "#add-card-api-sentry")
      assert has_element?(lv, "#new-definition")
      assert has_element?(lv, "#add-group-programs")
      assert has_element?(lv, "#add-integration")
      refute has_element?(lv, "#integrations-readonly")
    end

    test "is told who sets an agent up, when they open its form", ctx do
      conn = log_in_user(build_conn(), ctx.client_admin.user)

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, integrations_path(ctx, "/new-runtime"))

      assert to == integrations_path(ctx)
      assert flash == %{"error" => @operator_sentence}
    end

    test "is told who sets an agent up on its settings, which they read", ctx do
      {lv, _html} = open(ctx, ctx.client_admin.user, "/#{ctx.agent.public_id}/settings")

      assert has_element?(lv, "#connection-readonly", @operator_sentence)
      refute has_element?(lv, "#connection-readonly", "Only owners and admins")
    end

    test "sets up an API as before", ctx do
      {lv, _html} = open(ctx, ctx.client_admin.user, "/new-service?definition=builtin:npm")

      {:ok, services} = Connections.list_connections(ctx.client_admin.scope)
      before = length(services)

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> form("#new-service-form", connection: %{name: "Registry"})
               |> render_submit()

      assert to =~ "/settings/integrations/con_"
      {:ok, services} = Connections.list_connections(ctx.client_admin.scope)
      assert length(services) == before + 1
    end
  end

  describe "the operator's admin" do
    test "sees the cards for agents, and opens the form that sets one up", ctx do
      admin = member_fixture(ctx.operator.scope, :admin)
      {lv, _html} = open(ctx, admin.user)

      assert has_element?(lv, "#add-group-agent")
      assert has_element?(lv, "#add-card-runtime-claude")
      assert has_element?(lv, "#add-group-apis")
      assert has_element?(lv, "#add-group-programs")

      {lv, _html} = open(ctx, admin.user, "/new-runtime")
      assert has_element?(lv, "#new-runtime-form")
    end
  end

  describe "with the flag off" do
    test "the client's admin sees the cards for agents as before", ctx do
      Flags.put_operator_infrastructure(false)
      {lv, _html} = open(ctx, ctx.client_admin.user)

      assert has_element?(lv, "#add-group-agent")
      assert has_element?(lv, "#add-card-runtime-claude")
      assert has_element?(lv, "#add-group-apis")
      assert has_element?(lv, "#add-group-programs")
    end
  end
end
