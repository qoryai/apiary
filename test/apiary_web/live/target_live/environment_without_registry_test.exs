defmodule ApiaryWeb.TargetLive.EnvironmentWithoutRegistryTest do
  # The Environment card of a target on an instance without a registry
  # (`Apiary.Registry.configured?/0`): no build runs there, so the card says how to get
  # one and that runs start in the pool's default image, with no pool lines and no
  # Rebuild. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Dispatches, Repo, Targets}

  @moduletag needs: :factory

  # The instance's organisation comes first, so the person signed up here is no instance
  # admin.
  setup do
    _organisation = ensure_instance_organisation!()
    :ok
  end

  setup :register_and_log_in_user
  setup {Apiary.DataCase, :without_registry}

  @system "code.example.com"
  @path "acme/shop"

  setup %{scope: scope} do
    started_run(scope, %{"forge" => @system, "repository" => @path})
    shop = Targets.get(scope, @system, @path)
    %{path: workspace_path(scope, "/targets/#{shop.public_id}")}
  end

  # The element's words, with the spaces between them as a reader sees them.
  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

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
             "Runs of this repository start in the pool's default image."
           )

    refute has_element?(view, "#target-environment-pools")
    refute has_element?(view, "#target-environment-pool-#{pool.id}-held")
    refute has_element?(view, "#target-environment-pool-#{pool.id}-waiting")
    refute has_element?(view, "#target-environment-rebuild")
    refute render(view) =~ "Runs wait until this repository's environment image is built."
    refute render(view) =~ "A build is waiting."
  end

  test "an instance admin reads how to get a registry" do
    admin = instance_admin_scope()
    admin = %{admin | workspace: workspace_fixture(admin.organisation, "Build")}

    started_run(admin, %{"forge" => @system, "repository" => @path})
    shop = Targets.get(admin, @system, @path)
    pool_fixture(admin, name: "mac-pool")

    collection_fixture(admin,
      external_ref: "SHOP",
      target_system: @system,
      target_path: @path,
      environment_ref: "env-1"
    )

    view =
      open(
        log_in_user(build_conn(), admin.user),
        workspace_path(admin, "/targets/#{shop.public_id}")
      )

    # In the words of the workspace's domain, software, with the server's setting in code.
    assert text(view, "#target-environment-no-registry") ==
             "Set QORY_REGISTRY on the server to build this repository's environment image. " <>
               "Until then, runs start in the pool's default image."

    assert has_element?(view, "#target-environment-no-registry code", "QORY_REGISTRY")
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
