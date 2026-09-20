defmodule ApiaryWeb.UserLive.Login do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="mb-6 text-center">
        <h1 class="text-lg font-semibold tracking-tight text-ink">Log in</h1>
        <p class="mt-1 text-sm text-ink-muted">
          <%= if @current_scope do %>
            You need to reauthenticate to perform sensitive actions on your account.
          <% else %>
            Don't have an account? <.link
              navigate={~p"/users/register"}
              class="font-medium text-ink underline-offset-4 hover:underline"
              phx-no-format
            >Sign up</.link> for an account now.
          <% end %>
        </p>
      </div>

      <.notice :if={local_mail_adapter?()} kind={:info} class="mb-5">
        <p>You are running the local mail adapter.</p>
        <p>
          To see sent emails, visit <.link
            href="/dev/mailbox"
            class="font-medium text-ink underline underline-offset-4"
          >
            the mailbox page
          </.link>.
        </p>
      </.notice>

      <.form
        :let={f}
        for={@form}
        id="login_form_magic"
        action={~p"/users/log-in"}
        phx-submit="submit_magic"
      >
        <.input
          readonly={!!@current_scope}
          field={f[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.button variant="primary" class="w-full">
          Log in with email <span aria-hidden="true">→</span>
        </.button>
      </.form>

      <div class="my-6 flex items-center gap-3 text-xs uppercase tracking-wide text-ink-faint">
        <span class="h-px flex-1 bg-line" /> or <span class="h-px flex-1 bg-line" />
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_password"
        action={~p"/users/log-in"}
        phx-submit="submit_password"
        phx-trigger-action={@trigger_submit}
      >
        <.input
          readonly={!!@current_scope}
          field={f[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          spellcheck="false"
        />
        <.button variant="primary" class="w-full" name={@form[:remember_me].name} value="true">
          Log in and stay logged in <span aria-hidden="true">→</span>
        </.button>
        <.button class="mt-2 w-full">
          Log in only this time
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false, page_title: "Log in")}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:apiary, Apiary.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
