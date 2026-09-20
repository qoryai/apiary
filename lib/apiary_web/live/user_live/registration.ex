defmodule ApiaryWeb.UserLive.Registration do
  use ApiaryWeb, :live_view

  alias Apiary.Accounts
  alias Apiary.Accounts.User
  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.check_your_email :if={@sent_to}>
        We sent a confirmation link to <strong class="font-medium text-base-content">{@sent_to}</strong>.
        It works for 15 minutes.
      </.check_your_email>

      <div :if={!@sent_to} class="grid gap-4">
        <Layouts.auth_heading>
          Create your account
          <:subtitle>
            Start an <.term word="apiary" /> for your workplace. We will email you a link to confirm;
            no password needed.
          </:subtitle>
        </Layouts.auth_heading>

        <.notice :if={@invitation} kind={:info}>
          You are invited to the <strong>{@invitation.hive.name}</strong>
          <.term word="hive" /> at <strong>{@invitation.organisation.name}</strong>.
          Your account joins it as soon as you confirm.
        </.notice>

        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          class="grid gap-4"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            size="md"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" size="md" class="btn-block" loading_text="Creating">
            Create account
          </.button>
        </.form>

        <p class="mt-1 text-center text-[13px]/[18px] text-muted">
          Already have an account?
          <.button variant="link" navigate={~p"/users/log-in"}>Log in</.button>
        </p>
      </div>

      <.dev_mailbox_note />
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
     |> assign(:page_title, "Create your account")
     |> assign(:sent_to, nil)
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

        {:noreply, assign(socket, :sent_to, user.email)}

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
