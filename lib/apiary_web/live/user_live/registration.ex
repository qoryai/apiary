defmodule ApiaryWeb.UserLive.Registration do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts
  alias Apiary.Accounts.User
  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="mb-6 text-center">
        <h1 class="text-lg font-semibold tracking-tight text-ink">Register</h1>
        <p class="mt-1 text-sm text-ink-muted">
          Already registered?
          <.link
            navigate={~p"/users/log-in"}
            class="font-medium text-ink underline-offset-4 hover:underline"
          >
            Log in
          </.link>
          to your account.
        </p>
      </div>

      <.notice :if={@invitation} kind={:info} class="mb-5">
        <p>
          You have been invited to join the <strong class="text-ink">{@invitation.hive.name}</strong>
          <.term word="hive" /> at <strong class="text-ink">{@invitation.organisation.name}</strong>.
          Your account will be part of it as soon as you register.
        </p>
      </.notice>

      <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />

        <.button variant="primary" phx-disable-with="Creating account..." class="w-full">
          Create an account
        </.button>
      </.form>

      <p class="mt-5 text-center text-[13px] text-ink-faint">
        We will email you a link to confirm your address. No password needed.
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ApiaryWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, _session, socket) do
    token = params["invitation"]
    invitation = token && Organisations.get_invitation_by_token(token)
    email = if invitation, do: invitation.email, else: nil

    changeset = Accounts.change_user_email(%User{}, %{"email" => email}, validate_unique: false)

    {:ok,
     socket
     |> assign(:page_title, "Register")
     |> assign(:invitation_token, if(invitation, do: token, else: nil))
     |> assign(:invitation, invitation)
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Organisations.sign_up_user(user_params, socket.assigns.invitation_token) do
      {:ok, %{user: user}} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
