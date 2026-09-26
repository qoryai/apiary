defmodule ApiaryWeb.UserLive.Settings do
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.Accounts
  alias Apiary.Accounts.Preferences

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={assigns[:nav_counts]}
      width="narrow"
    >
      <.header>
        {gettext("Account settings")}
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

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, gettext("Account settings"))
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:languages, Preferences.languages())
      |> assign(:preferences_form, preferences_form(Accounts.change_user_preferences(user)))
      |> assign_new(:memberships, fn -> [] end)

    {:ok, socket}
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
