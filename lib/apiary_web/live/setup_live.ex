defmodule ApiaryWeb.SetupLive do
  @moduledoc """
  The set-up page, `/setup/<code>`, the link a new instance logs at every start until it
  is used (`Apiary.Setup`). With the stored code it asks for an email address, a password
  and its confirmation, and the organisation's name; it makes the instance's first
  account, an instance admin, its organisation and the workspace Main
  (`Apiary.Setup.set_up/3`), and the edition says what is created
  (`c:Apiary.Edition.first_sign_up_line/0`). Once it is accepted, the same form is
  submitted to the log-in controller (`phx-trigger-action`, as the sign-up page does),
  which signs the person in with the password the browser holds.

  Once the instance is set up, any code gets "already set up" and the way to log in.
  Before, a code that is not the stored one is a path that does not exist
  (`ApiaryWeb.NotFound`). Each load counts against the limit on the pages a link opens,
  before the code is looked up.

  The code is held in the page's process for the set-up alone, in a struct that inspects
  without it, so a crash report does not print it; it is never drawn on the page.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Organisations, Setup}

  defmodule HeldCode do
    @moduledoc false
    # The code the page was opened with, which inspects without its value.
    @derive {Inspect, except: [:value]}
    @enforce_keys [:value]
    defstruct [:value]
  end

  # TODO(fg49/mail-p4): once ApiaryWeb.AttemptLimits is merged, call
  # `ApiaryWeb.AttemptLimits.link_page_mount/1` directly in `count_attempt/1`, and drop
  # this line and the check of the module there.
  @compile {:no_warn_undefined, ApiaryWeb.AttemptLimits}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div :if={@state == :set_up} id="setup-done" class="grid gap-4">
        <Layouts.auth_heading>
          {gettext("This Qory Apiary is already set up.")}
        </Layouts.auth_heading>
        <.button
          :if={@current_scope && @current_scope.user}
          variant="primary"
          size="md"
          class="btn-block"
          href={~p"/"}
        >
          {gettext("Go to your workspace")}
        </.button>
        <.button
          :if={!(@current_scope && @current_scope.user)}
          variant="primary"
          size="md"
          class="btn-block"
          navigate={~p"/users/log-in"}
        >
          {gettext("Log in")}
        </.button>
      </div>

      <div :if={@state == :form} class="grid gap-4">
        <Layouts.auth_heading>
          {gettext("Set up Qory Apiary")}
          <:subtitle>{@line} {gettext("You become this instance's admin.")}</:subtitle>
        </Layouts.auth_heading>

        <.form
          for={@form}
          id="setup_form"
          action={~p"/users/log-in"}
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            size="md"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.new_password_fields
            password={@form[:password]}
            confirmation={@form[:password_confirmation]}
            size="md"
          />
          <.input
            field={@form[:organisation_name]}
            type="text"
            label={gettext("Organisation name")}
            size="md"
            autocomplete="organization"
            hint={
              gettext(
                "Usually your company's name. Owners can change it later in the organisation's settings."
              )
            }
            required
          />
          <.button variant="primary" size="md" class="btn-block" loading_text={gettext("Setting up")}>
            {gettext("Set up")}
          </.button>
        </.form>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    case count_attempt(socket) do
      {:ok, socket} -> {:ok, open(socket, code), temporary_assigns: [form: nil]}
      {:limited, socket} -> {:ok, socket}
    end
  end

  # What the page shows for `code`: "already set up" once the instance is; the form for
  # the stored code; and a path that does not exist for any other. A trailing full stop,
  # which the log line puts after the link, is no part of a code.
  defp open(socket, code) do
    code = String.trim_trailing(code, ".")

    cond do
      Setup.set_up?() ->
        assign_done(socket)

      Setup.valid_code?(code) ->
        socket
        |> assign(:page_title, gettext("Set up"))
        |> assign(:state, :form)
        |> assign(:code, %HeldCode{value: code})
        |> assign(:line, Apiary.Edition.first_sign_up_line())
        |> assign(:trigger_submit, false)
        # Where the set-up comes from, for its audit entry: known while the page mounts.
        |> assign(:origin, ApiaryWeb.Origin.from_socket(socket))
        |> assign_form(change_set_up(%{}))

      true ->
        raise ApiaryWeb.NotFound
    end
  end

  defp assign_done(socket) do
    socket
    |> assign(:page_title, gettext("Set up"))
    |> assign(:state, :set_up)
    |> assign(:code, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, assign_form(socket, Map.put(change_set_up(params), :action, :validate))}
  end

  def handle_event("save", %{"user" => params}, %{assigns: %{state: :form}} = socket) do
    %HeldCode{value: code} = socket.assigns.code

    case Setup.set_up(code, params, password: :required, origin: socket.assigns.origin) do
      # The same form goes to the log-in controller, with the address the account has,
      # and signs the person in with the password the browser holds.
      {:ok, %{user: user}} ->
        {:noreply,
         socket
         |> assign(:code, nil)
         |> assign_form(change_set_up(%{"email" => user.email}))
         |> assign(:trigger_submit, true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      # Set up a moment before.
      {:error, :already_set_up} ->
        {:noreply, assign_done(socket)}

      # The code is no longer the stored one: the page as it would open now.
      {:error, :invalid_code} ->
        {:noreply, redirect(socket, to: ~p"/setup/#{code}")}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  @doc """
  not_set_up_line/0 is what the sign-up and log-in pages say before the instance is set
  up, in place of their forms.
  """
  @spec not_set_up_line() :: String.t()
  def not_set_up_line,
    do: gettext("This Qory Apiary is not set up yet: use the set-up link from its install.")

  defp change_set_up(params),
    do: Organisations.change_sign_up(params, validate_unique: false, password: :required)

  defp assign_form(socket, %Ecto.Changeset{} = changeset),
    do: assign(socket, :form, to_form(changeset, as: "user"))

  # Each load counts against the limit on the pages a link opens, before the code is
  # looked up (`ApiaryWeb.AttemptLimits.link_page_mount/1`, once it is merged).
  defp count_attempt(socket) do
    if Code.ensure_loaded?(ApiaryWeb.AttemptLimits),
      do: ApiaryWeb.AttemptLimits.link_page_mount(socket),
      else: {:ok, socket}
  end
end
