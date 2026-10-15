# The fixtures of `ApiaryWeb.FeaturesAnyTest`: pages of `secrets` or `factory`, of
# `secrets` alone, of `factory` at the Instance level, and of a feature there is not, with
# their routers.

defmodule ApiaryWeb.FeaturesAnyTest.EitherController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  use ApiaryWeb.Features, any: [:secrets, :factory]

  def index(conn, _params), do: Plug.Conn.send_resp(conn, 200, "either")
end

defmodule ApiaryWeb.FeaturesAnyTest.SecretsController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  use ApiaryWeb.Features, :secrets

  def index(conn, _params), do: Plug.Conn.send_resp(conn, 200, "secrets")
end

defmodule ApiaryWeb.FeaturesAnyTest.InstanceController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  use ApiaryWeb.Features, instance: :factory

  def index(conn, _params), do: Plug.Conn.send_resp(conn, 200, "instance")
end

defmodule ApiaryWeb.FeaturesAnyTest.EitherLive do
  @moduledoc false
  use Phoenix.LiveView
  use ApiaryWeb.Features, any: [:secrets, :factory]

  @impl true
  def render(assigns) do
    ~H"""
    <p id="either">either</p>
    """
  end
end

defmodule ApiaryWeb.FeaturesAnyTest.Router do
  @moduledoc false
  use Phoenix.Router
  get "/either", ApiaryWeb.FeaturesAnyTest.EitherController, :index
  get "/secrets", ApiaryWeb.FeaturesAnyTest.SecretsController, :index
  get "/instance", ApiaryWeb.FeaturesAnyTest.InstanceController, :index
end

defmodule ApiaryWeb.FeaturesAnyTest.UnknownFeatureController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  use ApiaryWeb.Features, any: [:secrets, :dispatch]

  def index(conn, _params), do: conn
end

defmodule ApiaryWeb.FeaturesAnyTest.UnknownFeatureRouter do
  @moduledoc false
  use Phoenix.Router
  get "/dispatch", ApiaryWeb.FeaturesAnyTest.UnknownFeatureController, :index
end

defmodule ApiaryWeb.FeaturesAnyTest do
  # A page of more than one feature, `use ApiaryWeb.Features, any: [...]`: there when the
  # instance has one of them, or the person is shown one, and absent when none is, as a
  # page of one feature that is off or hidden; what `use` is given, checked when the page
  # compiles; and the features it names, checked at boot.
  #
  # Not async: the tests switch the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Accounts.Scope

  alias ApiaryWeb.FeaturesAnyTest.{
    EitherController,
    EitherLive,
    InstanceController,
    Router,
    SecretsController,
    UnknownFeatureRouter
  }

  @neither [:observability, :security]

  # A request to `path` of the fixture router as the endpoint passes it on: the instance's
  # features at the door (`ApiaryWeb.Features.Routes`), then the route, the page's gate
  # asking `scope` where one is given.
  defp request(path, scope) do
    conn = build_conn(:get, path)
    conn = if scope, do: Plug.Conn.assign(conn, :current_scope, scope), else: conn

    conn
    |> ApiaryWeb.Features.Routes.call(Router)
    |> Router.call(Router.init([]))
  end

  # What a request is answered: the status and the body, or the error raised for the
  # endpoint to render, as for a path the router does not know.
  defp answer(path, scope \\ nil) do
    conn = request(path, scope)
    {conn.status, conn.resp_body}
  rescue
    error in [Phoenix.Router.NoRouteError] -> {:raised, error.plug_status}
  end

  # A person's scope that hides `hidden`.
  defp person(hidden), do: %Scope{hidden: hidden}

  describe "what the page names" do
    test "__feature__/0 is {:any, features}; the form of one feature is unchanged" do
      assert EitherController.__feature__() == {:any, [:secrets, :factory]}
      assert EitherLive.__feature__() == {:any, [:secrets, :factory]}
      assert SecretsController.__feature__() == :secrets

      assert ApiaryWeb.Features.gate(EitherController) == {:any, [:secrets, :factory]}
      assert ApiaryWeb.Features.gate(SecretsController) == :secrets
      assert ApiaryWeb.Features.gate(Router) == nil

      assert ApiaryWeb.Features.features({:any, [:secrets, :factory]}) == [:secrets, :factory]
      assert ApiaryWeb.Features.features(:secrets) == [:secrets]
    end
  end

  describe "with secrets and not factory" do
    @describetag with_features: [:observability, :security, :secrets]

    test "the page is there, to the instance and to a person shown secrets" do
      assert answer("/either") == {200, "either"}
      assert answer("/either", person([])) == {200, "either"}
      assert {:ok, view, _html} = live_isolated(build_conn(), EitherLive)
      assert has_element?(view, "#either")
    end

    test "to a person secrets is hidden from, it answers as a page of secrets does" do
      hidden = person([:secrets])
      assert {404, _body} = answer("/either", hidden)
      assert answer("/either", hidden) == answer("/secrets", hidden)
    end
  end

  describe "with factory and not secrets" do
    @describetag with_features: [:observability, :security, :factory]

    test "the page is there, and a page of secrets alone is not" do
      assert answer("/either") == {200, "either"}
      assert answer("/either", person([])) == {200, "either"}
      assert answer("/secrets") == answer("/no-such-page")
      assert {:ok, view, _html} = live_isolated(build_conn(), EitherLive)
      assert has_element?(view, "#either")
    end
  end

  describe "with secrets and factory" do
    @describetag with_features: [:observability, :security, :secrets, :factory]

    test "the page is there, while a person is shown one of them" do
      assert answer("/either") == {200, "either"}
      assert answer("/either", person([:secrets])) == {200, "either"}
      assert answer("/either", person([:factory])) == {200, "either"}
      assert {404, _body} = answer("/either", person([:secrets, :factory]))
      assert {:ok, view, _html} = live_isolated(build_conn(), EitherLive)
      assert has_element?(view, "#either")
    end
  end

  describe "with neither" do
    @describetag with_features: @neither

    test "the page answers as a path the router does not know, as a page of secrets does" do
      assert answer("/no-such-page") == {:raised, 404}
      assert answer("/either") == answer("/no-such-page")
      assert answer("/either") == answer("/secrets")
      assert answer("/either", person([])) == answer("/no-such-page", person([]))
    end

    test "past the door, the page's gates answer as a hidden page's" do
      # A live navigation never reaches the door: the LiveView's hook answers.
      assert_raise ApiaryWeb.Features.NotFound, fn ->
        ApiaryWeb.Features.on_mount({:any, [:secrets, :factory]}, %{}, %{}, socket())
      end

      assert {:cont, _socket} = ApiaryWeb.Features.on_mount(:observability, %{}, %{}, socket())

      # A controller's plug, as a signed request of the server contract meets it.
      gate = ApiaryWeb.Features.init({:any, [:secrets, :factory]})
      conn = ApiaryWeb.Features.call(build_conn(:get, "/either"), gate)
      assert conn.halted
      assert conn.status == 404

      single = ApiaryWeb.Features.call(build_conn(:get, "/secrets"), :secrets)
      assert conn.resp_body == single.resp_body
    end

    test "the instance has none of them" do
      refute ApiaryWeb.Features.on?({:any, [:secrets, :factory]})
      refute ApiaryWeb.Features.visible?(person([]), {:any, [:secrets, :factory]})
      assert ApiaryWeb.Features.on?({:any, [:security, :factory]})
    end
  end

  describe "a page of the Instance level, `instance:`" do
    test "names its feature as a page of the organisation does" do
      assert InstanceController.__feature__() == :factory
      assert ApiaryWeb.Features.gate(InstanceController) == :factory
    end

    test "says it is one, and no other page does" do
      assert ApiaryWeb.Features.instance?(InstanceController)
      refute ApiaryWeb.Features.instance?(SecretsController)
      refute ApiaryWeb.Features.instance?(EitherController)
      refute ApiaryWeb.Features.instance?(Router)
    end

    @tag with_features: [:observability, :security, :factory]
    test "with the feature, an open page stays there, whatever the scope hides" do
      assert ApiaryWeb.Features.page_shown?(InstanceController, person([:factory]))
      assert ApiaryWeb.Features.page_shown?(InstanceController, nil)

      # A page of the organisation asks what the scope shows; a page of no feature is there.
      refute ApiaryWeb.Features.page_shown?(EitherController, person([:factory]))
      assert ApiaryWeb.Features.page_shown?(EitherController, person([]))
      assert ApiaryWeb.Features.page_shown?(Router, person([:factory]))
    end

    @tag with_features: [:observability, :security, :factory]
    test "with the feature, it is there to whoever opens it, whatever the scope hides" do
      assert answer("/instance") == {200, "instance"}
      assert answer("/instance", person([:factory])) == {200, "instance"}

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, current_scope: person([:factory])}
      }

      assert {:cont, _socket} =
               ApiaryWeb.Features.on_mount({:instance, :factory}, %{}, %{}, socket)
    end

    @tag with_features: @neither
    test "without it, it answers as a path the router does not know, and its gates as a hidden page's" do
      assert answer("/instance") == answer("/no-such-page")
      assert answer("/instance", person([])) == answer("/no-such-page", person([]))

      assert_raise ApiaryWeb.Features.NotFound, fn ->
        ApiaryWeb.Features.on_mount({:instance, :factory}, %{}, %{}, socket())
      end

      gate = ApiaryWeb.Features.init({:instance, :factory})
      conn = ApiaryWeb.Features.call(build_conn(:get, "/instance"), gate)
      assert conn.halted
      assert conn.status == 404

      single = ApiaryWeb.Features.call(build_conn(:get, "/secrets"), :secrets)
      assert conn.resp_body == single.resp_body

      refute ApiaryWeb.Features.page_shown?(InstanceController, person([]))
      refute ApiaryWeb.Features.page_shown?(InstanceController, nil)
    end
  end

  describe "what use is given, checked when the page compiles" do
    test "instance: takes what the page of the organisation takes" do
      assert_raise ArgumentError, ~r/takes the name of a feature, got: nil/, fn ->
        compile_page(quote(do: use(ApiaryWeb.Features, instance: nil)))
      end

      assert_raise ArgumentError, ~r/any: takes two or more names/, fn ->
        compile_page(quote(do: use(ApiaryWeb.Features, instance: [any: [:secrets]])))
      end
    end

    test "any: takes two or more names of features, each once" do
      for features <- [[], [:secrets], [:secrets, :secrets], [:secrets, nil], :secrets, "x"] do
        error =
          assert_raise ArgumentError, fn ->
            compile_page(quote(do: use(ApiaryWeb.Features, any: unquote(features))))
          end

        assert error.message =~
                 "use ApiaryWeb.Features, any: takes two or more names of " <>
                   "features, each once, got: #{inspect(features)}"
      end
    end

    test "the form of one feature still takes a name" do
      assert_raise ArgumentError, ~r/takes the name of a feature, got: nil/, fn ->
        compile_page(quote(do: use(ApiaryWeb.Features, nil)))
      end

      assert_raise ArgumentError, ~r/takes the name of a feature, got: \[some: :thing\]/, fn ->
        compile_page(quote(do: use(ApiaryWeb.Features, some: :thing)))
      end
    end
  end

  describe "the features it names, checked at boot" do
    test "a router whose pages name features there are passes" do
      assert ApiaryWeb.Features.check_routes!(Router) == :ok
    end

    test "a page with any: that names a feature there is not stops the boot, naming it" do
      error =
        assert_raise ArgumentError, fn ->
          ApiaryWeb.Features.check_routes!(UnknownFeatureRouter)
        end

      assert error.message =~
               "UnknownFeatureController uses ApiaryWeb.Features with any: [:secrets, :dispatch], " <>
                 "and :dispatch is not one of"
    end
  end

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  # Compiles a controller whose body is `use_features`, under a name of its own.
  defp compile_page(use_features) do
    name = Module.concat(__MODULE__, "Page#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use Phoenix.Controller, formats: [:html]
          unquote(use_features)
        end
      end
    )
  end
end
