defmodule ApiaryWeb.UserLive.Password do
  @moduledoc """
  A password link's page, `/users/password/:token`: it sets the password of the account
  the link is for (`Apiary.Accounts.build_password_link/3`), which an instance admin makes
  on the People page of the instance's organisation while no mail is set, and a release
  command prints (`Apiary.Release.password_link/1`).

  The page names the account by its address and asks for the new password and its
  confirmation (`ApiaryWeb.CoreComponents.new_password_fields/1`). Setting it uses the link
  up and ends every session of the account, as a change of password in Account settings
  does (`Apiary.Accounts.set_password_by_link/2`); the page then goes to the log-in page,
  where the person logs in with it. A link that does not work, used, ended by a newer one
  or expired, says so the same way whatever the reason, and an account the edition refuses
  (`Apiary.Accounts.sign_in_refusal/1`) is told what the log-in page tells it, and nothing
  is done.

  The page counts as a page a link opens before the token is looked up
  (`link_page_mount/1`). The token stays in the page's process: the request log writes the
  path without it (`ApiaryWeb.RequestLog`).
  """
  use ApiaryWeb, :live_view

  alias Apiary.Accounts
  alias ApiaryWeb.UserAuth

  @impl true
  def render(%{user: nil} = assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <.hex_tile icon="hero-clock" tone="neutral" />
      <Layouts.auth_heading>
        {gettext("That password link has expired")}
        <:subtitle>
          {gettext(
            "Password links work once and for a short time. Ask an admin of this Qory Apiary for a new one."
          )}
        </:subtitle>
      </Layouts.auth_heading>
      <.button variant="primary" size="md" class="btn-block" navigate={~p"/users/log-in"}>
        {gettext("Log in")}
      </.button>
    </Layouts.auth>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <Layouts.auth_heading>
        {gettext("Set your password")}
        <:subtitle><span id="password-email" class="break-all">{@user.email}</span></:subtitle>
      </Layouts.auth_heading>

      <.form
        for={@form}
        id="password_form"
        phx-change="validate"
        phx-submit="save"
        class="grid gap-4"
        novalidate
      >
        <.new_password_fields
          password={@form[:password]}
          confirmation={@form[:password_confirmation]}
          label={gettext("New password")}
          confirm_label={gettext("Confirm new password")}
          size="md"
        />
        <.button variant="primary" size="md" class="btn-block" loading_text={gettext("Setting")}>
          {gettext("Set password")}
        </.button>
      </.form>

      <p class="text-center text-[13px]/[18px] text-muted">
        {gettext("This link works once. Setting the password logs this account out everywhere.")}
      </p>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    # Counted before the token is looked up: past the limit the socket comes back
    # redirected, with the limit's one answer, and nothing of the link is looked up.
    case link_page_mount(socket) do
      {_counted, %{redirected: nil} = socket} ->
        {:ok, socket |> assign(:token, token) |> open(token)}

      {_limited, socket} ->
        {:ok, socket}
    end
  end

  # PIECE-4-SEAM. Piece 4 (fg49/mail-p4) adds `ApiaryWeb.AttemptLimits.link_page_mount/1`,
  # `{:ok, socket}` or `{:limited, socket}` redirected with its message, which is not on
  # this branch's base. At the merge this function goes, and `mount/3` calls
  # `ApiaryWeb.AttemptLimits.link_page_mount(socket)` in its place.
  defp link_page_mount(socket), do: {:ok, socket}

  defp open(socket, token) do
    user = Accounts.get_user_by_password_link(token)

    cond do
      is_nil(user) ->
        assign(socket,
          user: nil,
          form: nil,
          page_title: gettext("That password link has expired")
        )

      Accounts.sign_in_refusal(user) ->
        refused(socket)

      true ->
        assign(socket,
          user: user,
          form: form(user, %{}),
          page_title: gettext("Set your password")
        )
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, %{assigns: %{user: %{} = user}} = socket) do
    form =
      user
      |> Accounts.change_user_password(params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form(as: "user")

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"user" => params}, %{assigns: %{user: %{}}} = socket) do
    case Accounts.set_password_by_link(socket.assigns.token, params) do
      {:ok, {_user, tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Your password is set. Log in with it."))
         |> redirect(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "user"))}

      {:error, :invalid} ->
        {:noreply,
         assign(socket,
           user: nil,
           form: nil,
           page_title: gettext("That password link has expired")
         )}

      {:error, _refusal} ->
        {:noreply, refused(socket)}
    end
  end

  # An event of a page whose link no longer works: there is nothing to set.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp form(user, params),
    do: user |> Accounts.change_user_password(params, hash_password: false) |> to_form(as: "user")

  # What the log-in page tells an account the edition refuses, once it has shown the
  # account is theirs: here, with the link.
  defp refused(socket) do
    socket
    |> assign(user: nil, form: nil, page_title: gettext("Log in"))
    |> put_flash(
      :error,
      gettext("This account cannot log in at the moment. Ask the admins of this Qory Apiary.")
    )
    |> redirect(to: ~p"/users/log-in")
  end
end
