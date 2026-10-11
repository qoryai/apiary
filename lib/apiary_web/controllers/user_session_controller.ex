defmodule ApiaryWeb.UserSessionController do
  use ApiaryWeb, :controller

  alias Apiary.Accounts
  alias ApiaryWeb.{AttemptLimits, UserAuth}

  def create(conn, %{"_action" => "confirmed"} = params) do
    log_in(conn, params, gettext("Your account is confirmed."))
  end

  def create(conn, params) do
    log_in(conn, params, gettext("You are logged in."))
  end

  # A log-in with a password counts against its limits (`ApiaryWeb.AttemptLimits`)
  # before the address is looked up: past them, an address with an account and one
  # without get the same answer, without a password checked. A link's log-in does not.
  # Every other post counts, whatever its shape, since each costs a password check: one
  # without an address as text spends its client's bucket alone.
  defp log_in(conn, %{"user" => %{"token" => _}} = params, info), do: create(conn, params, info)

  defp log_in(conn, params, info) do
    email =
      case params do
        %{"user" => %{"email" => email}} when is_binary(email) -> email
        _other -> nil
      end

    case AttemptLimits.password_log_in(email, ApiaryWeb.Origin.from_conn(conn).remote_ip) do
      :ok ->
        create(conn, params, info)

      :limited ->
        conn
        |> put_flash(:error, AttemptLimits.message())
        |> put_flash(:email, String.slice(email || "", 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      # The first link of an account whose password was set before its address was
      # confirmed: the password is gone, and so is every other session.
      {:ok, {user, tokens_to_disconnect}, :password_removed} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(
          :info,
          gettext(
            "Your address is confirmed. The password set before it was confirmed is removed: set a new one in Account settings if you want one."
          )
        )
        |> UserAuth.log_in_user(user, user_params)

      # An account the edition refuses (`Apiary.Accounts.sign_in_refusal/1`).
      {:error, reason} when is_atom(reason) and reason != :not_found ->
        refuse_account(conn)

      _ ->
        conn
        # Without mail the log-in page asks for no link: it takes a password.
        |> put_flash(
          :error,
          if(Apiary.Mail.configured?(),
            do: gettext("That link has expired. Ask for a new one below."),
            else: gettext("That link has expired.")
          )
        )
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login. A field missing, or not text, is an empty one: the same
  # answer as a wrong password, after the same work.
  defp create(conn, %{"user" => %{} = user_params}, info) do
    email = text(user_params["email"])
    password = text(user_params["password"])

    user = Accounts.get_user_by_email_and_password(email, password)

    cond do
      Accounts.sign_in_refusal(user) ->
        refuse_account(conn)

      user ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      true ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, gettext("That email and password do not match."))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp create(conn, _params, info), do: create(conn, %{"user" => %{}}, info)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  # An account the edition refuses (`Apiary.Accounts.sign_in_refusal/1`), told only once
  # it has shown it is theirs: with its password, or a link sent to its address. The
  # sentence names no reason and no one.
  defp refuse_account(conn) do
    conn
    |> put_flash(
      :error,
      gettext("This account cannot log in at the moment. Ask the admins of this Qory Apiary.")
    )
    |> redirect(to: ~p"/users/log-in")
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.update_user_password(user, user_params,
           session_token: get_session(conn, :user_token)
         ) do
      {:ok, {_user, expired_tokens}} ->
        # disconnect all existing LiveViews with old sessions
        UserAuth.disconnect_sessions(expired_tokens)

        # The log-in that follows is the signed-in person's own, whatever email the form
        # posted: it is not counted against the limits, so it must not name anyone else.
        params = put_in(params, ["user", "email"], user.email)

        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> create(params, gettext("Your password is updated."))

      # The session ended, or the account was confirmed, since this request loaded it: a
      # log-in link to its address removed the password and every session. Nothing is
      # set, and the person logs in again, as after any session that ended.
      {:error, :stale} ->
        conn
        |> put_flash(:error, gettext("You must log in to access this page."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("You are logged out."))
    |> UserAuth.log_out_user()
  end

  @doc """
  Where a person is sent once their account is deleted
  (`ApiaryWeb.UserLive.Settings`): their session is ended here, every page of it
  disconnected on its `live_socket_id`, and the cookie cleared, as a log-out does. The
  session's token is gone with the account, so the request is signed out already; one
  that is signed in, a link followed by someone else, is sent to `/` and nothing ends.
  """
  def account_deleted(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/")
    else
      conn
      |> put_flash(:info, gettext("Your account is deleted."))
      |> UserAuth.log_out_user()
    end
  end
end
