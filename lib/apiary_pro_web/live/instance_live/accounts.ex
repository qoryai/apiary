defmodule ApiaryProWeb.InstanceLive.Accounts do
  @moduledoc """
  Instance settings › Accounts, the Instance level's third section, for the instance
  organisation's owners, the instance admins (`instance.read`); for anyone else the page
  is not found. Its paths are `ApiaryProWeb.InstanceLive.Paths`'.

  Every account on the instance, with how many memberships it holds and whether it is
  suspended, in two views (All, Suspended) with a search by email, both in the URL. From
  the row's menu: **Suspend**, confirmed on the row, ends the account's sessions and
  disconnects its open pages; **Activate**, at once, lets it log in again
  (`ApiaryPro.Suspensions.suspend_account/2`, `activate_account/2`). Neither is offered
  for the reader's account. Before a suspension the confirmation names the
  organisations it would leave without an owner who can act.

  **Password links.** While no mail is set (`Apiary.Mail.configured?/0`), the menu of each
  other account that is not suspended has Make a password link
  (`Apiary.Accounts.build_password_link/3`), as the core's People page has for the members
  of the instance organisation (`ApiaryWeb.MemberLive.Index`): here for any account, a
  client's owner or a member of any organisation, who would otherwise need a shell on the
  instance's machine. The page calls `Apiary.Access.can?/3` with `account.password_link`
  for each account. It is the core's link, and only the core's checks apply to it:
  an instance admin's, while no mail is set, never for their account nor for one that
  cannot log in, and only after a recent sign-in, as Account settings ask: an admin whose
  sign-in is older is sent to log in again first. It works once, for 24 hours, or until
  mail is set (`Apiary.Mail.end_password_links/0`), a new one ends the one before, and the
  instance organisation's trail records it (`account.password_link`). The page shows it
  once, above the list, to copy and send to the person, until Done or until the reader
  leaves (`CoreComponents.one_time_link/1`, `kind: :password`); it keeps the link in
  its process alone, in a function, as the People page does, so no inspection of the
  process's state prints it, and never in a path, a flash or a title.
  """
  use ApiaryProWeb, :live_view
  on_mount {ApiaryProWeb.InstanceLive.Components, :instance}

  alias Apiary.{Access, Accounts}
  alias ApiaryPro.Suspensions
  alias ApiaryProWeb.InstanceLive.Paths
  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:accounts}
    >
      <.settings_page section={:accounts} measure="list" title={gettext("Accounts")}>
        <:subtitle>
          {gettext("Every account on this Qory Apiary, with how many memberships it holds.")}
          {gettext("A suspended account cannot log in, and acts in no organisation.")}
        </:subtitle>

        <.async_result :let={accounts} assign={@accounts}>
          <:loading>
            <div
              id="accounts-loading"
              class="overflow-hidden rounded-box border border-line bg-base-100 shadow-xs"
              aria-busy="true"
            >
              <span class="sr-only">{gettext("Loading the accounts")}</span>
              <div
                :for={n <- 1..4}
                class="flex h-11 items-center gap-6 border-b border-line px-4 last:border-b-0"
              >
                <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-48", else: "w-36")]}></span>
                <span class="skeleton q-skel w-20"></span>
              </div>
            </div>
          </:loading>
          <:failed>
            <.notice kind={:error} class="max-w-[80ch]">
              <span id="accounts-error">
                {gettext(
                  "The accounts could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
                )}
              </span>
            </.notice>
          </:failed>

          <div class="grid min-w-0 gap-3">
            <%!-- The password link made, once, above the list, until Done. --%>
            <.one_time_link
              :if={@password_link}
              id="password-link"
              url={@password_link.url.()}
              expires_at={@password_link.expires_at}
              for={@password_link.email}
              kind={:password}
            >
              <:actions>
                <.button id="password-link-done" size="sm" phx-click="password_link_done">
                  {gettext("Done")}
                </.button>
              </:actions>
            </.one_time_link>

            <.views id="accounts-views" label={gettext("Views of the accounts")}>
              <:view
                :for={{view, label} <- views()}
                id={"accounts-view-#{view}"}
                patch={list_path(@list, view: view)}
                count={Format.number(Enum.count(accounts, &in_view?(&1, view)))}
                current={@list.view == view}
              >
                {label}
              </:view>
            </.views>

            <div class="q-bar">
              <.list_search
                id="accounts-search"
                label={gettext("Find an account")}
                placeholder={gettext("Find by email")}
                value={@list.q}
              />
            </div>

            <%!-- Always there, so a screen reader hears what the search left. --%>
            <div id="accounts-status" role="status" class="q-status">
              <p :if={@list.q} class="text-[13px] text-muted">
                {ngettext(
                  "%{number} account matches",
                  "%{number} accounts match",
                  length(shown(accounts, @list)),
                  number: Format.number(length(shown(accounts, @list)))
                )}
              </p>
            </div>

            <div :if={shown(accounts, @list) == []} id="accounts-none">
              <.empty_state icon={nil} tone="neutral" title={empty_title(@list)}>
                <:actions :if={@list.q}>
                  <.button id="accounts-clear" patch={list_path(@list, q: nil)}>
                    {gettext("Clear the search")}
                  </.button>
                </:actions>
              </.empty_state>
            </div>

            <.table
              :if={shown(accounts, @list) != []}
              id="accounts"
              label={gettext("Accounts")}
              rows={shown(accounts, @list)}
              row_id={&"account-#{&1.user.id}"}
              row_class={&(&1.suspended_at && "row-off")}
              confirming={@live_action == :suspend && confirming(@accounts, @account_id, @scope)}
            >
              <:col :let={a} label={gettext("Account")} kind="title">
                <span class="q-nm q-fold-nm">
                  <.avatar
                    name={a.user.email}
                    kind={if a.user.id == @scope.user.id, do: "self", else: "person"}
                  />
                  <span class="q-title" title={a.user.email}>{a.user.email}</span>
                  <span :if={a.user.id == @scope.user.id} class="q-side">{gettext("you")}</span>
                  <%!-- Below 600 px of table, a line under the email: its memberships, whose
                       column the table drops there, and its state. --%>
                  <span class="q-fold-line text-[12.5px] font-normal">
                    <span class="q-fold tabular-nums">{memberships(a)}</span>
                    <span id={"account-#{a.user.id}-status"} class="q-fold-states">
                      <.state_word :if={a.suspended_at}>{gettext("Suspended")}</.state_word>
                      <span :if={!a.suspended_at} class="sr-only">{gettext("Active")}</span>
                    </span>
                  </span>
                </span>
              </:col>
              <:col :let={a} label={gettext("Memberships")} from="sm">
                <span id={"account-#{a.user.id}-memberships"} class="tabular-nums">
                  {memberships(a)}
                </span>
              </:col>
              <:confirm :let={a}>
                <.inline_confirm
                  id="suspend-account"
                  question={gettext("Suspend %{email}?", email: a.user.email)}
                  cancel={list_path(@list, [])}
                >
                  {gettext(
                    "%{email} is logged out everywhere at once, and can no longer log in or act in any organisation. Nothing is removed: their memberships stay, and the access keys they added keep working. You can activate the account again at any time.",
                    email: a.user.email
                  )}
                  <span :if={@sole_owned != []} id="suspend-account-sole-owner" class="q-hot">
                    {gettext(
                      "With %{email} suspended, %{organisations} run without an owner who can act: their admins and members work, and what only an owner does waits until you activate the account again or transfer the ownership to one of their admins.",
                      email: a.user.email,
                      organisations: Enum.map_join(@sole_owned, ", ", & &1.name)
                    )}
                  </span>
                  <:action>
                    <.button
                      id="suspend-account-confirm"
                      variant="danger"
                      size="xs"
                      phx-click="suspend_account"
                      loading_text={gettext("Suspending")}
                    >
                      {gettext("Yes, suspend")}
                    </.button>
                  </:action>
                </.inline_confirm>
              </:confirm>
              <:action :let={a}>
                <.row_menu
                  id={"account-#{a.user.id}-menu"}
                  label={gettext("Actions for %{email}", email: a.user.email)}
                >
                  <.menu_item
                    :if={
                      @password_links? and is_nil(a.suspended_at) and
                        Access.can?(@scope, :"account.password_link", a.user)
                    }
                    id={"account-#{a.user.id}-password-link"}
                    phx-click="password_link"
                    phx-value-id={a.user.id}
                    aria-label={gettext("Make a password link for %{email}", email: a.user.email)}
                  >
                    {gettext("Make a password link")}
                  </.menu_item>
                  <.menu_item
                    :if={
                      is_nil(a.suspended_at) and
                        Access.can?(@scope, :"instance.suspend_account", a.user)
                    }
                    id={"account-#{a.user.id}-suspend-button"}
                    patch={Paths.account(a.user.id, :suspend)}
                    aria-label={gettext("Suspend %{email}", email: a.user.email)}
                  >
                    {gettext("Suspend…")}
                  </.menu_item>
                  <.menu_item
                    :if={
                      a.suspended_at &&
                        Access.can?(@scope, :"instance.activate_account", a.user)
                    }
                    id={"account-#{a.user.id}-activate-button"}
                    phx-click="activate_account"
                    phx-value-id={a.user.id}
                    aria-label={gettext("Activate %{email}", email: a.user.email)}
                  >
                    {gettext("Activate")}
                  </.menu_item>
                </.row_menu>
              </:action>
            </.table>
          </div>
        </.async_result>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp memberships(account),
    do:
      ngettext("%{number} membership", "%{number} memberships", account.memberships,
        number: Format.number(account.memberships)
      )

  # The account whose row asks to confirm its suspension.
  defp confirming(accounts, id, scope) do
    case target(accounts, id, scope) do
      [account] -> "account-#{account.user.id}"
      _none -> nil
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title:
         SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
           gettext("Accounts")
         ]),
       account_id: nil,
       sole_owned: [],
       list: list_params(%{}),
       password_link: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Every path starts without a password link shown: it is shown once, until the reader
    # leaves.
    socket = assign(socket, :password_link, nil)

    socket =
      if socket.assigns.live_action == :index,
        do: assign(socket, :list, list_params(params)),
        else: socket

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, account_id: nil, sole_owned: [])

  # The organisations its suspension leaves without an owner who may act, an owned
  # operator's clients among them: the confirmation says so first.
  defp apply_action(socket, :suspend, %{"id" => id}) do
    assign(socket, account_id: id, sole_owned: Suspensions.left_without_owner(id))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns.list, q: q), replace: true)}
  end

  def handle_event("suspend_account", _params, %{assigns: %{account_id: id}} = socket)
      when is_binary(id) do
    case Suspensions.suspend_account(socket.assigns.scope, id) do
      {:ok, %{user: user, tokens: tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} is suspended.", email: user.email))
         |> load()
         |> back()}

      {:error, :last_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The instance's last owner who can act cannot be suspended.")
         )
         |> load()
         |> back()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("activate_account", %{"id" => id}, socket) do
    case Suspensions.activate_account(socket.assigns.scope, id) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} is active again.", email: user.email))
         |> load()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  # A password link for an account, shown once above the list: the core's context asks who
  # may, and for which account (`Accounts.build_password_link/3`); the page adds no check
  # beyond what it offers.
  def handle_event("password_link", %{"id" => id}, socket) do
    case account(socket.assigns.accounts, id) do
      nil ->
        {:noreply, refused(socket)}

      %{user: user} ->
        case Accounts.build_password_link(
               socket.assigns.scope,
               user,
               &url(~p"/users/password/#{&1}")
             ) do
          # The link in a function, as the core's People page keeps it, so no inspection
          # of the process's state prints it.
          {:ok, url, expires_at} ->
            {:noreply,
             assign(socket, :password_link, %{
               email: user.email,
               url: fn -> url end,
               expires_at: expires_at
             })}

          {:error, :mail_set} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext(
                 "Qory Apiary sends email now: they get a log-in link from the log-in page instead."
               )
             )
             |> load()}

          {:error, :not_found} ->
            {:noreply, socket |> assign(:password_link, nil) |> refused()}

          {:error, :own_account} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(:error, gettext("Change your password in Account settings."))}

          # The sign-in is not recent: signed in again first, as the core's People page asks.
          {:error, :sudo} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("You must re-authenticate to access this page."))
             |> redirect(to: ~p"/users/log-in")}

          {:error, reason} when reason in [:forbidden, :no_instance_organisation] ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext(
                 "Only an admin of this Qory Apiary makes password links, while it sends no email."
               )
             )
             |> load()}

          # An account the edition refuses, a suspended one, gets no link.
          {:error, _refusal} ->
            {:noreply,
             socket
             |> assign(:password_link, nil)
             |> put_flash(
               :error,
               gettext("That account cannot log in at the moment, so it gets no password link.")
             )}
        end
    end
  end

  def handle_event("password_link_done", _params, socket),
    do: {:noreply, assign(socket, :password_link, nil)}

  # A confirmation without its row open, as a second click of a button whose
  # confirmation has closed sends: the page as it is now.
  def handle_event("suspend_account", _params, socket) do
    {:noreply, socket |> load() |> back()}
  end

  defp load(socket) do
    scope = socket.assigns.scope

    socket
    |> assign(:password_links?, password_links?())
    |> assign_async(:accounts, fn ->
      case Suspensions.list_accounts(scope) do
        {:ok, rows} -> {:ok, %{accounts: rows}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Whether the page offers password links at all: while no mail is set, as the core's
  # People page does. Each row calls `can?/3`, and the core's context checks again when one
  # is made.
  defp password_links?, do: not Apiary.Mail.configured?()

  # The listed account `id`, while the list is loaded; nil for one it does not hold.
  defp account(%{ok?: true, result: rows}, id), do: Enum.find(rows, &(&1.user.id == id))
  defp account(_accounts, _id), do: nil

  # Back to the list as it was left: its view and its search.
  defp back(socket),
    do: push_patch(socket, to: list_path(socket.assigns.list, []))

  defp refused(socket) do
    socket
    |> put_flash(
      :error,
      gettext("That is no longer possible. The page shows the instance as it is now.")
    )
    |> load()
    |> back()
  end

  # The account a suspension's confirmation is about, in a list of one, while it may be
  # suspended: not the reader's account, nor one suspended already.
  defp target(%{ok?: true, result: rows}, id, scope) when is_binary(id) do
    Enum.filter(rows, fn %{user: user} = row ->
      user.id == id and is_nil(row.suspended_at) and
        Access.can?(scope, :"instance.suspend_account", user)
    end)
  end

  defp target(_accounts, _id, _scope), do: []

  ## The list's views and search, in the URL.

  @views ~w(all suspended)

  defp views, do: [{"all", gettext("All")}, {"suspended", gettext("Suspended")}]

  defp list_params(params) do
    %{
      view: if(params["view"] in @views, do: params["view"], else: "all"),
      q:
        case String.trim(params["q"] || "") do
          "" -> nil
          q -> q
        end
    }
  end

  defp list_path(list, changes) do
    list = Enum.into(changes, list)
    Paths.accounts(view: list.view != "all" && list.view, q: list.q)
  end

  # What an empty list says: that nothing matches where the search narrows it, what the
  # view keeps where only the view does.
  defp empty_title(%{q: nil, view: "suspended"}), do: gettext("No account is suspended")
  defp empty_title(_list), do: gettext("No account matches")

  defp in_view?(_account, "all"), do: true
  defp in_view?(account, "suspended"), do: not is_nil(account.suspended_at)

  defp shown(accounts, list) do
    Enum.filter(accounts, &(in_view?(&1, list.view) and matches?(&1.user.email, list.q)))
  end

  defp matches?(_email, nil), do: true
  defp matches?(email, q), do: String.contains?(String.downcase(email), String.downcase(q))
end
