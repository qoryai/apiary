defmodule ApiaryWeb.UserLive.Settings do
  @moduledoc """
  A person's own settings, one section a page, whose list is the sidebar of a person's
  pages under Your settings (`ApiaryWeb.Layouts`): Profile, `/users/settings` (`:edit`),
  their email address, their password and, last, its danger zone
  (`ApiaryWeb.SettingsComponents.danger_zone/1`), deleting their account, confirmed inline
  in it, its line expanded in place at `/users/settings/delete` (`:delete`), where they
  type their email to confirm, once nothing stops the deletion; and Preferences, `/users/settings/preferences` (`:preferences`), their language
  and time zone, kept with the account, and the theme and the keyboard shortcuts, reading
  preferences of the browser (`localStorage`), the same theme the account menu sets.

  Profile and the deletion ask for a recent sign-in (`ApiaryWeb.UserAuth`'s sudo mode),
  for they change what the account is or end it; Preferences does not.
  """
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, {:require_sudo_mode, except: [:preferences]}}

  import ApiaryWeb.SettingsComponents, only: [theme_picker: 1]

  alias Apiary.{Accounts, Organisations}
  alias Apiary.Accounts.Preferences
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={assigns[:nav_counts]}
      nav={if @live_action == :preferences, do: :user_preferences, else: :user_settings}
    >
      <.settings_page
        section={if @live_action == :preferences, do: :user_preferences, else: :user_settings}
        title={if @live_action == :preferences, do: gettext("Preferences"), else: gettext("Profile")}
      >
        <:subtitle :if={@live_action != :preferences}>
          {gettext("Your email address and password, and your account itself.")}
        </:subtitle>
        <:subtitle :if={@live_action == :preferences}>
          {gettext("How the console shows things to you, in every organisation you belong to.")}
        </:subtitle>

        <SettingsComponents.part :if={@live_action != :preferences} id="email">
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            class="q-form"
            aria-label={gettext("Email")}
            novalidate
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
            />
            <SettingsComponents.save>
              <.button type="submit" loading_text={gettext("Sending")}>
                {gettext("Change email")}
              </.button>
              <:note>{gettext("We send a confirmation link to the new address.")}</:note>
            </SettingsComponents.save>
          </.form>
        </SettingsComponents.part>

        <SettingsComponents.part :if={@live_action != :preferences} id="password">
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="q-form"
            aria-label={gettext("Password")}
            novalidate
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              autocomplete="username"
              value={@current_email}
            />
            <div class="q-form-two">
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
            </div>
            <SettingsComponents.save>
              <.button type="submit" loading_text={gettext("Saving")}>
                {gettext("Save password")}
              </.button>
              <:note>{gettext("Optional. Log-in links keep working either way.")}</:note>
            </SettingsComponents.save>
          </.form>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@live_action == :preferences}
          id="preferences"
          level={:h2}
          title={gettext("Language and time")}
        >
          <.form
            for={@preferences_form}
            id="preferences_form"
            phx-submit="update_preferences"
            class="q-form"
            novalidate
          >
            <div class="q-form-two">
              <.input
                :if={length(@languages) > 1}
                field={@preferences_form[:language]}
                type="select"
                label={gettext("Language")}
                options={Enum.map(@languages, &{language_name(&1), &1})}
              />
              <.input
                field={@preferences_form[:time_zone]}
                type="select"
                label={gettext("Time zone")}
                hint={gettext("Times are shown in this zone. They are kept in UTC.")}
                options={time_zone_options(@preferences_form[:time_zone].value)}
              />
            </div>
            <p
              :if={length(@languages) <= 1}
              id="preferences_language"
              class="text-[13px] text-muted"
            >
              {gettext("Pages are in English, the one language this instance has.")}
            </p>
            <SettingsComponents.save>
              <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
                {gettext("Save")}
              </.button>
              <:note>{gettext("Yours in every organisation you belong to.")}</:note>
            </SettingsComponents.save>
          </.form>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@live_action == :preferences}
          id="theme"
          level={:h2}
          title={gettext("Theme")}
        >
          <.theme_picker />
          <p class="q-foot-note">
            {pgettext(
              "plain",
              "Applies at once, on this browser. Auto follows the device's light or dark setting. The terminal stays dark in every theme."
            )}
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@live_action == :preferences}
          id="keyboard"
          level={:h2}
          title={gettext("Keyboard")}
        >
          <.switch
            id="shortcuts-switch"
            label={gettext("Keyboard shortcuts")}
            checked
            data-pref="shortcuts"
            phx-click={JS.dispatch("phx:set-shortcuts")}
            phx-mounted={JS.ignore_attributes(["aria-checked"])}
          >
            {gettext(
              "Single keys such as / to search, [ to fold the sidebar and the run timeline's letters. Off, only shortcuts with ⌘ or Ctrl work, such as ⌘K and Ctrl+K to search. Kept on this browser."
            )}
          </.switch>
        </SettingsComponents.part>

        <SettingsComponents.danger_zone :if={@live_action != :preferences}>
          <SettingsComponents.danger_action
            id="delete-account"
            title={gettext("Delete account")}
            button={gettext("Delete account…")}
            disabled={@sole_owned != []}
            open={@live_action == :delete}
            open_path={~p"/users/settings/delete"}
            close_path={~p"/users/settings"}
            question={gettext("Delete your account?")}
            form={@confirm_form}
            change="confirm"
            submit="delete_account"
            ready={email_typed?(@confirm_form[:email].value, @current_email)}
          >
            {gettext(
              "Your email address, password and preferences are erased and you leave every organisation you belong to, which cannot be undone; what you made in a workspace stays there and names you as a former member."
            )}
            <:lost>
              {gettext(
                "Your email address, password and preferences are erased at once, you leave every organisation you belong to, and you are logged out everywhere. This cannot be undone: to come back, sign up again, as a new account."
              )}
            </:lost>
            <:lost :if={@marked_alone != []} id="delete-account-lost-orphans">
              {ngettext(
                "Nobody will be left who can cancel the deletion of the organisation you are the only owner of: it is purged when its grace period is over.",
                "Nobody will be left who can cancel the deletion of the organisations you are the only owner of: they are purged when their grace period is over.",
                length(@marked_alone)
              )}
            </:lost>
            <:field>
              <.input
                field={@confirm_form[:email]}
                type="text"
                label={gettext("Type your email, %{email}, to confirm", email: @current_email)}
                autocomplete="off"
                spellcheck="false"
                debounce="0"
              />
            </:field>
          </SettingsComponents.danger_action>
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
            <ul id="sole-owned" class="mt-1.5 grid gap-1">
              <li :for={organisation <- @sole_owned} id={"sole-owned-#{organisation.id}"}>
                <.link
                  navigate={~p"/#{organisation}/settings"}
                  class="link inline-flex min-h-6 items-center font-medium"
                >
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
        </SettingsComponents.danger_zone>
      </.settings_page>
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
      |> assign(:page_title, page_title(socket.assigns.live_action))
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
      |> assign_confirm()
      |> load_sole_owned()

    {:ok, socket}
  end

  # A patch from Preferences to Profile or the deletion asks for the recent sign-in the
  # mount asked of them.
  @impl true
  def handle_params(_params, _uri, socket) do
    socket = socket |> assign(:page_title, page_title(socket.assigns.live_action))

    if socket.assigns.live_action != :preferences and
         not Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:noreply, reauthenticate(socket)}
    else
      {:noreply,
       if(socket.assigns.live_action == :delete, do: socket, else: assign_confirm(socket))}
    end
  end

  defp reauthenticate(socket) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  # The email typed to confirm the account's deletion, and whether it was refused.
  defp assign_confirm(socket, params \\ %{}, refused \\ nil) do
    errors =
      case refused do
        :mismatch -> [email: {dgettext_noop("errors", "is not your email"), []}]
        nil -> []
      end

    assign(socket, :confirm_form, to_form(params, as: :confirm, errors: errors))
  end

  # Whether the email typed is the account's, as it is written or in another case, with
  # the spaces around it left out.
  defp email_typed?(typed, email) when is_binary(typed),
    do: String.downcase(String.trim(typed)) == String.downcase(email)

  defp email_typed?(_typed, _email), do: false

  defp page_title(:preferences), do: gettext("Preferences") <> " · " <> gettext("Your settings")
  defp page_title(_profile), do: gettext("Profile") <> " · " <> gettext("Your settings")

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
          {:noreply, push_navigate(socket, to: ~p"/users/settings/preferences")}
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

  def handle_event("confirm", %{"confirm" => params}, socket),
    do: {:noreply, assign_confirm(socket, params)}

  def handle_event("delete_account", params, socket) do
    scope = socket.assigns.current_scope
    typed = get_in(params, ["confirm", "email"])

    cond do
      not Accounts.sudo_mode?(scope.user) ->
        {:noreply, reauthenticate(socket)}

      not email_typed?(typed, scope.user.email) ->
        {:noreply, assign_confirm(socket, %{"email" => typed || ""}, :mismatch)}

      true ->
        delete_account(socket, scope)
    end
  end

  defp delete_account(socket, scope) do
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
