defmodule ApiaryWeb.TargetLive.EnvironmentWithoutRegistryTest do
  # The Environment card of a target on an instance without a registry
  # (`Apiary.Registry.configured?/0`): no build runs there, so the card says how to get
  # one and that runs start in the pool's default image, with no pool lines and no
  # Rebuild. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Dispatches, Repo, Targets}

  @moduletag needs: :factory

  setup :register_and_log_in_user
  setup {Apiary.DataCase, :without_registry}

  @system "code.example.com"
  @path "acme/shop"

  setup %{scope: scope} do
    started_run(scope, %{"forge" => @system, "repository" => @path})
    shop = Targets.get(scope, @system, @path)
    %{path: workspace_path(scope, "/targets/#{shop.public_id}")}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  test "a target that names an environment: one line, no pool lines, no Rebuild",
       %{conn: conn, scope: scope, path: path} do
    refute Apiary.Registry.configured?()
    pool = pool_fixture(scope, name: "mac-pool")

    collection =
      collection_fixture(scope,
        external_ref: "SHOP",
        target_system: @system,
        target_path: @path,
        environment_ref: "env-1"
      )

    # A build queued while the registry was there waits, and the card says nothing of it.
    {:ok, {:ok, _run}} =
      Repo.transact(fn -> {:ok, Dispatches.queue_prebuild(collection, pool, "env-1")} end)

    view = open(conn, path)

    # In the words of the workspace's domain, software: a target is a repository.
    assert has_element?(
             view,
             "#target-environment-no-registry",
             "Ask an instance admin to set up a registry to build this repository's environment image. Until then, runs start in the pool's default image."
           )

    refute has_element?(view, "#target-environment-pools")
    refute has_element?(view, "#target-environment-pool-#{pool.id}-held")
    refute has_element?(view, "#target-environment-pool-#{pool.id}-waiting")
    refute has_element?(view, "#target-environment-rebuild")
    refute render(view) =~ "Runs wait until this repository's environment image is built."
    refute render(view) =~ "A build is waiting."
  end

  test "a target that names no environment: the line it had", %{
    conn: conn,
    scope: scope,
    path: path
  } do
    pool_fixture(scope)

    collection_fixture(scope,
      external_ref: "SHOP",
      target_system: @system,
      target_path: @path,
      environment_ref: nil
    )

    view = open(conn, path)
    assert has_element?(view, "#target-environment-none")
    refute has_element?(view, "#target-environment-no-registry")
  end
end
