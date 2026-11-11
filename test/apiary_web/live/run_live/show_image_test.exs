defmodule ApiaryWeb.RunLive.ShowImageTest do
  @moduledoc """
  The Image row of a run page's rail (`ApiaryWeb.RunLive.Show`), after the Wall, for a
  run of the workspace's queue: the image Qory gave the run, raw, with "Prebuilt for this
  repository" under it where the image is at the place a build for the run's target
  pushes its image, and with no line under it elsewhere; for a run of the queue given none, the image it reported, with
  "The pool's default image." under it; for a run that started in its policy's image, and
  any other run, the image it reported, with no line under it. A run with no wall has no
  Image row.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.RunEventsFixtures

  @moduletag needs: :factory

  @digest String.duplicate("3b9d", 16)
  @elsewhere "ghcr.io/northwind/storefront-agent@sha256:" <> @digest
  @reported "registry.example/agent:1"

  setup :register_and_log_in_user

  setup %{scope: scope} do
    pool = pool_fixture(scope, name: "mac-pool")
    %{access_key: key} = enrolled_key_fixture(scope, pool)
    %{key: key}
  end

  defp open(conn, scope, run) do
    {:ok, lv, _html} =
      live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.number}")

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

  # A run of the queue given the image a build for its target pushed, at the target's
  # place in the registry (`Apiary.Registry.RunAccess.destinations/1`).
  defp prebuilt(scope, key, attrs \\ %{}) do
    run = dispatched(scope, key, %{})

    target =
      if run.target_id,
        do: Apiary.Repo.get!(Apiary.Runs.Target, run.target_id),
        else:
          Apiary.Repo.insert!(%Apiary.Runs.Target{
            organisation_id: scope.organisation.id,
            workspace_id: scope.workspace.id,
            system: "code.example.com",
            path: "northwind/storefront",
            first_seen_at: DateTime.utc_now()
          })

    place =
      Apiary.Registry.Names.target_name(
        Apiary.InstanceConfig.registry_instance(),
        scope.organisation.id,
        target.public_id
      )

    image = "#{Apiary.Registry.service()}/#{place}@sha256:#{@digest}"

    run =
      run
      |> Ecto.Changeset.change(Map.merge(given_image(image), Map.new(attrs)))
      |> Ecto.Changeset.change(target_id: target.id)
      |> Apiary.Repo.update!()

    {run, image}
  end

  test "an image Qory gave the run: in mono, raw, its whole reference the title, prebuilt",
       %{conn: conn, scope: scope, key: key} do
    {run, prebuilt} = prebuilt(scope, key)
    run = run |> Ecto.Changeset.change(image: prebuilt) |> Apiary.Repo.update!()
    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image.font-mono[title="#{prebuilt}"]), prebuilt)
    refute has_element?(lv, "#run-image bdi")
    assert has_element?(lv, "#run-image-source", "Prebuilt for this repository")
  end

  test "an image Qory gave the run elsewhere than its target's place: the image, no line",
       %{conn: conn, scope: scope, key: key} do
    # A run given a machine type's image, before a type set only the size.
    run = dispatched(scope, key, given_image(@elsewhere))
    lv = open(conn, scope, run)

    assert has_element?(lv, ~s(#run-image.font-mono[title="#{@elsewhere}"]), @elsewhere)
    refute has_element?(lv, "#run-image-source")
  end

  test "the image has a separate row after the Wall, the Key and the Machine type, and the Wall has the wall alone",
       %{conn: conn, scope: scope, key: key} do
    run = dispatched(scope, key, %{started_image_from: "none"})
    lv = open(conn, scope, run)

    facts = lv |> element("#run-facts") |> render() |> LazyHTML.from_fragment()
    labels = facts |> LazyHTML.query("dt") |> Enum.map(&String.trim(LazyHTML.text(&1)))
    wall = Enum.find_index(labels, &(&1 == "Wall"))
    image = Enum.find_index(labels, &(&1 == "Image"))
    assert image > wall
    assert Enum.slice(labels, (wall + 1)..(image - 1)//1) -- ["Key", "Machine type"] == []

    assert has_element?(lv, "#run-image-row #run-image", @reported)
    assert has_element?(lv, "#run-image-row #run-image-source")

    wall_value = facts |> LazyHTML.query("dd") |> Enum.at(wall) |> LazyHTML.text()
    assert String.trim(wall_value) == "docker"
  end

  test "a run with no wall has no Image row", %{conn: conn, scope: scope} do
    run = run_fixture(scope, %{state: "running", wall: nil, image: @reported})
    lv = open(conn, scope, run)

    refute has_element?(lv, "#run-image-row")
    refute has_element?(lv, "#run-facts dt", "Image")
  end

  test "an image Qory gave the run is shown even where the run reported another",
       %{conn: conn, scope: scope, key: key} do
    {run, prebuilt} = prebuilt(scope, key)
    lv = open(conn, scope, run)

    assert has_element?(lv, "#run-image", prebuilt)
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
    {run, _prebuilt} = prebuilt(scope, key)
    html = conn |> open(scope, run) |> element("#run-image-source") |> render()

    assert html =~ "Prebuilt for this repository"
    refute html =~ "target"

    assert Gettext.with_locale(ApiaryWeb.Gettext, "en@software", fn ->
             Gettext.gettext(ApiaryWeb.Gettext, "Prebuilt for this target")
           end) == "Prebuilt for this repository"
  end
end
