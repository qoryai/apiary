defmodule ApiaryWeb.UserAuth do
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Apiary.AccessKeys
  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.LogMetadata
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

  # The workspace a signed-in user last opened, remembered for `/`, the log-in and `/:org`
  # to send them back to, while they reach it. No workspace's page reads it to decide what
  # it shows: the path says that; an organisation's page shows it beside it.
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
      scope = user |> Scope.for_user() |> Scope.put_origin(ApiaryWeb.Origin.from_conn(conn))
      # The person's id in the request's log lines, on every page.
      LogMetadata.put_user(scope)

      conn
      |> assign(:current_scope, scope)
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
  # for a user who reaches that workspace.
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
      # A person's own pages are no organisation's: their lines carry no ids, though the
      # sidebar shows the workspace last opened.
      scope = Organisations.load_home_scope(scope, session[Atom.to_string(@last_workspace)])
      {:cont, assign_organisation(socket, scope)}
    else
      {:cont, Phoenix.Component.assign(socket, memberships: [], nav_counts: nil)}
    end
  end

  # The organisation and the workspace come from the path: `/:org/…` and
  # `/:org/:workspace/…`. A slug the user holds no membership in, or names a workspace
  # they do not reach, answers as a path that does not exist; the pipeline's
  # `fetch_path_scope/2` has already answered so for the first render, and this answers
  # for a live navigation. An organisation's page carries the workspace the session
  # remembers, while the user reaches it, or the first they reach. Their ids go into the
  # Logger metadata of the LiveView's process (`Apiary.LogMetadata`). An organisation
  # where the user's membership is suspended sends them to their organisations, and says
  # why, rather than that it does not exist.
  def on_mount(:load_path_scope, params, session, socket) do
    socket = mount_current_scope(socket, session)
    scope = without_place(socket.assigns.current_scope)

    case Organisations.resolve_scope(scope, params["org"], params["workspace"],
           last_workspace: session[Atom.to_string(@last_workspace)]
         ) do
      {:ok, scope} ->
        LogMetadata.put(scope)

        {:cont,
         socket
         |> Phoenix.LiveView.put_private(:path_workspace?, is_binary(params["workspace"]))
         |> assign_organisation(scope)}

      :error ->
        case suspended_membership(scope, params["org"]) do
          nil ->
            raise ApiaryWeb.NotFound

          membership ->
            {:halt,
             socket
             |> Phoenix.LiveView.put_flash(:error, membership_suspended(membership))
             |> Phoenix.LiveView.redirect(to: ~p"/users/organisations")}
        end
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
    |> Phoenix.Component.assign(:memberships, Organisations.list_places(scope.user))
    |> Phoenix.Component.assign(:nav_counts, nav_counts(scope))
    |> follow_membership_changes()
    |> follow_alive_runs()
    |> follow_policy_mode()
  end

  @doc """
  The counts the sidebar shows beside Runs (alive now), Access keys (active keys) and
  Members, with the policy's mode beside Policy, and the edition's beside its entries
  (`c:ApiaryWeb.Edition.nav_counts/1`).
  """
  def nav_counts(%Scope{organisation: nil}), do: nil

  def nav_counts(%Scope{workspace: nil} = scope),
    do:
      Map.merge(
        %{members: scope |> Organisations.list_members() |> length()},
        ApiaryWeb.Edition.nav_counts(scope)
      )

  def nav_counts(%Scope{} = scope) do
    %{
      keys: scope |> AccessKeys.list_access_keys() |> Enum.count(&is_nil(&1.revoked_at)),
      members: scope |> Organisations.list_members() |> length(),
      alive: Apiary.Runs.count_alive(scope)
    }
    |> Map.merge(policy_mode(scope))
    |> Map.merge(ApiaryWeb.Edition.nav_counts(scope))
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

  # An open page follows a change of the user's own membership and of the workspaces they
  # reach: a new level is loaded into the scope, a membership that is gone, or a workspace
  # they no longer reach, sends the page to `/` (and from there to wherever the user
  # still belongs). The contexts authorize on the
  # database whatever the page holds; this keeps what the page shows honest.
  defp follow_membership_changes(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(
        Apiary.PubSub,
        Organisations.membership_topic(socket.assigns.current_scope.user.id)
      )
    end

    Phoenix.LiveView.attach_hook(socket, :membership_changed, :handle_info, fn
      {:membership_changed, _change}, socket ->
        socket = reload_scope(socket)
        reload = socket.private[:on_membership_change]

        {:halt, if(reload && !socket.redirected, do: reload.(socket), else: socket)}

      _message, socket ->
        {:cont, socket}
    end)
  end

  @doc """
  on_membership_change/2 makes an open page read its own data again, with `reload`, a
  function of the socket, once the scope has been loaded again after a change of its
  person's memberships (`reload_scope/1`), and the page is still theirs: for a page whose
  content such a change alters, as the organisation's settings list its owners.
  """
  @spec on_membership_change(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def on_membership_change(socket, reload) when is_function(reload, 1),
    do: Phoenix.LiveView.put_private(socket, :on_membership_change, reload)

  @doc """
  Loads the scope a page's path names again from the database, with the memberships and
  the counts of the sidebar, when the page's may be stale: a membership, or what the
  edition says of it, that changed elsewhere, or an action `Apiary.Access` refused on the membership
  as it is now. A page that asks `Apiary.Access.can?/3` as it renders follows. A
  membership that is gone, or a workspace of the path the user no longer reaches, sends
  the page to `/`; a membership suspended sends it to `/users/organisations`, which says
  so; a page of a feature taken away from the organisation or the workspace meanwhile
  (`Apiary.Features.of/2`) sends it to the organisation's overview, which every
  organisation has, and says so; an organisation's page keeps its workspace while the user
  reaches it.
  """
  @spec reload_scope(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reload_scope(socket) do
    scope = socket.assigns.current_scope
    path_workspace? = Map.get(socket.private, :path_workspace?, not is_nil(scope.workspace))

    reloaded =
      scope.organisation &&
        Organisations.resolve_scope(
          without_place(scope),
          scope.organisation.slug,
          if(path_workspace?, do: scope.workspace && scope.workspace.slug),
          last_workspace: scope.workspace && scope.workspace.id
        )

    with {:ok, reloaded} <- reloaded || :error,
         :ok <- page_feature_on(socket, reloaded) do
      socket
      |> Phoenix.Component.assign(:current_scope, reloaded)
      |> Phoenix.Component.assign(:memberships, Organisations.list_places(scope.user))
      |> Phoenix.Component.assign(:nav_counts, nav_counts(reloaded))
    else
      {:feature_off, reloaded} ->
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("What that page showed is no longer part of %{organisation}.",
            organisation: reloaded.organisation.name
          )
        )
        |> Phoenix.LiveView.redirect(to: ~p"/#{reloaded.organisation}")

      :error ->
        case suspended_membership(scope, scope.organisation && scope.organisation.slug) do
          nil ->
            Phoenix.LiveView.redirect(socket, to: ~p"/")

          membership ->
            socket
            |> Phoenix.LiveView.put_flash(:error, membership_suspended(membership))
            |> Phoenix.LiveView.redirect(to: ~p"/users/organisations")
        end
    end
  end

  # Whether the feature of the page's LiveView (`ApiaryWeb.Features`), if it has one, is
  # still on where the scope is now: a feature taken away while the page was open.
  defp page_feature_on(socket, reloaded) do
    view = socket.view

    if function_exported?(view, :__feature__, 0) and
         not Apiary.Features.on?(reloaded, view.__feature__()),
       do: {:feature_off, reloaded},
       else: :ok
  end

  # The signed-in user's suspended membership in the organisation `slug`, or nil: an
  # organisation they cannot open because of it, which the page they are sent to says.
  defp suspended_membership(%Scope{user: %Accounts.User{} = user}, slug) when is_binary(slug),
    do: Organisations.suspended_membership(user, slug)

  defp suspended_membership(_scope, _slug), do: nil

  defp membership_suspended(membership) do
    case {membership.level, membership.organisation} do
      {:admin, _organisation} ->
        gettext("Your membership in %{name} is suspended. An owner of it can activate it.",
          name: membership.organisation.name
        )

      _member ->
        gettext(
          "Your membership in %{name} is suspended. An owner or an admin of it can activate it.",
          name: membership.organisation.name
        )
    end
  end

  defp without_place(scope),
    do: %{
      scope
      | organisation: nil,
        workspace: nil,
        membership: nil,
        reach: nil,
        edition: %{}
    }

  # Every hook mounts the scope through here, so a LiveView's log lines carry the person's
  # id from its mount on; the organisation and the workspace are added by
  # `:load_path_scope` only. The scope carries where the LiveView's connection came from,
  # which the audit trail records of every change made through it.
  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        {user, _} =
          if user_token = session["user_token"] do
            Accounts.get_user_by_session_token(user_token)
          end || {nil, nil}

        user |> Scope.for_user() |> Scope.put_origin(ApiaryWeb.Origin.from_socket(socket))
      end)

    LogMetadata.put_user(socket.assigns.current_scope)
    socket
  end

  @doc """
  signed_in_path/1 is where a signed-in user is sent, from `/` and after log-in: the
  workspace the session remembers as last opened while the user still reaches it, else
  the first workspace they reach in their earliest organisation
  (`Apiary.Organisations.load_home_scope/2`); the organisation's own path, `/:org`, for a
  member who reaches no workspace yet, which says so; and without a membership
  `/users/organisations`. A LiveView cannot read the session, and is given `/`, which
  sends on the same way.
  """
  def signed_in_path(%Plug.Conn{} = conn) do
    signed_in_path(conn, conn.assigns[:current_scope] && conn.assigns.current_scope.user)
  end

  def signed_in_path(_socket), do: ~p"/"

  defp signed_in_path(conn, %Apiary.Accounts.User{} = user) do
    case Organisations.load_home_scope(Scope.for_user(user), get_session(conn, @last_workspace)) do
      %Scope{organisation: %{} = organisation, workspace: %{} = workspace} ->
        ~p"/#{organisation}/#{workspace}"

      %Scope{organisation: %{} = organisation} ->
        ~p"/#{organisation}"

      _no_membership ->
        ~p"/users/organisations"
    end
  end

  defp signed_in_path(_conn, nil), do: ~p"/"

  @doc """
  Plug for the pages under `/:org/…` and `/:org/:workspace/…`: loads the organisation
  and the workspace their path names into the scope
  (`Apiary.Organisations.resolve_scope/4`), an organisation's page the workspace the
  session remembers while the user reaches it, puts their ids into the request's Logger
  metadata (`Apiary.LogMetadata`) and remembers the workspace for `signed_in_path/1`. A
  slug the user holds no membership in, or a workspace they do not reach, is answered as
  a path that does not exist, as the router answers one, but an organisation where their
  membership is suspended: that sends them to `/users/organisations`, which says why.
  Runs after `require_authenticated_user/2`.
  """
  def fetch_path_scope(conn, _opts) do
    scope = conn.assigns.current_scope
    %{"org" => organisation_slug} = params = conn.path_params

    case Organisations.resolve_scope(scope, organisation_slug, params["workspace"],
           last_workspace: get_session(conn, @last_workspace)
         ) do
      {:ok, scope} ->
        LogMetadata.put(scope)

        conn
        |> assign(:current_scope, scope)
        |> remember_workspace(scope.workspace)

      :error ->
        case suspended_membership(scope, organisation_slug) do
          nil ->
            conn
            |> put_resp_content_type("text/html")
            |> send_resp(404, ApiaryWeb.ErrorHTML.render("404.html", %{}))
            |> halt()

          membership ->
            conn
            |> put_flash(:error, membership_suspended(membership))
            |> redirect(to: ~p"/users/organisations")
            |> halt()
        end
    end
  end

  # Written only when it changes, so that a page and the log reads of its terminal do not
  # each send the session cookie again.
  defp remember_workspace(conn, nil), do: conn

  defp remember_workspace(conn, %{id: workspace_id}) do
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

  @doc """
  Answers `401`, as JSON, a request that needs a signed-in person and has none: for what a
  page asks of the server without leaving it, such as the palette's answers, which a
  redirect to log in would not help.
  """
  def require_authenticated_json(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_status(401)
      |> Phoenix.Controller.json(%{error: "unauthenticated"})
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
