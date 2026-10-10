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
  defp log_in(conn, %{"user" => %{"token" => _}} = params, info), do: create(conn, params, info)

  defp log_in(conn, %{"user" => %{"email" => email, "password" => _}} = params, info)
       when is_binary(email) do
    case AttemptLimits.password_log_in(email, ApiaryWeb.Origin.from_conn(conn).remote_ip) do
      :ok ->
        create(conn, params, info)

      :limited ->
        conn
        |> put_flash(:error, AttemptLimits.message())
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp log_in(conn, params, info), do: create(conn, params, info)

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      # An account the edition refuses (`Apiary.Accounts.sign_in_refusal/1`).
      {:error, reason} when is_atom(reason) and reason != :not_found ->
        refuse_account(conn)

      _ ->
        conn
        |> put_flash(:error, gettext("That link has expired. Ask for a new one below."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

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
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, gettext("Your password is updated."))
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
