defmodule ApiaryWeb.UserLive.Settings do
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.{Accounts, Organisations}
  alias Apiary.Accounts.Preferences
  alias ApiaryWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={assigns[:nav_counts]}
      nav={:user_settings}
      width="read"
    >
      <.header>
        {gettext("Your settings")}
        <:subtitle>{gettext("Your email address, password and preferences.")}</:subtitle>
      </.header>

      <.card>
        <:title>{gettext("Email")}</:title>
        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
        </.form>
        <:footer>
          <span>{gettext("We send a confirmation link to the new address.")}</span>
          <.button type="submit" form="email_form" loading_text={gettext("Sending")}>
            {gettext("Change email")}
          </.button>
        </:footer>
      </.card>

      <.card>
        <:title>{gettext("Password")}</:title>
        <.form
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
          class="grid max-w-[420px] gap-4"
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_user_email"
            autocomplete="username"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label={gettext("New password")}
            hint={gettext("At least 12 characters.")}
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
            autocomplete="new-password"
            spellcheck="false"
          />
        </.form>
        <:footer>
          <span>{gettext("Optional. Log-in links keep working either way.")}</span>
          <.button type="submit" form="password_form" loading_text={gettext("Saving")}>
            {gettext("Save password")}
          </.button>
        </:footer>
      </.card>

      <.card id="preferences">
        <:title>{gettext("Preferences")}</:title>
        <.form
          for={@preferences_form}
          id="preferences_form"
          phx-submit="update_preferences"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@preferences_form[:time_zone]}
            type="select"
            label={gettext("Time zone")}
            hint={gettext("Times are shown in this zone. They are kept in UTC.")}
            options={time_zone_options(@preferences_form[:time_zone].value)}
          />
          <.input
            :if={length(@languages) > 1}
            field={@preferences_form[:language]}
            type="select"
            label={gettext("Language")}
            options={Enum.map(@languages, &{language_name(&1), &1})}
          />
        </.form>
        <p :if={length(@languages) <= 1} id="preferences_language" class="text-[13px] text-muted">
          {gettext("Pages are in English, the one language this instance has.")}
        </p>
        <:footer>
          <span>{gettext("Yours in every organisation you belong to.")}</span>
          <.button type="submit" form="preferences_form" loading_text={gettext("Saving")}>
            {gettext("Save preferences")}
          </.button>
        </:footer>
      </.card>

      <.card id="delete-account">
        <:title>{gettext("Delete account")}</:title>
        <p class="max-w-[60ch] text-muted">
          {gettext(
            "Your email address, password and preferences are erased, and you leave every organisation you belong to. What you made in a workspace stays there and names you as a former member. The address is free for a new account at once."
          )}
        </p>
        <div :if={is_nil(@sole_owned)} id="delete-account-loading" aria-busy="true">
          <span class="sr-only">{gettext("Checking the organisations you own")}</span>
          <span class="skeleton q-skel w-64"></span>
        </div>
        <.notice :if={@sole_owned not in [nil, []]} kind={:warning}>
          <p id="delete-account-blocked">
            {ngettext(
              "You are the only owner of this organisation. Make another member an owner, or delete the organisation, before you delete your account.",
              "You are the only owner of these organisations. Make another member an owner of each, or delete it, before you delete your account.",
              length(@sole_owned)
            )}
          </p>
          <ul id="sole-owned" class="mt-1.5 grid gap-0.5">
            <li :for={organisation <- @sole_owned} id={"sole-owned-#{organisation.id}"}>
              <.link navigate={~p"/#{organisation}/settings"} class="link font-medium">
                {organisation.name}
              </.link>
            </li>
          </ul>
        </.notice>
        <.notice :if={@sole_owned == [] and @marked_alone != []} kind={:warning}>
          <p id="delete-account-orphans">
            {ngettext(
              "You are the only owner of an organisation that is deleted and waits to be purged. Once your account is deleted, nobody is left who can cancel its deletion.",
              "You are the only owner of organisations that are deleted and wait to be purged. Once your account is deleted, nobody is left who can cancel their deletion.",
              length(@marked_alone)
            )}
          </p>
          <ul id="marked-alone" class="mt-1.5 grid gap-0.5">
            <li :for={organisation <- @marked_alone} id={"marked-alone-#{organisation.id}"}>
              <span class="font-medium">{organisation.name}</span>
            </li>
          </ul>
        </.notice>
        <:footer>
          <span>{gettext("It cannot be undone.")}</span>
          <.button
            :if={@sole_owned == []}
            id="delete-account-button"
            variant="danger"
            patch={~p"/users/settings/delete"}
          >
            {gettext("Delete account")}
          </.button>
          <.button
            :if={@sole_owned != []}
            id="delete-account-button"
            type="button"
            variant="danger"
            disabled
          >
            {gettext("Delete account")}
          </.button>
        </:footer>
      </.card>

      <.modal
        :if={@live_action == :delete}
        id="delete-account-modal"
        title={gettext("Delete your account")}
        on_cancel={JS.patch(~p"/users/settings")}
      >
        <p class="text-muted">
          {gettext(
            "Your email address, password and preferences are erased at once, you leave every organisation you belong to, and you are logged out everywhere. This cannot be undone: to come back, sign up again, as a new account."
          )}
        </p>
        <p :if={@marked_alone != []} id="delete-account-modal-orphans" class="text-muted">
          {ngettext(
            "Nobody will be left who can cancel the deletion of the organisation you are the only owner of: it is purged when its grace period is over.",
            "Nobody will be left who can cancel the deletion of the organisations you are the only owner of: they are purged when their grace period is over.",
            length(@marked_alone)
          )}
        </p>
        <:footer>
          <.button patch={~p"/users/settings"} data-autofocus>{gettext("Cancel")}</.button>
          <.button
            id="delete-account-confirm"
            variant="danger"
            phx-click="delete_account"
            loading_text={gettext("Deleting")}
          >
            {gettext("Delete my account")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Your email address is changed."))

        {:error, _} ->
          put_flash(socket, :error, gettext("That link has expired. Ask for a new one below."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, gettext("Your settings"))
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:languages, Preferences.languages())
      |> assign(:preferences_form, preferences_form(Accounts.change_user_preferences(user)))
      |> assign_new(:memberships, fn -> [] end)
      # This page's own session, which deleting the account ends by redirecting, rather
      # than by the disconnect the other sessions get.
      |> assign(:session_token, session["user_token"])
      |> assign(sole_owned: nil, marked_alone: [])
      |> load_sole_owned()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:sole_owned, {:ok, {sole_owned, marked_alone}}, socket),
    do: {:noreply, assign(socket, sole_owned: sole_owned, marked_alone: marked_alone)}

  # Not known: the deletion is not offered, and the context function asks again anyway.
  def handle_async(:sole_owned, _failed, socket), do: {:noreply, socket}

  # The organisations the person is the only owner of, which stop the deletion, and those
  # marked for deletion that nobody would be left to restore, which the page warns of:
  # read off the first paint, and again after a refused deletion.
  defp load_sole_owned(socket) do
    user = socket.assigns.current_scope.user

    if connected?(socket),
      do:
        start_async(socket, :sole_owned, fn ->
          {Organisations.sole_owned_organisations(user),
           Organisations.marked_sole_owned_organisations(user)}
        end),
      else: socket
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info =
          gettext("A link to confirm your email change is on its way to the new address.")

        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_preferences", %{"preferences" => params}, socket) do
    %{current_scope: scope} = socket.assigns

    case Accounts.update_user_preferences(scope.user, params) do
      {:ok, user} ->
        scope = %{scope | user: user}
        socket = put_flash(socket, :info, gettext("Preferences saved."))

        # Another language is another locale: the page is mounted again to be written in
        # it, and the time zone reaches every page as it mounts with the new scope.
        if user.language != socket.assigns.current_scope.user.language do
          {:noreply, push_navigate(socket, to: ~p"/users/settings")}
        else
          {:noreply,
           socket
           |> assign(:current_scope, scope)
           |> assign(:preferences_form, preferences_form(Accounts.change_user_preferences(user)))}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :preferences_form, preferences_form(changeset, :update))}
    end
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("delete_account", _params, socket) do
    scope = socket.assigns.current_scope

    if Accounts.sudo_mode?(scope.user) do
      case Accounts.delete_user(scope) do
        {:ok, {_tombstone, tokens}} ->
          tokens
          |> Enum.reject(&(&1.token == socket.assigns.session_token))
          |> UserAuth.disconnect_sessions()

          # This page's own session ends where it is sent, which disconnects it as a
          # log-out does.
          {:noreply, redirect(socket, to: ~p"/users/account-deleted")}

        {:error, :last_owner} ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             gettext(
               "You are the only owner of an organisation. Make another member an owner, or delete the organisation, first."
             )
           )
           |> load_sole_owned()
           |> push_patch(to: ~p"/users/settings")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> put_flash(:error, gettext("Your account could not be deleted. Try again."))
           |> push_patch(to: ~p"/users/settings")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You must re-authenticate to access this page."))
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  defp preferences_form(changeset, action \\ nil),
    do: to_form(changeset, as: :preferences, action: action || changeset.action)

  # The zones by region, as the zone database names them: UTC first, then each region's
  # zones under its name, the city as the reader would write it. A known zone chosen
  # outside the list, a link name such as `UTC`, stays on top so the select shows it.
  defp time_zone_options(current) do
    zones = Preferences.time_zones()
    [utc | regional] = zones
    # Only a zone the database knows: a refused one, sent by a crafted form, is not shown.
    extra =
      if current not in zones and Preferences.time_zone?(current),
        do: [{current, current}],
        else: []

    groups =
      regional
      |> Enum.chunk_by(&region/1)
      |> Enum.map(fn [first | _] = group ->
        {region(first), Enum.map(group, &{zone_label(&1), &1})}
      end)

    extra ++ [{"UTC", utc} | groups]
  end

  defp region(zone), do: zone |> String.split("/", parts: 2) |> hd()

  # The city and the countries that keep its clock, as the zone database names them, so a
  # country without a zone of its own (Norway keeps Berlin's) is found by its name.
  defp zone_label(zone) do
    case Preferences.time_zone_countries(zone) do
      [] -> city(zone)
      countries -> "#{city(zone)} (#{Enum.join(countries, ", ")})"
    end
  end

  defp city(zone) do
    case String.split(zone, "/", parts: 2) do
      [_region, city] -> String.replace(city, "_", " ")
      [zone] -> zone
    end
  end

  # A language is offered in its own name, whatever the page's language: a reader finds
  # theirs by the name they know. A language not listed shows its code.
  @language_names %{
    "de" => "Deutsch",
    "en" => "English",
    "es" => "Español",
    "fr" => "Français",
    "it" => "Italiano",
    "nl" => "Nederlands",
    "pl" => "Polski",
    "pt" => "Português"
  }

  defp language_name(language), do: Map.get(@language_names, language, language)
end
