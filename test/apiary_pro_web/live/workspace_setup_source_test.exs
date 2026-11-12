defmodule ApiaryProWeb.WorkspaceSetupSourceTest do
  # The Work sources step of the workspace set-up, `/:org/:workspace/set-up/sources`
  # (`ApiaryWeb.WorkspaceSetupLive`), on an instance, for a person `adapter.connect`
  # refuses: while the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`),
  # a client's people see who connects work sources, with Skip, and no
  # Connect; with the flag off, and in an organisation with no operator, the core's
  # behaviour. The flag is set per process (`Flags.put_operator_infrastructure/1`).
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    Flags.put_operator_infrastructure(false)
    name = "Hive Ops #{System.unique_integer([:positive])}"
    operator = operator_fixture(%{organisation_name: name})
    client = client_fixture(operator.scope, "Acme")
    client_member = client_member_fixture(client, :member)
    %{adapter: adapter} = connectable_adapter_fixture()

    %{
      operator_name: name,
      operator: operator,
      client: client,
      client_member: client_member,
      adapter: adapter
    }
  end

  defp set_up_path(organisation, workspace),
    do: "/#{organisation.slug}/#{workspace.slug}/set-up/sources"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp skip_to(client),
    do: "/#{client.organisation.slug}/#{client.workspace.slug}/set-up/destinations"

  describe "in a client, with the flag on" do
    setup do: Flags.put_operator_infrastructure(true)

    test "its first person sees who connects and Skip, and no Connect", ctx do
      %{client: client, adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(client.owner.user)
        |> live(set_up_path(client.organisation, client.workspace))

      assert has_element?(lv, "h1", "Where does work for Main come from?")

      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")

      # The About work sources column says who connects, so the page has no second line for it.
      refute has_element?(lv, "#set-up-connect-who-may")

      assert words(lv, "#set-up-what") =~
               "Owners and admins of #{ctx.operator_name} connect it once for Acme."

      assert has_element?(
               lv,
               ~s{#set-up-skip[data-phx-link=patch][href="#{skip_to(client)}"]},
               "Skip"
             )
    end

    test "a member of the client sees the same sentence",
         ctx do
      %{client: client, adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(ctx.client_member.user)
        |> live(set_up_path(client.organisation, client.workspace))

      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")

      assert words(lv, "#set-up-what") =~
               "Owners and admins of #{ctx.operator_name} connect it once for Acme."
    end

    test "an owner of the operator can connect: Connect, and no sentence", ctx do
      %{client: client, adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(ctx.operator.user)
        |> live(set_up_path(client.organisation, client.workspace))

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")
    end
  end

  describe "in the operator, with the flag on" do
    setup do: Flags.put_operator_infrastructure(true)

    test "an admin of the operator can connect in a client: Connect, and no sentence", ctx do
      %{client: client, adapter: adapter} = ctx
      admin = member_fixture(ctx.operator.scope, :admin)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(admin.user)
        |> live(set_up_path(client.organisation, client.workspace))

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")
    end

    test "the operator's organisation itself gets Connect and no sentence", ctx do
      %{adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(ctx.operator.user)
        |> live(set_up_path(ctx.operator.organisation, ctx.operator.workspace))

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")
    end
  end

  describe "in a client, with the flag off" do
    test "its owner connects as in the core: Connect, and no sentence", ctx do
      %{client: client, adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(client.owner.user)
        |> live(set_up_path(client.organisation, client.workspace))

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")
    end

    test "a member of the client, whom the core refuses, sees the core's sentence and no Connect",
         ctx do
      %{client: client, adapter: adapter} = ctx

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(ctx.client_member.user)
        |> live(set_up_path(client.organisation, client.workspace))

      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")

      assert words(lv, "#set-up-connect-who-may") ==
               "Only owners and admins of #{client.organisation.name} connect work sources."
    end
  end

  describe "in an organisation with no operator" do
    setup do: Flags.put_operator_infrastructure(true)

    test "its owner connects, and a member sees the core's sentence, as in the core" do
      %{user: owner, organisation: organisation, workspace: workspace, scope: scope} =
        sign_up_fixture()

      %{user: member} = member_fixture(scope, :member)
      %{adapter: adapter} = connectable_adapter_fixture()

      {:ok, lv, _html} =
        build_conn() |> log_in_user(owner) |> live(set_up_path(organisation, workspace))

      assert has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")
      refute has_element?(lv, "#set-up-connect-who-may")

      {:ok, lv, _html} =
        build_conn() |> log_in_user(member) |> live(set_up_path(organisation, workspace))

      refute has_element?(lv, "#set-up-adapter-#{adapter.public_id}-connect")

      assert words(lv, "#set-up-connect-who-may") ==
               "Only owners and admins of #{organisation.name} connect work sources."
    end
  end
end
