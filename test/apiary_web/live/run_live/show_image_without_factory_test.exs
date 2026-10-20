defmodule ApiaryWeb.RunLive.ShowImageWithoutFactoryTest do
  # An instance without the feature that gives a run an image: the rail shows under the
  # Wall the image the run reported, with no line under it, whatever image the run's row
  # keeps as given. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures

  @moduletag with_features: [:observability, :security]

  @prebuilt "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @reported "registry.example/agent:1"

  setup :register_and_log_in_user

  test "a run whose row keeps an image as given: the image it reported, no line",
       %{conn: conn, scope: scope} do
    run =
      run_fixture(scope, %{
        state: "running",
        wall: "docker",
        image: @reported,
        configured_image: @prebuilt,
        started_image_from: "top_level",
        started_image: @prebuilt
      })

    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}")

    assert has_element?(lv, ~s(#run-image[title="#{@reported}"] > bdi), @reported)
    refute has_element?(lv, "#run-image", @prebuilt)
    refute has_element?(lv, "#run-image-source")
  end
end
