defmodule ApiaryProWeb.OperatedRefusalTextsTest do
  # What a page says when a link between a workspace and its operator stops a change: a change of kind on Instance › Organisations, the
  # deletion of an operated workspace, and the deletion of an operator that operates one.
  # Not async: instance admins are owners of the suite's one instance organisation.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias ApiaryProWeb.Edition

  @moduletag with_features: Apiary.Features.all()

  setup do
    operator = operator_fixture()
    %{scope: owner, user: owner_user, organisation: organisation} = sign_up_fixture()
    w3 = workspace_fixture(organisation, "W3")
    operate_fixture(owner.workspace, operator.organisation)

    %{
      operator: operator,
      owner: owner,
      owner_user: owner_user,
      organisation: organisation,
      w1: owner.workspace,
      w3: w3
    }
  end

  defp change_kind(conn, organisation) do
    {:ok, lv, _html} = live(conn, ~p"/instance/organisations/#{organisation.id}/kind")
    render_async(lv)
    lv |> element("#kind-confirm") |> render_click()
    lv
  end

  describe "a change of kind" do
    setup %{conn: conn} do
      admin = instance_admin_fixture()
      %{conn: log_in_user(conn, admin.user)}
    end

    test "an organisation with an operated workspace is not made an operator", ctx do
      lv = change_kind(ctx.conn, ctx.organisation)

      assert has_element?(
               lv,
               "#flash-error",
               "An organisation with an operated workspace cannot be made an operator."
             )
    end

    test "an operator that operates a workspace is not made an organisation", ctx do
      lv = change_kind(ctx.conn, ctx.operator.organisation)

      assert has_element?(
               lv,
               "#flash-error",
               "An operator that operates a workspace cannot be made an organisation."
             )
    end
  end

  describe "a deletion" do
    test "an operated workspace is not deleted, and its owner reads why", ctx do
      conn = log_in_user(build_conn(), ctx.owner_user)
      org = ctx.organisation
      {:ok, lv, _html} = live(conn, ~p"/#{org}/#{ctx.w1}/settings/danger")

      lv |> form("#delete-workspace-form", confirm: %{slug: ctx.w1.slug}) |> render_submit()

      assert has_element?(
               lv,
               "#flash-error",
               "A workspace with an operator cannot be deleted."
             )

      assert Apiary.Repo.get!(Apiary.Organisations.Workspace, ctx.w1.id).deletion_marked_at ==
               nil
    end

    test "an operator that operates a workspace is not deleted, and its owner reads why",
         ctx do
      operator = ctx.operator.organisation
      conn = log_in_user(build_conn(), ctx.operator.user)
      {:ok, lv, _html} = live(conn, ~p"/#{operator}/settings/delete")

      lv
      |> form("#delete-organisation-form", confirm: %{slug: operator.slug})
      |> render_submit()

      assert_patch(lv, ~p"/#{operator}/settings")

      assert has_element?(
               lv,
               "#flash-error",
               "An operator that operates a workspace cannot be deleted."
             )
    end

    test "the edition's sentences for the two deletions" do
      assert Edition.refusal_sentence(:operated) ==
               "A workspace with an operator cannot be deleted."

      assert Edition.refusal_sentence(:has_operated_workspaces) ==
               "An operator that operates a workspace cannot be deleted."
    end
  end
end
