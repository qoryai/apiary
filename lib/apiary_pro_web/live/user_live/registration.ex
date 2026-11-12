defmodule ApiaryProWeb.UserLive.Registration do
  @moduledoc """
  The edition's sign-up page, which the edition's router serves at `/users/register` in
  place of the core's (`ApiaryWeb.UserLive.Registration`), because it offers kinds of
  organisation. With an invitation's token it creates the account that joins the
  invitation's workspace, or its organisation for an invitation without a workspace, and
  asks for the address alone. Without one it offers what `ApiaryPro.SignUp.offer/0` answers
  on mount: before the instance is set up, nothing, and the page says to use its set-up
  link, as the core's page does (`Apiary.Setup`, `ApiaryWeb.SetupLive.not_set_up_line/0`); a
  sign-up of the one kind the instance opens, with no choice; a choice, in plain words,
  where it opens both, an organisation or an operator; and nothing where it opens neither,
  where the page says sign-up is by invitation. `Apiary.Organisations.sign_up_user/3` asks
  again when the form is sent, and hands the kind to the edition, which asks the settings
  again (`ApiaryPro.Tenants.organisation_created/2`).

  A load of the page with an invitation's token counts against the limit of the pages a
  link opens (`ApiaryWeb.AttemptLimits.link_page_mount/1`) before the token is looked up;
  past it, the page redirects with the limit's message, as the core's pages do.

  The page is the account's step of the set-up, in the core's frame
  (`ApiaryWeb.SetUpComponents.frame/1`), with the same progress indicator as the core's:
  Your account and the flow's steps (Name alone without the `factory` feature), for both kinds
  (`ApiaryWeb.SetUpComponents.steps_for/3`). The kind is the core's choice field. Under
  About accounts the page says who the person becomes, what an operator is where the
  operator kind is chosen, and whether the account signs in with a password.

  It follows the core's sign-up page (`ApiaryWeb.UserLive.Registration`) on mail.
  **With mail** (`Apiary.Mail.configured?/0`) the account is made and a link to confirm it
  is emailed; the page says so in place. When the email cannot be sent, the account stays
  made, and the person is sent to the log-in page, which asks for a new link.

  **Without mail** the form asks for a password too
  (`ApiaryWeb.CoreComponents.new_password_fields/1`), an invitation's address cannot be
  changed, and once the account is made the same form is submitted to the log-in
  controller (`phx-trigger-action`, as the core's page does), which signs the person in
  with the password the browser holds. The account is unconfirmed until mail is set and a
  log-in link is followed.
  """
  use ApiaryProWeb, :live_view

  alias Apiary.Accounts
  alias Apiary.Organisations
  alias ApiaryPro.SignUp
  alias ApiaryProWeb.OrganisationComponents
  alias ApiaryWeb.SetUpComponents

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :form_shown, form_shown?(assigns))

    ~H"""
    <Layouts.set_up flash={@flash} current_scope={@current_scope}>
      <SetUpComponents.frame steps={if @form_shown or @sent_to, do: @steps, else: []}>
        <.check_your_email :if={@sent_to}>
          <.rich text={
            rich_gettext("We sent a confirmation link to %{email}. It works for 15 minutes.",
              email: {:b, @sent_to, "font-medium text-base-content"}
            )
          } />
        </.check_your_email>

        <div :if={!@sent_to && by_invitation_only?(assigns)} id="sign-up-closed" class="grid gap-4">
          <SetUpComponents.heading>
            {gettext("Sign-up is by invitation")}
            <:subtitle :if={@mail?}>
              {gettext(
                "Accounts are created by invitation. Ask an owner or an admin of your organisation to invite you; the email they send has the link to sign up."
              )}
            </:subtitle>
            <:subtitle :if={!@mail?}>
              {gettext(
                "Accounts are created by invitation. Ask an owner or an admin of your organisation to invite you; they send you the link to sign up."
              )}
            </:subtitle>
          </SetUpComponents.heading>

          <.button variant="primary" size="md" class="btn-block" navigate={~p"/users/log-in"}>
            {gettext("Sign in")}
          </.button>
        </div>

        <div :if={!@sent_to && not_set_up?(assigns)} id="sign-up-not-set-up" class="grid gap-4">
          <SetUpComponents.heading>
            {gettext("Create your account")}
            <:subtitle>{ApiaryWeb.SetupLive.not_set_up_line()}</:subtitle>
          </SetUpComponents.heading>
        </div>

        <div :if={@form_shown} class="grid gap-4">
          <SetUpComponents.heading>{gettext("Create your account")}</SetUpComponents.heading>

          <.notice :if={@invitation} kind={:info}>
            <.rich text={invited_line(@invitation, @mail?)} />
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
            <OrganisationComponents.kind_field
              :if={!@invitation && choice?(assigns)}
              field={@form[:kind]}
            />
            <.input
              :if={!@invitation}
              field={@form[:organisation_name]}
              type="text"
              label={gettext("Organisation name")}
              size="md"
              autocomplete="organization"
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
            <.button variant="link" navigate={~p"/users/log-in"}>{gettext("Sign in")}</.button>
          </p>
        </div>

        <.dev_mailbox_note />

        <:context :if={@sent_to} about={gettext("About accounts")}>
          <p id="sign-up-context">
            {gettext("The link confirms that the address is yours and signs you in.")}
          </p>
        </:context>
        <:context :if={@form_shown} about={gettext("About accounts")}>
          <p :if={!@invitation} id="sign-up-owner">{owner_line(@kind)}</p>
          <p :if={!@invitation and @kind == :operator} id="sign-up-operator">
            {gettext(
              "An operator creates clients. Each client is a separate organisation; its people belong to it, not to the operator."
            )}
          </p>
          <p id="sign-up-context">{mail_line(@mail?)}</p>
        </:context>
      </SetUpComponents.frame>
    </Layouts.set_up>
    """
  end

  defp form_shown?(%{sent_to: nil} = assigns),
    do: !by_invitation_only?(assigns) && !not_set_up?(assigns)

  defp form_shown?(_assigns), do: false

  defp owner_line(:operator),
    do:
      gettext(
        "You become the owner of the operator. Owners rename it later in Organisation settings."
      )

  defp owner_line(:organisation),
    do:
      gettext(
        "You become the owner of the organisation. Owners rename it later in Organisation settings."
      )

  defp mail_line(true),
    do: gettext("You sign in with a link we email you and need no password.")

  defp mail_line(false),
    do: gettext("You sign in with a password.")

  # What the invitation is to, as the core's page says it. An invitation without a workspace
  # is to the organisation.
  defp invited_line(%{workspace: nil, organisation: organisation}, true = _mail?),
    do:
      rich_gettext(
        "You are invited to %{organisation}. You can open it as soon as you confirm your email address.",
        organisation: {:b, organisation.name}
      )

  defp invited_line(%{workspace: nil, organisation: organisation}, false = _mail?),
    do:
      rich_gettext(
        "You are invited to %{organisation}. You can open it as soon as you create your account.",
        organisation: {:b, organisation.name}
      )

  defp invited_line(%{workspace: workspace, organisation: organisation}, true = _mail?),
    do:
      rich_gettext(
        "You are invited to the %{workspace} workspace at %{organisation}. Your account joins it as soon as you confirm.",
        workspace: {:b, workspace.name},
        organisation: {:b, organisation.name}
      )

  defp invited_line(%{workspace: workspace, organisation: organisation}, false = _mail?),
    do:
      rich_gettext(
        "You are invited to the %{workspace} workspace at %{organisation}. Your account joins it as soon as you create it.",
        workspace: {:b, workspace.name},
        organisation: {:b, organisation.name}
      )

  # Without mail, an invitation's link is the inviter's word for its address: the page
  # shows it, and the sign-up takes it whatever is sent.
  defp fixed_email?(%{invitation: %{}, mail?: false}), do: true
  defp fixed_email?(_assigns), do: false

  defp by_invitation_only?(%{invitation: nil, offer: []}), do: true
  defp by_invitation_only?(_assigns), do: false

  defp not_set_up?(%{invitation: nil, offer: :not_set_up}), do: true
  defp not_set_up?(_assigns), do: false

  defp choice?(%{offer: [_, _ | _]}), do: true
  defp choice?(_assigns), do: false

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ApiaryWeb.UserAuth.signed_in_path(socket))}
  end

  # An invitation's token counts against the limit of the pages a link opens
  # (`ApiaryWeb.AttemptLimits`) before it is looked up, as on the core's sign-up page.
  def mount(%{"invitation" => _} = params, session, socket) do
    case ApiaryWeb.AttemptLimits.link_page_mount(socket) do
      {:ok, socket} -> mount_page(params, session, socket)
      {:limited, socket} -> {:ok, socket}
    end
  end

  def mount(params, session, socket), do: mount_page(params, session, socket)

  defp mount_page(params, _session, socket) do
    token = params["invitation"]
    invitation = token && Organisations.get_invitation_by_token(token)
    email = if invitation, do: invitation.email, else: nil
    offer = if invitation, do: nil, else: SignUp.offer()

    socket =
      socket
      |> assign(:page_title, gettext("Create your account"))
      |> assign(:sent_to, nil)
      |> assign(:invitation_token, if(invitation, do: token, else: nil))
      |> assign(:invitation, invitation)
      |> assign(:offer, offer)
      |> assign(:kind, kind(offer, %{}))
      |> assign(:steps, steps(invitation, token))
      |> assign(:mail?, Apiary.Mail.configured?())
      |> assign(:trigger_submit, false)
      # Where the sign-up comes from, for its audit entry: known while the page mounts.
      |> assign(:origin, ApiaryWeb.Origin.from_socket(socket))

    {:ok, assign_form(socket, change_sign_up(socket, %{"email" => email})),
     temporary_assigns: [form: nil]}
  end

  # The set-up's steps the form is the account's step of, as the core's page lists them.
  defp steps(nil, _token), do: SetUpComponents.steps_for(nil, :account)

  defp steps(invitation, token),
    do: SetUpComponents.steps_for(nil, :account, invitation: invitation, token: token)

  # The kind the page's context speaks of: the one kind the instance opens, else the one
  # chosen in the form, an organisation until one is.
  defp kind([:operator], _params), do: :operator
  defp kind([_, _ | _], %{"kind" => "operator"}), do: :operator
  defp kind(_offer, _params), do: :organisation

  # The form is checked whole, the kind with the rest, before the sign-up is asked for:
  # the core's sign-up checks the kind only as it creates the organisation, so a form that
  # misses the kind and more would first say only what it misses besides.
  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    # With mail the page asks for no password, and sends none: the address is confirmed
    # by email first.
    user_params =
      if socket.assigns.mail?,
        do: Map.drop(user_params, ~w(password password_confirmation)),
        else: user_params

    socket = assign(socket, :kind, kind(socket.assigns.offer, user_params))

    case change_sign_up(socket, user_params) do
      %{valid?: true} -> sign_up(socket, user_params)
      changeset -> {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    socket = assign(socket, :kind, kind(socket.assigns.offer, user_params))
    changeset = change_sign_up(socket, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # The sign-up of a form found whole, which the core asks again.
  defp sign_up(socket, user_params) do
    case Organisations.sign_up_user(user_params, socket.assigns.invitation_token,
           origin: socket.assigns.origin,
           workspace: false
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

      # The instance is not set up: nobody signs up before its set-up link is used.
      {:error, :not_set_up} ->
        {:noreply, assign(socket, :offer, :not_set_up)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # What the instance offers may have changed since the page mounted, and so may
        # its mail, which decides whether the form asks for a password.
        socket =
          if socket.assigns.invitation,
            do: socket,
            else: assign(socket, :offer, SignUp.offer())

        {:noreply, socket |> assign(:mail?, Apiary.Mail.configured?()) |> assign_form(changeset)}
    end
  end

  # The link that confirms the account, emailed, as the core's page sends it. One that
  # cannot be sent leaves the account made: the log-in page sends a new link.
  defp confirm_by_email(socket, user) do
    case Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")) do
      {:ok, _email} ->
        assign(socket, :sent_to, user.email)

      {:error, _reason} ->
        socket
        |> put_flash(
          :error,
          gettext(
            "Your account is made, but the email with its link could not be sent. Ask for a new link on the sign-in page in a few minutes."
          )
        )
        |> push_navigate(to: ~p"/users/log-in")
    end
  end

  defp change_sign_up(socket, params) do
    offer = socket.assigns.offer

    SignUp.change_sign_up(params,
      invited: not is_nil(socket.assigns.invitation),
      kinds: if(is_list(offer), do: offer, else: []),
      validate_unique: false,
      # A password while the instance sends no email, none once it does.
      password: if(socket.assigns.mail?, do: :none, else: :required)
    )
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
