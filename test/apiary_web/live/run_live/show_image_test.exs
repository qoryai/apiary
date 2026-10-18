defmodule ApiaryWeb.RunLive.ShowImageTest do
  @moduledoc """
  The image under the Wall in a run page's rail (`ApiaryWeb.RunLive.Show`), for a run of
  the workspace's queue: the image Qory gave the run, raw, with "Prebuilt for this
  repository" under it; for a run of the queue given none, the image it reported, with
  "The pool's default image." under it; for a run that started in its policy's image, and
  any other run, the image it reported, with no line under it.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  @moduletag needs: :factory

  @prebuilt "registry.example.com:5000/acme/shop-env@sha256:" <> String.duplicate("3b9d", 16)
  @reported "registry.example/agent:1"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    pool = pool_fixture(scope, name: "mac-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{key: key}
  end

  defp open(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}")

    lv
  end

  # A run of the queue, handed over and started, that reported `@reported` in its wall.
  defp dispatched(scope, key, attrs) do
    %{run: run} =
      handed_over_fixture(scope, key, Map.merge(%{wall: "docker", image: @reported}, attrs))

    run
  end

  defp given_image(image),
    do: %{configured_image: image, started_image_from: "top_level", started_image: image}

  test "an image Qory gave the run: in mono, raw, its whole reference the title, prebuilt",
       %{conn: conn, scope: scope, key: key} do
    run = dispatched(scope, key, Map.merge(given_image(@prebuilt), %{image: @prebuilt}))
    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image.font-mono[title="#{@prebuilt}"]), @prebuilt)
    refute has_element?(lv, "#run-image bdi")
    assert has_element?(lv, "#run-image-source", "Prebuilt for this repository")
  end

  test "an image Qory gave the run is shown even where the run reported another",
       %{conn: conn, scope: scope, key: key} do
    run = dispatched(scope, key, given_image(@prebuilt))
    lv = open(conn, scope, run)

    assert has_element?(lv, "#run-image", @prebuilt)
    refute has_element?(lv, "#run-image", @reported)
    assert has_element?(lv, "#run-image-source", "Prebuilt for this repository")
  end

  test "a run of the queue given no image: the image it reported, the pool's default image",
       %{conn: conn, scope: scope, key: key} do
    run = dispatched(scope, key, %{started_image_from: "none"})
    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image[title="#{@reported}"] > bdi), @reported)
    assert has_element?(lv, "#run-image-source", "The pool's default image.")
  end

  test "a run of the queue that started in its policy's image: the image it reported, no line",
       %{conn: conn, scope: scope, key: key} do
    run =
      dispatched(scope, key, %{started_image_from: "policy", started_image: "with-docker"})

    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image[title="#{@reported}"] > bdi), @reported)
    refute has_element?(lv, "#run-image-source")
  end

  test "a run not of the queue: the image it reported, no line", %{conn: conn, scope: scope} do
    run = run_fixture(scope, %{state: "running", wall: "docker", image: @reported})
    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image[title="#{@reported}"] > bdi), @reported)
    refute has_element?(lv, "#run-image-source")
  end

  test "the line under an image Qory gave says repository in the software domain, target in the engine's words",
       %{conn: conn, scope: scope, key: key} do
    run = dispatched(scope, key, given_image(@prebuilt))
    html = conn |> open(scope, run) |> element("#run-image-source") |> render()

    assert html =~ "Prebuilt for this repository"
    refute html =~ "target"

    assert Gettext.with_locale(ApiaryWeb.Gettext, "en@software", fn ->
             Gettext.gettext(ApiaryWeb.Gettext, "Prebuilt for this target")
           end) == "Prebuilt for this repository"
  end
end
