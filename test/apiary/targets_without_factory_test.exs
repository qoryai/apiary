defmodule Apiary.TargetsWithoutFactoryTest do
  # An instance without the feature a target's further repositories belong to: nobody
  # chooses them, an owner included, and the target's page has no card of them. Not async:
  # the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  alias Apiary.Targets

  @moduletag with_features: [:observability, :security]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
    %{shop: Targets.get(scope, "code.example.com", "acme/shop")}
  end

  # A path that does not exist answers 404, rendered by the endpoint or raised to it.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    _raised ->
      {status, _headers, _body} = assert_error_sent(404, fn -> get(conn, path) end)
      status
  end

  test "an owner's change is not found, and nothing is written", %{scope: scope, shop: shop} do
    assert Targets.set_further_repositories(scope, shop, "acme/docs") == {:error, :not_found}
    assert Targets.further_repositories(Targets.get(scope, shop.system, shop.path)) == []
  end

  test "the target's page has no card, and the form page is not there",
       %{conn: conn, scope: scope, shop: shop} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/targets/#{shop.public_id}"))
    render_async(view, 2_000)
    assert has_element?(view, "#target-overview")
    refute has_element?(view, "#target-further-repositories")

    assert status(conn, workspace_path(scope, "/targets/#{shop.public_id}/also-read")) == 404
  end
end
