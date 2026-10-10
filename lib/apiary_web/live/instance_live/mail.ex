defmodule ApiaryWeb.InstanceLive.Mail do
  @moduledoc """
  Instance settings › Mail, `/instance/mail`: the mail server Qory Apiary sends its email
  through (`Apiary.Mail`), for the instance's admins (`Apiary.Access.instance_admin?/1`);
  anyone else is answered as a path that does not exist
  (`ApiaryWeb.NotFound`). It comes after an edition's sections and before Configuration
  (`ApiaryWeb.Layouts.instance_sections/1`).

  Where the server's environment sets mail (`SMTP_RELAY`), it wins whole: the page shows
  the environment's settings, read only, and says where to change them. Otherwise it says
  whether mail is on, and holds the form: the relay, its port, TLS, username and password,
  and the sender. Saving sends a test link to the admin who saved, and mail is off until
  they follow it (`ApiaryWeb.InstanceMailController`), signed in as themselves.

  The password is never shown: its field is always empty, and the page keeps neither the
  password given nor the one saved; a saved one is said to be there, and is kept while the
  field stays empty and nothing it is bound to changes (`Apiary.Mail.save_settings/3`).

  The page asks for a recent sign-in, as Account settings does (`ApiaryWeb.UserAuth`'s
  sudo mode): whoever controls the mail receives every log-in link. A save after the
  sign-in has grown old leads to the log-in page the same way.
  """
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.{Access, Mail}
  alias Apiary.Mail.{Password, Settings}
  alias ApiaryWeb.SettingsComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:mail}
    >
      <.settings_page section={:mail} title={gettext("Mail")}>
        <:subtitle>
          {gettext(
            "The mail server Qory Apiary sends its email through: invitations, log-in links and password links."
          )}
        </:subtitle>

        <SettingsComponents.part :if={@source == :env} id="mail-env">
          <p id="mail-status" class="text-[13px]/[20px]">
            <.rich text={
              rich_gettext("Set by the server's environment (%{variable}); change it there.",
                variable: {:code, "SMTP_RELAY", "q-mono"}
              )
            } />
          </p>
          <dl :if={@env[:relay]} id="mail-env-settings" class="grid gap-4">
            <.setting id="mail-env-relay" label={gettext("SMTP relay")} value={@env[:relay]} />
            <.setting id="mail-env-port" label={gettext("Port")} value={to_string(@env[:port])} />
            <.setting id="mail-env-tls" label={gettext("TLS")} value={env_tls(@env)} />
            <.setting
              id="mail-env-username"
              label={gettext("Username")}
              value={@env[:username] || gettext("None")}
            />
            <.setting id="mail-env-sender" label={gettext("Sender")} value={@default_sender} />
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part :if={@source != :env} id="mail-settings">
          <div id="mail-status">
            <.notice :if={@state in [:none, :pending]}>
              {gettext("Off: invitations and password links are copied by hand.")}
            </.notice>
            <.notice :if={@state == :on} kind={:success}>
              {gettext("On since %{day}.", day: Format.day(@settings.mail_verified_at))}
            </.notice>
            <.notice :if={@state == :unreadable} kind={:error}>
              {gettext("Off: the saved password cannot be read. Enter it again and save.")}
            </.notice>
          </div>

          <.form for={@form} id="mail_form" phx-submit="save" class="q-form" novalidate>
            <div class="q-form-two">
              <.input
                field={@form[:smtp_relay]}
                label={gettext("SMTP relay")}
                hint={gettext("The mail server's host name, such as smtp.example.com.")}
                autocomplete="off"
                spellcheck="false"
                required
              />
              <.input
                field={@form[:smtp_port]}
                type="number"
                label={gettext("Port")}
                hint={gettext("587 for STARTTLS; 465 for TLS from the start.")}
                min="1"
                max="65535"
              />
            </div>
            <.input
              field={@form[:smtp_tls]}
              type="select"
              label={gettext("TLS")}
              hint={gettext("On port 465, TLS from the start, whatever this says.")}
              options={[
                {gettext("Always"), "always"},
                {gettext("When the server offers it"), "if_available"},
                {gettext("Never"), "never"}
              ]}
            />
            <div class="q-form-two">
              <.input
                field={@form[:smtp_username]}
                label={gettext("Username")}
                hint={gettext("Empty when the relay takes mail without logging in.")}
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@form[:smtp_password]}
                type="password"
                value=""
                label={gettext("Password")}
                hint={
                  @password_saved &&
                    gettext(
                      "Saved, and never shown. Leave it empty to keep it, unless you change the relay, port, TLS or username."
                    )
                }
                autocomplete="new-password"
                spellcheck="false"
              />
            </div>
            <.input
              field={@form[:mail_from]}
              type="email"
              label={gettext("Sender")}
              hint={
                gettext("The address email comes from. Empty: %{address}.", address: @default_sender)
              }
              autocomplete="off"
              spellcheck="false"
            />
            <SettingsComponents.save id="mail-save">
              <.button type="submit" variant="primary" loading_text={gettext("Sending")}>
                {gettext("Save")}
              </.button>
              <:note>
                {gettext("Saving sends a test link to %{email}. Mail is off until you follow it.",
                  email: @current_scope.user.email
                )}
              </:note>
            </SettingsComponents.save>
          </.form>

          <div :if={@sent == :not_sent} id="mail-not-sent">
            <.notice kind={:error}>
              {gettext(
                "Saved, but the test link could not be sent through these settings. Check them and save again."
              )}
            </.notice>
          </div>
          <p
            :if={@state == :pending and @sent != :not_sent and @link_waiting}
            id="mail-pending"
            class="q-foot-note"
          >
            {if @settings.mail_saved_by_id == @current_scope.user.id,
              do:
                gettext(
                  "Mail turns on when you follow the link we sent to %{email}, signed in as you.",
                  email: @current_scope.user.email
                ),
              else:
                gettext(
                  "Mail turns on when the admin who saved these settings follows the link we sent them."
                )}
          </p>
          <p
            :if={@state == :pending and @sent != :not_sent and not @link_waiting}
            id="mail-no-link"
            class="q-foot-note"
          >
            {gettext("No test link is waiting: save the settings again to send one.")}
          </p>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  # One setting of the environment's, read only.
  defp setting(assigns) do
    ~H"""
    <div id={@id} class="grid gap-x-6 gap-y-1 text-[13px]/[20px] sm:grid-cols-[200px_minmax(0,1fr)]">
      <dt class="text-muted">{@label}</dt>
      <dd id={"#{@id}-value"} class="m-0 min-w-0 font-medium break-words">{@value}</dd>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Access.instance_admin?(socket.assigns.current_scope) do
      {:ok,
       socket
       |> assign(
         page_title:
           SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
             gettext("Mail")
           ]),
         sent: nil
       )
       |> load()}
    else
      raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_event("save", %{"mail" => params}, socket) when is_map(params) do
    url_fun = &url(~p"/instance/mail/confirm/#{&1}")

    case Mail.save_settings(socket.assigns.current_scope, params, url_fun) do
      {:ok, _settings, sent} ->
        {:noreply, socket |> assign(sent: sent) |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, sent: nil, form: to_form(changeset, as: "mail", action: :save))}

      {:error, :env} ->
        {:noreply, socket |> assign(sent: nil) |> load()}

      # The sign-in has grown old since the page opened: as the page's own mount does.
      {:error, :sudo} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You must re-authenticate to access this page."))
         |> redirect(to: ~p"/users/log-in")}

      # No longer an instance admin: the page itself is not found now.
      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: ~p"/instance/mail")}
    end
  end

  # What the page shows, read now: where mail comes from, and the saved settings, their
  # state, whether a test link waits, and the form. None of it holds a password.
  defp load(socket) do
    settings = Mail.settings()

    assign(socket,
      source: Mail.source(),
      env: env_shown(),
      default_sender: Apiary.Mailer.default_address(),
      settings: settings,
      state: Mail.state(settings),
      link_waiting: Mail.test_link_waiting?(settings),
      password_saved: match?({:ok, _password}, settings && Password.decrypt(settings)),
      form: settings_form(settings)
    )
  end

  # The environment's settings the page shows: never the password.
  defp env_shown, do: Keyword.take(Mail.env(), [:relay, :port, :ssl, :tls, :username])

  defp settings_form(settings) do
    (settings || %Settings{})
    |> Settings.changeset(%{})
    |> Settings.without_password()
    |> to_form(as: "mail")
  end

  # TLS as the environment's configuration has it: from the start on port 465, else
  # STARTTLS as SMTP_TLS says.
  defp env_tls(env) do
    cond do
      env[:ssl] -> gettext("From the start (port 465)")
      env[:tls] == :if_available -> gettext("When the server offers it")
      env[:tls] == :never -> gettext("Never")
      true -> gettext("Always")
    end
  end
end
