defmodule ApiaryProWeb.OrganisationPolicyFeaturesLiveTest do
  # What people see when an organisation is granted the organisation's policy or has it
  # taken away: the policy holds above its workspaces either way, so a workspace's
  # History says nothing of it.
  # Not async: the features are the node's, and an instance admin is made for each test.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Policy}
  alias ApiaryPro.{Grants, OrganisationPolicy}

  @moduletag with_features: Features.all()

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    %{admin: instance_admin_fixture()}
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  test "hiding the policy writes nothing to a workspace's History", ctx do
    %{user: user, scope: owner, organisation: organisation} =
      sign_up_fixture(%{organisation_name: "Acme"})

    conn = log_in_user(build_conn(), user)
    {:ok, _} = OrganisationPolicy.deny(owner, %{host: "paste.example"})
    changes = Policy.list_changes(owner, nil, 1).items
    shown = Grants.shown(organisation)

    view = open(conn, workspace_path(owner, "/policy/history"))
    before = text(view, "#policy-history")

    {:ok, _} =
      Grants.set_organisation(
        ctx.admin.instance_scope,
        organisation.id,
        shown -- [:organisation_policy]
      )

    view = open(conn, workspace_path(owner, "/policy/history"))
    assert text(view, "#policy-history") == before
    refute text(view, "#policy-history") =~ "Qory Apiary changed"

    {:ok, _} = Grants.set_organisation(ctx.admin.instance_scope, organisation.id, shown)

    view = open(conn, workspace_path(owner, "/policy/history"))
    assert text(view, "#policy-history") == before
    assert Policy.list_changes(owner, nil, 1).items == changes
  end
end
