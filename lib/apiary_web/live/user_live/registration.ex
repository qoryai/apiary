defmodule ApiaryWeb.UserLive.Registration do
  @moduledoc """
  The sign-up page, `/users/register`. With an invitation's token it creates the account
  that joins the invitation's workspace, and asks for the address alone. Without one it
  offers what `Apiary.Organisations.sign_up_offer/1` answers on mount: the instance's
  first sign-up, which creates the organisation its first user owns; a later sign-up,
  where the edition opens one, of an organisation; and nothing where none is open,
  where the page says sign-up is by invitation. `Apiary.Organisations.sign_up_user/3`
  asks again when the form is sent.

  **With mail** (`Apiary.Mail.configured?/0`) the account is made and a link to confirm
  it is emailed; the page says so in place. When the email cannot be sent, the account
  stays made, and the person is sent to the log-in page, which asks for a new link.

  **Without mail** the form asks for a password too (`ApiaryWeb.CoreComponents.new_password_fields/1`),
  an invitation's address cannot be changed, and once the account is made the same form
  is submitted to the log-in controller (`phx-trigger-action`, as the log-in page does),
  which signs the person in with the password the browser holds. The account is
  unconfirmed until mail is set and a log-in link is followed.

  An edition whose sign-up asks more of the form serves its own page at this path
  (`ApiaryWeb.Routes`, `except:`).
  """
  use ApiaryWeb, :live_view

  alias Apiary.Accounts
  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.check_your_email :if={@sent_to}>
        <.rich text={
          rich_gettext("We sent a confirmation link to %{email}. It works for 15 minutes.",
            email: {:b, @sent_to, "font-medium text-base-content"}
          )
        } />
      </.check_your_email>

      <div :if={!@sent_to && by_invitation_only?(assigns)} id="sign-up-closed" class="grid gap-4">
        <Layouts.auth_heading>
          {gettext("Sign-up is by invitation")}
          <:subtitle :if={@mail?}>
            {gettext(
              "Accounts on this instance are created by invitation. Ask an owner or an admin of your organisation to invite you; the email they send has the link to sign up."
            )}
          </:subtitle>
          <:subtitle :if={!@mail?}>
            {gettext(
              "Accounts on this instance are created by invitation. Ask an owner or an admin of your organisation to invite you; they send you the link to sign up."
            )}
          </:subtitle>
        </Layouts.auth_heading>

        <.button variant="primary" size="md" class="btn-block" navigate={~p"/users/log-in"}>
          {gettext("Log in")}
        </.button>
      </div>

      <div :if={!@sent_to && !by_invitation_only?(assigns)} class="grid gap-4">
        <Layouts.auth_heading>
          {gettext("Create your account")}
          <:subtitle>{subtitle(assigns)}</:subtitle>
        </Layouts.auth_heading>

        <.notice :if={@invitation && @mail?} kind={:info}>
          <.rich text={
            rich_gettext(
              "You are invited to the %{workspace} workspace at %{organisation}. Your account joins it as soon as you confirm.",
              workspace: {:b, @invitation.workspace.name},
              organisation: {:b, @invitation.organisation.name}
            )
          } />
        </.notice>
        <.notice :if={@invitation && !@mail?} kind={:info}>
          <.rich text={
            rich_gettext(
              "You are invited to the %{workspace} workspace at %{organisation}. Your account joins it as soon as you create it.",
              workspace: {:b, @invitation.workspace.name},
              organisation: {:b, @invitation.organisation.name}
            )
          } />
        </.notice>

        <.form
          for={@form}
          id="registration_form"
          action={!@mail? && ~p"/users/log-in"}
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
            readonly={fixed_email?(assigns)}
            phx-mounted={!fixed_email?(assigns) && JS.focus()}
          />
          <.input
            :if={!@invitation}
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
          <.new_password_fields
            :if={!@mail?}
            password={@form[:password]}
            confirmation={@form[:password_confirmation]}
            size="md"
          />
          <.button variant="primary" size="md" class="btn-block" loading_text={gettext("Creating")}>
            {gettext("Create account")}
          </.button>
        </.form>

        <p class="mt-1 text-center text-[13px]/[18px] text-muted">
          {gettext("Already have an account?")}
          <.button variant="link" navigate={~p"/users/log-in"}>{gettext("Log in")}</.button>
        </p>
      </div>

      <.dev_mailbox_note />
    </Layouts.auth>
    """
  end

  # What the page says it creates: an organisation. The first sign-up of an instance
  # creates an organisation like any other, to the person who makes it.
  defp subtitle(%{invitation: %{}, mail?: true}),
    do: gettext("We will email you a link to confirm; no password needed.")

  defp subtitle(%{invitation: %{}}), do: gettext("Choose a password to sign in with.")

  defp subtitle(%{mail?: true}),
    do:
      gettext(
        "Start an organisation and its first workspace. We will email you a link to confirm; no password needed."
      )

  defp subtitle(_assigns),
    do:
      gettext("Start an organisation and its first workspace. Choose a password to sign in with.")

  # Without mail, an invitation's link is the inviter's word for its address: the page
  # shows it, and the sign-up takes it whatever is sent.
  defp fixed_email?(%{invitation: %{}, mail?: false}), do: true
  defp fixed_email?(_assigns), do: false

  defp by_invitation_only?(%{invitation: nil, offer: :closed}), do: true
  defp by_invitation_only?(_assigns), do: false

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ApiaryWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, _session, socket) do
    token = params["invitation"]
    invitation = token && Organisations.get_invitation_by_token(token)
    email = if invitation, do: invitation.email, else: nil
    offer = if invitation, do: nil, else: Organisations.sign_up_offer()

    socket =
      socket
      |> assign(:page_title, gettext("Create your account"))
      |> assign(:sent_to, nil)
      |> assign(:invitation_token, if(invitation, do: token, else: nil))
      |> assign(:invitation, invitation)
      |> assign(:offer, offer)
      |> assign(:mail?, Apiary.Mail.configured?())
      |> assign(:trigger_submit, false)
      # Where the sign-up comes from, for its audit entry: known while the page mounts.
      |> assign(:origin, ApiaryWeb.Origin.from_socket(socket))

    {:ok, assign_form(socket, change_sign_up(socket, %{"email" => email})),
     temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # With mail the page asks for no password, and sends none: the address is confirmed
    # by email first.
    user_params =
      if socket.assigns.mail?,
        do: Map.drop(user_params, ~w(password password_confirmation)),
        else: user_params

    case Organisations.sign_up_user(user_params, socket.assigns.invitation_token,
           origin: socket.assigns.origin
         ) do
      # Without mail, a password was set: the same form goes to the log-in controller,
      # with the address the account has, and signs the person in.
      {:ok, %{user: %{hashed_password: hash} = user}}
      when is_binary(hash) and not socket.assigns.mail? ->
        {:noreply,
         socket
         |> assign_form(change_sign_up(socket, %{"email" => user.email}))
         |> assign(:trigger_submit, true)}

      {:ok, %{user: user}} ->
        {:noreply, confirm_by_email(socket, user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # What the instance offers may have changed since the page mounted: another
        # sign-up was the instance's first. So may its mail, which decides whether the
        # form asks for a password.
        socket =
          if socket.assigns.invitation,
            do: socket,
            else: assign(socket, :offer, Organisations.sign_up_offer())

        {:noreply, socket |> assign(:mail?, Apiary.Mail.configured?()) |> assign_form(changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = change_sign_up(socket, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # The link that confirms the account, emailed. One that cannot be sent leaves the
  # account made: the log-in page sends a new link.
  defp confirm_by_email(socket, user) do
    case Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")) do
      {:ok, _email} ->
        assign(socket, :sent_to, user.email)

      {:error, _reason} ->
        socket
        |> put_flash(
          :error,
          gettext(
            "Your account is made, but the email with its link could not be sent. Ask for a new link on the log-in page in a few minutes."
          )
        )
        |> push_navigate(to: ~p"/users/log-in")
    end
  end

  defp change_sign_up(socket, params) do
    Organisations.change_sign_up(params,
      invited: not is_nil(socket.assigns.invitation),
      validate_unique: false
    )
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
