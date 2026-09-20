defmodule ApiaryWeb.UserLive.Confirmation do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts

  @impl true
  def render(%{user: nil} = assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.hex_tile icon="hero-clock" tone="neutral" />
      <Layouts.auth_heading>
        That link has expired
        <:subtitle>Log-in links work once and for a short time. Ask for a new one.</:subtitle>
      </Layouts.auth_heading>
      <.button variant="primary" size="md" class="btn-block" navigate={~p"/users/log-in"}>
        Send a new link
      </.button>
    </Layouts.auth>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <Layouts.auth_heading>
        {if @user.confirmed_at, do: "Welcome back", else: "Welcome to Qory Apiary"}
        <:subtitle><span class="break-all">{@user.email}</span></:subtitle>
      </Layouts.auth_heading>

      <.form
        for={@form}
        id={if @user.confirmed_at, do: "login_form", else: "confirmation_form"}
        phx-submit="submit"
        action={
          if @user.confirmed_at, do: ~p"/users/log-in", else: ~p"/users/log-in?_action=confirmed"
        }
        phx-trigger-action={@trigger_submit}
        class="grid gap-4"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <.input
          :if={!@current_scope}
          field={@form[:remember_me]}
          type="checkbox"
          label="Keep me signed in"
          checked={@form[:remember_me].value != "false"}
        />
        <.button
          variant="primary"
          size="md"
          class="btn-block"
          loading_text={if @user.confirmed_at, do: "Logging in", else: "Confirming"}
          phx-mounted={JS.focus()}
        >
          {if @user.confirmed_at, do: "Log in", else: "Confirm my account"}
        </.button>
      </.form>

      <p :if={!@user.confirmed_at} class="text-center text-[13px]/[18px] text-muted">
        Prefer a password? You can set one in account settings.
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    user = Accounts.get_user_by_magic_link_token(token)
    form = to_form(%{"token" => token}, as: "user")

    {:ok,
     assign(socket,
       user: user,
       form: form,
       trigger_submit: false,
       page_title: if(user, do: "Log in", else: "That link has expired")
     ), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
