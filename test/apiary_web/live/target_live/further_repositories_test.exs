defmodule ApiaryWeb.TargetLive.FurtherRepositoriesTest do
  @moduledoc """
  What a target's runs also read, on its Overview (`ApiaryWeb.TargetLive.Show`) and on its
  form page (`ApiaryWeb.TargetLive.FurtherRepositories`): the card, after the Backlog card,
  its paths in the saved order, or its empty line, with Change for owners and admins
  alone, and no card where the reader is not shown the feature; the form page, its field
  taking the focus, a save back to the target's page with a flash, a refused list staying
  with its error under the field, Cancel back, and no page for a member or another
  organisation's owner.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Targets

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
    shop = Targets.get(scope, "code.example.com", "acme/shop")

    %{
      shop: shop,
      path: workspace_path(scope, "/targets/#{shop.public_id}"),
      form_path: workspace_path(scope, "/targets/#{shop.public_id}/also-read")
    }
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  defp saved(scope, shop),
    do: Targets.further_repositories(Targets.get(scope, shop.system, shop.path))

  describe "the card" do
    test "its paths in the saved order, with their count and Change, for an owner",
         %{conn: conn, scope: scope, shop: shop, path: path} do
      {:ok, _saved} =
        Targets.set_further_repositories(scope, shop, "acme/shared-config\nacme/docs")

      view = open(conn, path)

      assert has_element?(view, "#target-further-repositories")
      assert has_element?(view, "#target-further-repositories-row-1", "acme/shared-config")
      assert has_element?(view, "#target-further-repositories-row-2", "acme/docs")
      refute has_element?(view, "#target-further-repositories-row-3")
      assert has_element?(view, "#target-further-repositories .q-tgt-card-n", "2")
      refute has_element?(view, "#target-further-repositories-empty")

      assert has_element?(
               view,
               ~s(#target-further-repositories-change[href="#{path}/also-read"])
             )
    end

    test "its empty line where it reads no other", %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#target-further-repositories-empty")
      refute has_element?(view, "#target-further-repositories-row-1")
      refute has_element?(view, "#target-further-repositories .q-tgt-card-n")
    end

    test "after the Backlog and Environment cards, last in the main column", %{
      conn: conn,
      scope: scope,
      path: path
    } do
      connection = ticket_connection_fixture(scope)

      source_collection_fixture(scope, connection, %{
        target_system: "code.example.com",
        target_path: "acme/shop"
      })

      view = open(conn, path)

      assert has_element?(
               view,
               "#target-overview .q-tgt-ov-main > #target-backlog + #target-environment + section:last-child#target-further-repositories"
             )
    end

    test "Change for an admin; a member reads the paths, without Change",
         %{scope: scope, shop: shop, path: path} do
      {:ok, _saved} = Targets.set_further_repositories(scope, shop, "acme/docs")

      %{user: admin} = member_fixture(scope, :admin)
      view = open(log_in_user(build_conn(), admin), path)
      assert has_element?(view, "#target-further-repositories-change")

      %{user: member} = member_fixture(scope, :member)
      view = open(log_in_user(build_conn(), member), path)
      assert has_element?(view, "#target-further-repositories-row-1", "acme/docs")
      refute has_element?(view, "#target-further-repositories-change")
    end

    test "no card where the reader is not shown the feature", %{conn: conn, path: path} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
      :ok = Apiary.EditionStubs.HidesNamed.put([:factory])

      view = open(conn, path)
      assert has_element?(view, "#target-overview")
      refute has_element?(view, "#target-further-repositories")
    end
  end

  describe "the form page" do
    test "Change opens it, its field focused, holding the saved paths a line each",
         %{conn: conn, scope: scope, shop: shop, path: path, form_path: form_path} do
      {:ok, _saved} = Targets.set_further_repositories(scope, shop, "acme/docs\nacme/api")
      view = open(conn, path)

      {:ok, form, _html} =
        view
        |> element("#target-further-repositories-change")
        |> render_click()
        |> follow_redirect(conn, form_path)

      assert has_element?(form, "#further-repositories-page")
      assert has_element?(form, "textarea#target_further_repositories[phx-mounted]")
      assert has_element?(form, "#target_further_repositories", ~r"\Aacme/docs\s+acme/api\z")
      assert has_element?(form, "#target_further_repositories-hint")
      assert has_element?(form, "#further-repositories-limit")
    end

    test "a save goes back to the target's page, with a flash and the new paths",
         %{conn: conn, scope: scope, shop: shop, path: path, form_path: form_path} do
      form = open(conn, form_path)

      {:ok, view, _html} =
        form
        |> form("#further-repositories-form",
          target: %{further_repositories: "acme/web\n\n  acme/docs  "}
        )
        |> render_submit()
        |> follow_redirect(conn, path)

      render_async(view, 2_000)
      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#target-further-repositories-row-1", "acme/web")
      assert has_element?(view, "#target-further-repositories-row-2", "acme/docs")
      assert saved(scope, shop) == ["acme/web", "acme/docs"]
    end

    test "emptied, it saves none, and the card says so",
         %{conn: conn, scope: scope, shop: shop, path: path, form_path: form_path} do
      {:ok, _saved} = Targets.set_further_repositories(scope, shop, "acme/docs")

      {:ok, view, _html} =
        open(conn, form_path)
        |> form("#further-repositories-form", target: %{further_repositories: ""})
        |> render_submit()
        |> follow_redirect(conn, path)

      render_async(view, 2_000)
      assert has_element?(view, "#flash-info")
      assert has_element?(view, "#target-further-repositories-empty")
      assert saved(scope, shop) == []
    end

    test "a refused list stays, with its error under the field, and nothing is saved",
         %{conn: conn, scope: scope, shop: shop, form_path: form_path} do
      form = open(conn, form_path)

      form
      |> form("#further-repositories-form",
        target: %{further_repositories: "acme/docs\nother/docs"}
      )
      |> render_submit()

      assert has_element?(form, "#further-repositories-page")
      assert has_element?(form, "#target_further_repositories[aria-invalid=true]")
      assert has_element?(form, "#target_further_repositories-error")
      assert has_element?(form, "#target_further_repositories", ~r"\Aacme/docs\s+other/docs\z")
      refute has_element?(form, "#target_further_repositories-hint")
      assert saved(scope, shop) == []
    end

    test "a list over the joined limit stays too, with its error under the field",
         %{conn: conn, scope: scope, shop: shop, form_path: form_path} do
      form = open(conn, form_path)
      long = "acme/" <> String.duplicate("a", 195)

      form
      |> form("#further-repositories-form",
        target: %{further_repositories: long <> "\nacme/" <> String.duplicate("b", 50)}
      )
      |> render_submit()

      assert has_element?(form, "#further-repositories-page")
      # The count it names: acme/shop and the two, joined with commas.
      assert has_element?(form, "#target_further_repositories-error", "266")
      assert saved(scope, shop) == []
    end

    test "not there, and no card, where the workspace's domain has no label for a run's paths",
         %{conn: conn, scope: scope, path: path, form_path: form_path} do
      with_domain(scope, "example")

      view = open(conn, path)
      refute has_element?(view, "#target-further-repositories")

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, form_path) end
    end

    test "Cancel goes back to the target's page", %{conn: conn, path: path, form_path: form_path} do
      form = open(conn, form_path)
      assert has_element?(form, ~s(#further-repositories-save-cancel[href="#{path}"]))
    end

    test "not there for a member, nor for another organisation's owner",
         %{scope: scope, shop: shop, form_path: form_path} do
      %{user: member} = member_fixture(scope, :member)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(log_in_user(build_conn(), member), form_path)
      end

      %{user: other, scope: other_scope} = sign_up_fixture()
      elsewhere = workspace_path(other_scope, "/targets/#{shop.public_id}/also-read")

      assert_raise ApiaryWeb.NotFound, fn ->
        live(log_in_user(build_conn(), other), elsewhere)
      end
    end
  end
end
