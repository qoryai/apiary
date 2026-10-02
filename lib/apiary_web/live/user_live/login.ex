defmodule ApiaryWeb.UserLive.Login do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts
  alias Apiary.Accounts.User

  # Shown for an address that cannot be one, before anything is looked up: it says
  # nothing about whether an account exists.
  @email_error dgettext_noop("errors", "Enter an email address, such as dana@example.com.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.check_your_email :if={@sent_to} on_back="use_different_email">
        <.rich text={
          rich_gettext(
            "If %{email} has an account, a log-in link is on its way. It works for 15 minutes.",
            email: {:b, @sent_to, "font-medium text-base-content"}
          )
        } />
      </.check_your_email>

      <div :if={!@sent_to} class="grid gap-4">
        <Layouts.auth_heading>
          {if @current_scope, do: gettext("Confirm it is you"), else: gettext("Log in to Qory Apiary")}
          <:subtitle>
            <%= cond do %>
              <% @current_scope -> %>
                {gettext("Log in again to change sensitive account settings.")}
              <% @mode == :password -> %>
                {gettext("Enter the password you set in account settings.")}
              <% true -> %>
                {gettext("We will email you a link. No password needed.")}
            <% end %>
          </:subtitle>
        </Layouts.auth_heading>

        <.form
          :let={f}
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-change="change"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="grid gap-4"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label={gettext("Email")}
            size="md"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={@mode == :magic && JS.focus()}
          />
          <div :if={@mode == :password} id="login_password" class="grid gap-4">
            <div class="grid gap-1.5">
              <%!-- Never patched: the typed password is not echoed back by the server. --%>
              <div id="login_password_field" phx-update="ignore">
                <.input
                  field={f[:password]}
                  type="password"
                  label={gettext("Password")}
                  size="md"
                  autocomplete="current-password"
                  spellcheck="false"
                  required
                  phx-mounted={JS.focus()}
                />
              </div>
              <%!-- Outside the field, which is never patched: the error marks the field
                   as it comes and goes. --%>
              <p
                :if={@password_missing}
                id="login_form_password-error"
                class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
                phx-mounted={
                  JS.set_attribute({"aria-invalid", "true"}, to: "#login_form_password")
                  |> JS.set_attribute({"aria-describedby", "login_form_password-error"},
                    to: "#login_form_password"
                  )
                  |> JS.add_class("input-error", to: "#login_form_password")
                }
                phx-remove={
                  JS.remove_attribute("aria-invalid", to: "#login_form_password")
                  |> JS.remove_attribute("aria-describedby", to: "#login_form_password")
                  |> JS.remove_class("input-error", to: "#login_form_password")
                }
              >
                <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
                {gettext("Enter your password.")}
              </p>
            </div>
            <.input
              :if={!@current_scope}
              field={f[:remember_me]}
              type="checkbox"
              label={gettext("Keep me signed in")}
              checked={@remember_me}
            />
          </div>
          <div class="grid gap-2">
            <.button
              variant="primary"
              size="md"
              class="btn-block"
              loading_text={
                if @mode == :password, do: gettext("Logging in"), else: gettext("Sending")
              }
            >
              {if @mode == :password, do: gettext("Log in"), else: gettext("Send me a log-in link")}
            </.button>
            <.button
              type="button"
              variant="ghost"
              size="md"
              class="btn-block"
              phx-click="toggle_mode"
              aria-expanded={to_string(@mode == :password)}
              aria-controls="login_password"
            >
              {if @mode == :password,
                do: gettext("Email me a link instead"),
                else: gettext("Use a password instead")}
            </.button>
          </div>
        </.form>

        <p :if={!@current_scope && @sign_up?} class="mt-1 text-center text-[13px]/[18px] text-muted">
          {gettext("New to Qory Apiary?")}
          <.button variant="link" navigate={~p"/users/register"}>
            {gettext("Create an account")}
          </.button>
        </p>
      </div>

      <.dev_mailbox_note />
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # A failed password log-in comes back with the email in the flash: stay in
    # password mode, where the person was.
    flash_email = Phoenix.Flash.get(socket.assigns.flash, :email)

    email =
      flash_email ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    {:ok,
     assign(socket,
       form: to_form(%{"email" => email}, as: "user"),
       mode: if(flash_email, do: :password, else: :magic),
       password_missing: false,
       remember_me: true,
       sent_to: nil,
       trigger_submit: false,
       # Sign-up without an invitation, where the instance offers it: an invitation's
       # email links to the sign-up page itself.
       sign_up?: Apiary.Organisations.sign_up_offered?(),
       page_title: gettext("Log in")
     )}
  end

  @impl true
  def handle_event("change", %{"user" => params}, socket) do
    # Once a submit has shown an error, it goes as soon as the field is right.
    checked? = socket.assigns.form.errors != []

    {:noreply,
     socket
     |> assign(:form, email_form(params, checked?))
     |> assign(:password_missing, socket.assigns.password_missing and blank?(params["password"]))
     |> assign(:remember_me, Map.get(params, "remember_me", "true") == "true")}
  end

  def handle_event("toggle_mode", _params, socket) do
    mode = if socket.assigns.mode == :magic, do: :password, else: :magic
    {:noreply, assign(socket, mode: mode, password_missing: false)}
  end

  def handle_event("submit", %{"user" => params}, %{assigns: %{mode: :password}} = socket) do
    form = email_form(params, true)
    password_missing = blank?(params["password"])

    {:noreply,
     socket
     |> assign(form: form, password_missing: password_missing)
     |> assign(:trigger_submit, form.errors == [] and not password_missing)}
  end

  def handle_event("submit", %{"user" => params}, socket) do
    case email_form(params, true) do
      %{errors: []} ->
        email = params["email"]

        if user = Accounts.get_user_by_email(email) do
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )
        end

        # The same answer whether or not the address has an account.
        {:noreply, assign(socket, :sent_to, email)}

      form ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  def handle_event("use_different_email", _params, socket) do
    {:noreply, assign(socket, sent_to: nil, form: to_form(%{"email" => nil}, as: "user"))}
  end

  # The form of the email alone, the password never echoed back; checked, it carries the
  # error of an address that cannot be one: empty, without an @, with a space, too long.
  defp email_form(params, checked?) do
    params = %{"email" => Map.get(params, "email", "")}

    errors =
      if checked? and
           not Accounts.change_user_email(%User{}, params, validate_unique: false).valid?,
         do: [email: {@email_error, []}],
         else: []

    to_form(params, as: "user", errors: errors, action: if(errors != [], do: :validate))
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
