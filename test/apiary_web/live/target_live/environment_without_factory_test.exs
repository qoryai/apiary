defmodule ApiaryWeb.TargetLive.EnvironmentWithoutFactoryTest do
  # An instance without the feature a target's environment belongs to: the target's page
  # has no Environment card and no Rebuild, and a Rebuild, an owner's included, of a target
  # whose collection names an environment, is not found and queues nothing. Not async: the
  # features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Environments, Repo, Targets}
  alias Apiary.Dispatches.DispatchRun

  @moduletag with_features: [:observability, :security]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    started_run(scope, %{"forge" => "code.example.com", "repository" => "acme/shop"})
    # A node pool serves the workspace, and a collection assigned there with the target
    # names an environment: made with every feature, as an instance had them before it
    # was launched without one, since no adapter is made where the feature is off.
    pool_fixture(scope)
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, Apiary.Features.all())

    try do
      collection_fixture(scope,
        target_system: "code.example.com",
        target_path: "acme/shop",
        environment_ref: "env-1"
      )
    after
      Application.put_env(:apiary, :features, previous)
    end

    %{shop: Targets.get(scope, "code.example.com", "acme/shop")}
  end

  test "the target's page has no card and no Rebuild", %{conn: conn, scope: scope, shop: shop} do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/targets/#{shop.public_id}"))
    render_async(view, 2_000)

    assert has_element?(view, "#target-overview")
    refute has_element?(view, "#target-environment")
    refute has_element?(view, "#target-environment-rebuild")
  end

  test "an owner's Rebuild is not found, and nothing is queued", %{scope: scope, shop: shop} do
    assert Environments.rebuild(scope, shop) == {:error, :not_found}
    assert Environments.section(scope, shop) == nil

    assert Repo.aggregate(
             from(r in DispatchRun, where: r.step == ^DispatchRun.prebuild()),
             :count
           ) == 0
  end
end
