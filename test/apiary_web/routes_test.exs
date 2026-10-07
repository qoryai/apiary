defmodule ApiaryWeb.RoutesTest.Router do
  @moduledoc false
  # An edition's router as `ApiaryWeb.Routes` means it: the core's routes, one of them
  # served by a page of the edition's through `except:`, and a page of the edition's in
  # each block.
  use ApiaryWeb, :router

  import ApiaryWeb.Routes

  pipelines()
  public_routes()

  account_routes do
    live "/users/elsewhere", ApiaryWeb.UserLive.Organisations, :index
  end

  visitor_routes except: ["/users/register"] do
    live "/users/register", ApiaryWeb.UserLive.Login, :new
  end

  instance_routes do
    live "/instance/extra", ApiaryWeb.ActivityLive, :index
  end

  organisation_routes do
    live "/:org/extra", ApiaryWeb.ActivityLive, :index
  end
end

defmodule ApiaryWeb.RoutesTest do
  use ExUnit.Case, async: true

  alias ApiaryWeb.RoutesTest.Router

  defp route(router, path), do: Phoenix.Router.route_info(router, "GET", path, "localhost")

  # The on_mount hooks of a live_session, each `{module, argument}`.
  defp on_mount(%{extra: %{on_mount: hooks}}), do: Enum.map(hooks, & &1.id)

  defp live_session(router, path) do
    %{phoenix_live_view: {live_view, _action, _opts, extra}} = route(router, path)
    {live_view, extra.name}
  end

  test "the core's router holds the core's routes, and the edition's holds them all" do
    core = for %{verb: verb, path: path} <- ApiaryWeb.Router.__routes__(), do: {verb, path}
    edition = for %{verb: verb, path: path} <- Router.__routes__(), do: {verb, path}

    assert core -- edition == []
  end

  test "a block's routes are in the core's live_session, named in full" do
    assert live_session(Router, "/users/elsewhere") ==
             {ApiaryWeb.UserLive.Organisations, :require_authenticated_user}

    assert live_session(Router, "/users/register") == {ApiaryWeb.UserLive.Login, :current_user}
  end

  test "except: leaves out the core's route at that path" do
    registrations =
      for %{path: "/users/register", metadata: %{phoenix_live_view: {live_view, _, _, _}}} <-
            Router.__routes__(),
          do: live_view

    assert registrations == [ApiaryWeb.UserLive.Login]
  end

  test "an organisation page of the block comes before a workspace's" do
    assert live_session(Router, "/acme/extra") == {ApiaryWeb.ActivityLive, :workspace}

    %{pipe_through: pipelines} = route(Router, "/acme/extra")
    assert :path_scope in pipelines and :fetch_path_scope in pipelines

    assert live_session(ApiaryWeb.Router, "/acme/extra") ==
             {ApiaryWeb.WorkspaceLive.Overview, :workspace}
  end

  test "an Instance page of the block is in the Instance's live_session, behind sign-in" do
    assert live_session(Router, "/instance/extra") == {ApiaryWeb.ActivityLive, :instance}

    assert live_session(Router, "/instance/configuration") ==
             {ApiaryWeb.InstanceLive.Configuration, :instance}

    %{pipe_through: pipelines, phoenix_live_view: {_live_view, _action, _opts, session}} =
      route(Router, "/instance/extra")

    assert :require_authenticated_user in pipelines
    assert {ApiaryWeb.UserAuth, :require_authenticated} in on_mount(session)

    # The core's router has no such page: the block is the edition's alone.
    refute match?(
             %{phoenix_live_view: {ApiaryWeb.ActivityLive, _, _, _}},
             route(ApiaryWeb.Router, "/instance/extra")
           )
  end

  test "except: naming no route of the macro's is refused" do
    router =
      quote do
        defmodule ApiaryWeb.RoutesTest.Refused do
          use ApiaryWeb, :router
          import ApiaryWeb.Routes

          pipelines()
          visitor_routes(except: ["/users/no-such-page"])
        end
      end

    assert_raise ArgumentError, ~r{/users/no-such-page}, fn -> Code.eval_quoted(router) end
  end
end
