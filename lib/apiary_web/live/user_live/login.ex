defmodule ApiaryWeb.UserLive.Login do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.check_your_email :if={@sent_to} on_back="use_different_email">
        If <strong class="font-medium text-base-content">{@sent_to}</strong>
        has an account, a log-in link is on its way. It works for 15 minutes.
      </.check_your_email>

      <div :if={!@sent_to} class="grid gap-4">
        <Layouts.auth_heading>
          {if @current_scope, do: "Confirm it is you", else: "Log in to Qory"}
          <:subtitle>
            <%= cond do %>
              <% @current_scope -> %>
                Log in again to change sensitive account settings.
              <% @mode == :password -> %>
                Enter the password you set in account settings.
              <% true -> %>
                We will email you a link. No password needed.
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
            label="Email"
            size="md"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={@mode == :magic && JS.focus()}
          />
          <div :if={@mode == :password} id="login_password" class="grid gap-4">
            <%!-- Never patched: the typed password is not echoed back by the server. --%>
            <div id="login_password_field" phx-update="ignore">
              <.input
                field={f[:password]}
                type="password"
                label="Password"
                size="md"
                autocomplete="current-password"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
            </div>
            <.input
              :if={!@current_scope}
              field={f[:remember_me]}
              type="checkbox"
              label="Keep me signed in"
              checked={@remember_me}
            />
          </div>
          <div class="grid gap-2">
            <.button
              variant="primary"
              size="md"
              class="btn-block"
              loading_text={if @mode == :password, do: "Logging in", else: "Sending"}
            >
              {if @mode == :password, do: "Log in", else: "Send me a log-in link"}
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
              {if @mode == :password, do: "Email me a link instead", else: "Use a password instead"}
            </.button>
          </div>
        </.form>

        <p :if={!@current_scope} class="mt-1 text-center text-[13px]/[18px] text-muted">
          New to Qory?
          <.button variant="link" navigate={~p"/users/register"}>Create an account</.button>
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
       remember_me: true,
       sent_to: nil,
       trigger_submit: false,
       page_title: "Log in"
     )}
  end

  @impl true
  def handle_event("change", %{"user" => params}, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(Map.take(params, ["email"]), as: "user"))
     |> assign(:remember_me, Map.get(params, "remember_me", "true") == "true")}
  end

  def handle_event("toggle_mode", _params, socket) do
    mode = if socket.assigns.mode == :magic, do: :password, else: :magic
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("submit", %{"user" => params}, %{assigns: %{mode: :password}} = socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(Map.take(params, ["email"]), as: "user"))
     |> assign(:trigger_submit, true)}
  end

  def handle_event("submit", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    # The same answer whether or not the address has an account.
    {:noreply, assign(socket, :sent_to, email)}
  end

  def handle_event("use_different_email", _params, socket) do
    {:noreply, assign(socket, sent_to: nil, form: to_form(%{"email" => nil}, as: "user"))}
  end
end
