# A page of the Instance level, with the feature `factory`, and a LiveComponent on it that
# sends the test a message at each event.
defmodule ApiaryWeb.FeaturesComponentGateTest.Counter do
  @moduledoc false
  use ApiaryWeb, :live_component

  @impl true
  def mount(socket), do: {:ok, assign(socket, :count, 0)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <button type="button" phx-click="bump" phx-target={@myself}>Bump</button>
      <span class="count">{@count}</span>
    </div>
    """
  end

  @impl true
  def handle_event("bump", _params, socket) do
    send(socket.assigns.test, :bumped)
    {:noreply, update(socket, :count, &(&1 + 1))}
  end
end

defmodule ApiaryWeb.FeaturesComponentGateTest.Page do
  @moduledoc false
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  @impl true
  def mount(_params, %{"scope" => scope, "test" => test}, socket),
    do: {:ok, assign(socket, current_scope: scope, test: test)}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={ApiaryWeb.FeaturesComponentGateTest.Counter}
      id="counter"
      test={@test}
    />
    """
  end
end

defmodule ApiaryWeb.FeaturesComponentGateTest.AsyncPage do
  @moduledoc false
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  # Once connected, an async read that waits for the test's `:go`, and whose result sends
  # the test `:wrote`.
  @impl true
  def mount(_params, %{"scope" => scope, "test" => test}, socket) do
    socket = assign(socket, current_scope: scope, test: test)

    if connected?(socket) do
      {:ok,
       start_async(socket, :read, fn ->
         send(test, {:reading, self()})

         receive do
           :go -> :done
         end
       end)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns), do: ~H"<p>Async</p>"

  @impl true
  def handle_async(:read, {:ok, :done}, socket) do
    send(socket.assigns.test, :wrote)
    {:noreply, socket}
  end
end

defmodule ApiaryWeb.FeaturesComponentGateTest do
  # An event sent to a LiveComponent of an open page whose feature goes off
  # (`ApiaryWeb.Features.component_gate/1`) does nothing, and the page moves away as an
  # event of the LiveView moves it. The node's copy of the features changes here with no
  # broadcast, so the page stays open for the event. Not async: the features are the whole
  # node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  @moduletag needs: :factory
  @moduletag :feature_sets

  setup do
    previous = Application.get_env(:apiary, :features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
    :ok
  end

  test "a component's event does nothing once the page's feature is off, and the page moves",
       %{conn: conn} do
    %{scope: scope} = sign_up_fixture()

    {:ok, view, _html} =
      live_isolated(conn, ApiaryWeb.FeaturesComponentGateTest.Page,
        session: %{"scope" => scope, "test" => self()}
      )

    view |> element("#counter button") |> render_click()
    assert_received :bumped

    enabled = Apiary.Features.enabled()

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(enabled, enabled -- [:factory])
    )

    view |> element("#counter button") |> render_click()
    refute_received :bumped

    flash = assert_redirect(view, ~p"/instance/general")

    assert flash["error"] ==
             "That page is no longer shown: its feature is off in Instance settings › Features."
  end

  test "an async result does nothing once the page's feature is off, and the page moves",
       %{conn: conn} do
    %{scope: scope} = sign_up_fixture()

    {:ok, view, _html} =
      live_isolated(conn, ApiaryWeb.FeaturesComponentGateTest.AsyncPage,
        session: %{"scope" => scope, "test" => self()}
      )

    assert_receive {:reading, task}
    enabled = Apiary.Features.enabled()

    Application.put_env(
      :apiary,
      :features,
      Apiary.Features.Saved.close(enabled, enabled -- [:factory])
    )

    send(task, :go)
    flash = assert_redirect(view, ~p"/instance/general")

    assert flash["error"] ==
             "That page is no longer shown: its feature is off in Instance settings › Features."

    refute_received :wrote
  end
end
