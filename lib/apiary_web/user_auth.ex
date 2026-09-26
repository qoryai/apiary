defmodule ApiaryWeb.UserAuth do
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Apiary.AccessKeys
  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_apiary_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # The workspace a signed-in user last opened, remembered for `/` and the log-in to send
  # them back to. No page reads it to decide what it shows: the path says that.
  @last_workspace :last_workspace_id

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    to = get_session(conn, :user_return_to) || signed_in_path(conn, user)

    conn
    |> create_or_extend_session(user, params)
    |> delete_session(:user_return_to)
    |> redirect(to: to)
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      ApiaryWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  #
  # The workspace last opened is kept, so that `/` still sends back to it after a log-out
  # and a log-in. It is an id and no credential, and `signed_in_path/1` follows it only
  # for a user who is a member of that workspace.
  defp renew_session(conn, _user) do
    delete_csrf_token()
    last_workspace = get_session(conn, @last_workspace)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(&if(last_workspace, do: put_session(&1, @last_workspace, last_workspace), else: &1))
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      ApiaryWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule ApiaryWeb.PageLive do
        use ApiaryWeb, :live_view

        on_mount {ApiaryWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{ApiaryWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:load_organisation, _params, session, socket) do
    socket = mount_current_scope(socket, session)
    scope = socket.assigns.current_scope

    if scope && scope.user do
      scope = Organisations.load_home_scope(scope, session[Atom.to_string(@last_workspace)])
      {:cont, assign_organisation(socket, scope)}
    else
      {:cont, Phoenix.Component.assign(socket, memberships: [], nav_counts: nil)}
    end
  end

  # The organisation and the workspace come from the path: `/:org/…` and
  # `/:org/:workspace/…`. A slug the user holds no membership in answers as a path that
  # does not exist; the pipeline's `fetch_path_scope/2` has already answered so for the
  # first render, and this answers for a live navigation.
  def on_mount(:load_path_scope, params, session, socket) do
    socket = mount_current_scope(socket, session)
    scope = %{socket.assigns.current_scope | organisation: nil, workspace: nil, membership: nil}

    case Organisations.resolve_scope(scope, params["org"], params["workspace"]) do
      {:ok, scope} -> {:cont, assign_organisation(socket, scope)}
      :error -> raise ApiaryWeb.NotFound
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("You must re-authenticate to access this page.")
        )
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  defp assign_organisation(socket, scope) do
    socket
    |> Phoenix.Component.assign(:current_scope, scope)
    |> Phoenix.Component.assign(:memberships, Organisations.list_memberships(scope.user))
    |> Phoenix.Component.assign(:nav_counts, nav_counts(scope))
    |> follow_membership_changes()
    |> follow_alive_runs()
    |> follow_policy_mode()
  end

  @doc """
  The counts the sidebar shows beside Runs (alive now), Access keys (active keys) and
  Members.
  """
  def nav_counts(%Scope{organisation: nil}), do: nil

  def nav_counts(%Scope{} = scope) do
    %{
      keys: scope |> AccessKeys.list_access_keys() |> Enum.count(&is_nil(&1.revoked_at)),
      members: scope |> Organisations.list_members() |> length(),
      alive: Apiary.Runs.count_alive(scope)
    }
    |> Map.merge(policy_mode(scope))
  end

  # The word beside Policy: the workspace's default mode, once the workspace has a policy
  # of Qory's, and the modes of the targets that set their own. One read. Where the
  # `security` feature is off there is no Policy entry to put it beside: nothing is read,
  # and the counts carry no mode at all.
  defp policy_mode(%Scope{workspace: nil}), do: %{mode: nil, own_modes: []}

  defp policy_mode(%Scope{} = scope) do
    if Apiary.Access.can?(scope, :"security_policy.read", scope.workspace) do
      case Apiary.Policy.mode_summary(scope) do
        %{managed?: true, mode: mode, own_modes: own_modes} ->
          %{mode: mode, own_modes: own_modes}

        _unmanaged ->
          %{mode: nil, own_modes: []}
      end
    else
      %{}
    end
  end

  # The sidebar's mode word follows `policy:<workspace>` on every page: the hook
  # subscribes the page's process here, before the page mounts, and re-reads the word (one
  # read) at once on the first change and then at most once a second while changes keep
  # coming, as the count of alive runs does.
  #
  # Whether the message goes on to the page is decided when it arrives, not by who
  # subscribed first: a page that follows the policy subscribes too, wherever it likes,
  # and then the process holds the topic more than once. The hook sees that, leaves one
  # subscription in place, and from then on passes every message on. A page that never
  # subscribed never sees a message it did not ask for.
  #
  # Without the `security` feature there is no word to follow and the hook subscribes to
  # nothing: no page of such an instance hears of the policy.
  @policy_window 1_000

  defp follow_policy_mode(socket) do
    scope = socket.assigns.current_scope

    if scope.workspace && Apiary.Access.can?(scope, :"security_policy.read", scope.workspace) &&
         Phoenix.LiveView.connected?(socket) do
      Apiary.Policy.subscribe(scope)
      topic = Apiary.Policy.topic(scope.workspace.id)

      socket
      |> Phoenix.LiveView.put_private(:policy_window, :closed)
      |> Phoenix.LiveView.put_private(:policy_passes, false)
      |> Phoenix.LiveView.attach_hook(:policy_mode, :handle_info, fn
        {:policy_changed, _change}, socket ->
          socket = socket |> policy_page_subscribed(topic) |> policy_window_changed()
          if socket.private[:policy_passes], do: {:cont, socket}, else: {:halt, socket}

        :policy_window_over, socket ->
          case socket.private[:policy_window] do
            :dirty ->
              Process.send_after(self(), :policy_window_over, @policy_window)

              {:halt,
               socket
               |> refresh_policy_mode()
               |> Phoenix.LiveView.put_private(:policy_window, :open)}

            _open ->
              {:halt, Phoenix.LiveView.put_private(socket, :policy_window, :closed)}
          end

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  # The page subscribed as well: keep one subscription, so a change arrives once, and
  # pass messages on from now.
  defp policy_page_subscribed(socket, topic) do
    if Enum.count(Registry.keys(Apiary.PubSub, self()), &(&1 == topic)) > 1 do
      Phoenix.PubSub.unsubscribe(Apiary.PubSub, topic)
      Phoenix.PubSub.subscribe(Apiary.PubSub, topic)
      Phoenix.LiveView.put_private(socket, :policy_passes, true)
    else
      socket
    end
  end

  # `config :apiary, ApiaryWeb.PolicyLive, nav_window: 0` in a test reads at every change.
  defp policy_window do
    :apiary
    |> Application.get_env(ApiaryWeb.PolicyLive, [])
    |> Keyword.get(:nav_window, @policy_window)
  end

  defp policy_window_changed(socket) do
    case {policy_window(), socket.private[:policy_window]} do
      {0, _window} ->
        refresh_policy_mode(socket)

      {window, :closed} ->
        Process.send_after(self(), :policy_window_over, window)
        socket |> refresh_policy_mode() |> Phoenix.LiveView.put_private(:policy_window, :open)

      {_window, _open_or_dirty} ->
        Phoenix.LiveView.put_private(socket, :policy_window, :dirty)
    end
  end

  defp refresh_policy_mode(socket) do
    counts =
      Map.merge(socket.assigns.nav_counts || %{}, policy_mode(socket.assigns.current_scope))

    Phoenix.Component.assign(socket, :nav_counts, counts)
  end

  # The sidebar's count of alive runs follows the workspace on every page. It listens on a
  # topic of its own (`Apiary.Runs.touched_topic/1`), so no page has to handle a message
  # it did not ask for. The count is one indexed query, made at once on the first change
  # and then at most once a second while changes keep coming.
  @alive_window 1_000

  defp follow_alive_runs(socket) do
    scope = socket.assigns.current_scope

    if scope.workspace && Phoenix.LiveView.connected?(socket) do
      Apiary.Runs.subscribe_touched(scope)
    end

    socket
    |> Phoenix.LiveView.put_private(:alive_window, :closed)
    |> Phoenix.LiveView.attach_hook(:alive_runs, :handle_info, fn
      {:runs_touched, _workspace_id}, socket ->
        case socket.private[:alive_window] do
          :closed ->
            Process.send_after(self(), :alive_window_over, @alive_window)

            {:halt,
             socket |> refresh_alive() |> Phoenix.LiveView.put_private(:alive_window, :open)}

          _open_or_dirty ->
            {:halt, Phoenix.LiveView.put_private(socket, :alive_window, :dirty)}
        end

      :alive_window_over, socket ->
        case socket.private[:alive_window] do
          :dirty ->
            Process.send_after(self(), :alive_window_over, @alive_window)

            {:halt,
             socket |> refresh_alive() |> Phoenix.LiveView.put_private(:alive_window, :open)}

          _open ->
            {:halt, Phoenix.LiveView.put_private(socket, :alive_window, :closed)}
        end

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp refresh_alive(socket) do
    scope = socket.assigns.current_scope

    if scope && scope.workspace do
      counts = Map.put(socket.assigns.nav_counts || %{}, :alive, Apiary.Runs.count_alive(scope))
      Phoenix.Component.assign(socket, :nav_counts, counts)
    else
      socket
    end
  end

  # An open page follows a change of the user's own membership: a new level is
  # loaded into the scope, a membership that is gone sends the page to `/` (and from
  # there to wherever the user still belongs). The contexts authorize on the
  # database whatever the page holds; this keeps what the page shows honest.
  defp follow_membership_changes(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(
        Apiary.PubSub,
        Organisations.membership_topic(socket.assigns.current_scope.user.id)
      )
    end

    Phoenix.LiveView.attach_hook(socket, :membership_changed, :handle_info, fn
      {:membership_changed, _change}, socket -> {:halt, reload_scope(socket)}
      _message, socket -> {:cont, socket}
    end)
  end

  @doc """
  Loads the scope a page's path names again from the database, with the memberships and
  the counts of the sidebar, when the page's may be stale: a membership that changed
  elsewhere, or an action `Apiary.Access` refused on the membership as it is now. A page
  that asks `Apiary.Access.can?/3` as it renders follows. A membership that is gone sends
  the page to `/`.
  """
  @spec reload_scope(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload_scope(socket) do
    scope = socket.assigns.current_scope

    reloaded =
      scope.organisation &&
        Organisations.resolve_scope(
          %{scope | organisation: nil, workspace: nil, membership: nil},
          scope.organisation.slug,
          scope.workspace && scope.workspace.slug
        )

    with {:ok, reloaded} <- reloaded || :error do
      socket
      |> Phoenix.Component.assign(:current_scope, reloaded)
      |> Phoenix.Component.assign(:memberships, Organisations.list_memberships(scope.user))
      |> Phoenix.Component.assign(:nav_counts, nav_counts(reloaded))
    else
      :error -> Phoenix.LiveView.redirect(socket, to: ~p"/")
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc """
  signed_in_path/1 is where a signed-in user is sent, from `/` and after log-in: the
  workspace the session remembers as last opened while the user is still a member of it,
  else the user's earliest, and without a membership `/users/organisations`. A LiveView
  cannot read the session, and is given `/`, which sends on the same way.
  """
  def signed_in_path(%Plug.Conn{} = conn) do
    signed_in_path(conn, conn.assigns[:current_scope] && conn.assigns.current_scope.user)
  end

  def signed_in_path(_socket), do: ~p"/"

  defp signed_in_path(conn, %Apiary.Accounts.User{} = user) do
    case Organisations.home_membership(user, get_session(conn, @last_workspace)) do
      %{organisation: organisation, workspace: workspace} -> ~p"/#{organisation}/#{workspace}"
      nil -> ~p"/users/organisations"
    end
  end

  defp signed_in_path(_conn, nil), do: ~p"/"

  @doc """
  Plug for the pages under `/:org/…` and `/:org/:workspace/…`: loads the organisation
  and the workspace their path names into the scope
  (`Apiary.Organisations.resolve_scope/3`) and remembers the workspace for
  `signed_in_path/1`. A slug the user holds no
  membership in is answered as a path that does not exist, as the router answers one.
  Runs after `require_authenticated_user/2`.
  """
  def fetch_path_scope(conn, _opts) do
    scope = conn.assigns.current_scope
    %{"org" => organisation_slug} = params = conn.path_params

    case Organisations.resolve_scope(scope, organisation_slug, params["workspace"]) do
      {:ok, scope} ->
        conn
        |> assign(:current_scope, scope)
        |> remember_workspace(scope.workspace.id)

      :error ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(404, ApiaryWeb.ErrorHTML.render("404.html", %{}))
        |> halt()
    end
  end

  # Written only when it changes, so that a page and the log reads of its terminal do not
  # each send the session cookie again.
  defp remember_workspace(conn, workspace_id) do
    if get_session(conn, @last_workspace) == workspace_id,
      do: conn,
      else: put_session(conn, @last_workspace, workspace_id)
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must log in to access this page."))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
