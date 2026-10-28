defmodule ApiaryWeb.NewWorkspaceFormTest.FormLive do
  @moduledoc false
  # The page of `ApiaryWeb.NewWorkspaceFormTest`, defined outside that module: its imports
  # (`Plug.Conn`) clash with a live view's.
  use ApiaryWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.form for={@form} id="new-workspace" phx-change="validate" phx-submit="save">
      <.input field={@form[:name]} type="text" label="Name" />
      <.input field={@form[:slug]} type="text" label="Slug" />
      <.input
        field={@form[:domain]}
        type="radio"
        label="Type"
        options={for d <- Apiary.Lingo.Domain.choices(), do: {d.label(), d.name()}}
      />
      <button type="submit">Create</button>
    </.form>
    <p :if={@created} id="created">{@created.name}</p>
    """
  end

  @impl true
  def mount(_params, %{"scope" => scope}, socket) do
    {:ok,
     socket
     |> assign(scope: scope, created: nil)
     |> assign(:form, to_form(Apiary.Organisations.change_new_workspace(scope, %{})))}
  end

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset =
      socket.assigns.scope
      |> Apiary.Organisations.change_new_workspace(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    case Apiary.Organisations.create_workspace(socket.assigns.scope, params) do
      {:ok, workspace} -> {:noreply, assign(socket, :created, workspace)}
      {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end

defmodule ApiaryWeb.NewWorkspaceFormTest do
  @moduledoc """
  A form that creates a workspace through `Apiary.Organisations.change_new_workspace/2`
  and `create_workspace/2`, as an edition's New workspace page does: its type is a radio
  group with no choice made, its name and its slug text fields. The core has no such page,
  so the test draws one.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Accounts.Scope
  alias ApiaryWeb.NewWorkspaceFormTest.FormLive

  # The core's edition allows one workspace in use: the organisation's Main, marked for
  # deletion, makes room for another and keeps its name and slug.
  setup do
    %{scope: scope, workspace: main} = sign_up_fixture()
    now = DateTime.utc_now()

    main
    |> Ecto.Changeset.change(
      deletion_marked_at: now,
      purge_after: DateTime.add(now, 30, :day),
      purge_trigger: "grace_period"
    )
    |> Apiary.Repo.update!()

    %{
      scope: Organisations.load_scope(Scope.for_user(scope.user), scope.organisation.id),
      main: main
    }
  end

  defp open(scope), do: live_isolated(build_conn(), FormLive, session: %{"scope" => scope})

  test "a name typed before a type is chosen shows no error on the type", %{scope: scope} do
    {:ok, lv, _html} = open(scope)

    html =
      lv |> form("#new-workspace", workspace: %{name: "Data"}) |> render_change()

    refute html =~ "Choose a type."
    refute has_element?(lv, "#workspace_domain-error")
  end

  test "a form sent with no type says to choose one", %{scope: scope} do
    {:ok, lv, _html} = open(scope)

    lv |> form("#new-workspace", workspace: %{name: "Data"}) |> render_submit()

    assert has_element?(lv, "#workspace_domain-error", "Choose a type.")
    refute render(lv) =~ "be blank"
    refute has_element?(lv, "#created")
  end

  test "a form sent with no type and a taken name and slug shows all three errors",
       %{scope: scope, main: main} do
    {:ok, lv, _html} = open(scope)

    lv
    |> form("#new-workspace", workspace: %{name: main.name, slug: main.slug})
    |> render_submit()

    assert has_element?(lv, "#workspace_domain-error", "Choose a type.")

    assert has_element?(
             lv,
             "#workspace_name-error",
             "is already the name of a workspace in this organisation"
           )

    assert has_element?(
             lv,
             "#workspace_slug-error",
             "is already the slug of a workspace in this organisation"
           )
  end

  test "a type chosen and a free name create the workspace", %{scope: scope} do
    {:ok, lv, _html} = open(scope)

    lv
    |> form("#new-workspace", workspace: %{name: "Ops", domain: "example"})
    |> render_submit()

    assert has_element?(lv, "#created", "Ops")
    assert [%{name: "Ops", domain: "example"}] = Organisations.list_workspaces(scope)
  end
end
