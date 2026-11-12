defmodule ApiaryProWeb.UserLive.NewOrganisation do
  @moduledoc """
  A new organisation for the person, `/users/organisations/new`, where the
  organisation switcher's New organisation entry leads (`ApiaryProWeb.Edition`), from any
  organisation, and the person's organisations page too, for a person in none: an
  organisation of a kind the instance's sign-up settings open, whose first owner they
  are, with no workspace yet (`ApiaryPro.Organisations.create_organisation/2`,
  `organisation.create`). Where both settings open a kind the form asks which.

  With both settings closed neither the entry nor the page is there: the path sends the
  person to their organisations, saying it is not open, and so does a creation refused
  because the settings or the account changed since the page opened. Once it is created
  the person is taken to its overview, `/:org`, where the kind cards create its first
  workspace.

  It is a page of the person's Organisations, a section of their settings: the frame
  keeps the sidebar the person came from and lists their settings as its second column,
  Organisations the current one. It is a form as a separate page: the breadcrumb's Your
  settings / Organisations, which the frame writes, then the step of the set-up
  (`ApiaryWeb.SetUpComponents.frame/1`): the steps list, Your organisation alone
  (`ApiaryProWeb.OrganisationComponents.new_organisation_steps/0`), the title, the form,
  then Create organisation, and Cancel back to Organisations. About organisations says
  who the person becomes and what comes next. The kind is the core's choice field.
  """
  use ApiaryProWeb, :live_view

  alias ApiaryPro.Organisations
  alias ApiaryProWeb.OrganisationComponents
  alias ApiaryWeb.{SettingsComponents, SetUpComponents}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={assigns[:nav_counts]}
      nav={:user_organisations}
      section={:user_organisations}
    >
      <:crumb>{gettext("New organisation")}</:crumb>

      <SetUpComponents.frame steps={@steps}>
        <div id="new-organisation" class="grid gap-5">
          <SetUpComponents.heading>{gettext("New organisation")}</SetUpComponents.heading>

          <.form
            for={@form}
            id="new-organisation-form"
            phx-change="validate"
            phx-submit="create"
            class="q-form"
            novalidate
          >
            <OrganisationComponents.kind_field :if={length(@kinds) > 1} field={@form[:kind]} />
            <.input
              field={@form[:name]}
              type="text"
              label={gettext("Organisation name")}
              autocomplete="organization"
              required
              phx-mounted={length(@kinds) == 1 && JS.focus()}
            />
            <.page_form_foot id="new-organisation-save" cancel={~p"/users/organisations"}>
              <.button
                id="create-organisation"
                variant="primary"
                type="submit"
                loading_text={gettext("Creating")}
              >
                {gettext("Create organisation")}
              </.button>
            </.page_form_foot>
          </.form>
        </div>

        <:context about={gettext("About organisations")}>
          <p>
            {gettext(
              "You become the first owner. You invite its people from Organisation settings › People."
            )}
          </p>
          <p>
            {gettext(
              "Work happens in workspaces. You choose what its first one does on the organisation's overview."
            )}
          </p>
          <p>{gettext("Owners rename the organisation later in Organisation settings.")}</p>
        </:context>
      </SetUpComponents.frame>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_kinds(socket)

    if socket.assigns.kinds != [] do
      {:ok,
       socket
       |> assign(
         :page_title,
         SettingsComponents.page_title(nil, :person, [gettext("New organisation")])
       )
       |> assign(:steps, OrganisationComponents.new_organisation_steps())
       |> assign_form()}
    else
      {:ok, not_open(socket)}
    end
  end

  @impl true
  def handle_event("validate", %{"organisation" => params}, socket) do
    {:noreply, assign_form(socket, params, :validate)}
  end

  def handle_event("create", %{"organisation" => params}, socket) do
    case Organisations.create_organisation(socket.assigns.current_scope, params) do
      {:ok, %{organisation: organisation}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is created, and you are its owner.", name: organisation.name)
         )
         |> redirect(to: ~p"/#{organisation}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :organisation))}

      {:error, _reason} ->
        # The instance's settings or the account changed since the page opened: what it
        # offers is not there any more.
        {:noreply, not_open(socket)}
    end
  end

  # The kinds of organisation the person may create now: none when the instance opens
  # neither, and the page is not there.
  defp assign_kinds(socket),
    do: assign(socket, :kinds, Organisations.new_organisation_kinds(socket.assigns.current_scope))

  defp assign_form(socket, params \\ %{}, action \\ nil) do
    changeset = Organisations.change_new_organisation(params, kinds: socket.assigns.kinds)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :form, to_form(changeset, as: :organisation))
  end

  defp not_open(socket) do
    socket
    |> put_flash(
      :error,
      gettext("You cannot create a new organisation here. %{contact_support}.",
        contact_support: ApiaryWeb.Support.plain()
      )
    )
    |> push_navigate(to: ~p"/users/organisations")
  end
end
