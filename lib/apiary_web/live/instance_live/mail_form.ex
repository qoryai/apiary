defmodule ApiaryWeb.InstanceLive.MailForm do
  @moduledoc """
  The mail server's form, for an instance admin (`Apiary.Mail`): the one form of
  Instance settings › Mail (`ApiaryWeb.InstanceLive.Mail`) and of the mail step of the
  instance's connections, `/instance/set-up`. A live component, so both pages show the
  same form, its state and its save.

  Where the server's environment sets mail (`SMTP_RELAY`), it wins whole: the form shows
  the environment's settings, read only, and says where to change them. Otherwise it says
  whether mail is on, and holds the form: the relay, its port, TLS, username and password,
  and the sender. Saving sends a test link to the admin who saved, and mail is off until
  they follow it (`ApiaryWeb.InstanceMailController`), signed in as themselves.

  The password is never shown: its field is always empty, and the form keeps neither the
  password given nor the one saved; a saved one is said to be there, and is kept while the
  field stays empty and nothing it is bound to changes (`Apiary.Mail.save_settings/3`).

  `step` is the mail step's form: its button is "Save and send a test", with the step's
  `back` before it and its `actions` at the end of the row, and it says neither that mail
  is off nor what a save sends, which the step's context says. Once a save has sent the
  test link, it tells the page that holds it, `{ApiaryWeb.InstanceLive.MailForm, :sent}`.

  A save after the sign-in has grown old leads to the log-in page, as the settings page's
  mount does (`ApiaryWeb.UserAuth`'s sudo mode); a person who is no longer an instance
  admin is sent to `path`, the page's, which is then not found.
  """
  use ApiaryWeb, :live_component

  alias Apiary.Mail
  alias Apiary.Mail.Settings
  alias ApiaryWeb.SettingsComponents

  # Given: `id`, `current_scope`, `path`, the page's path, and, for the mail step, `step`
  # true and the `back` and `actions` slots.
  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
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
          <.notice :if={@state in [:none, :pending] and not @step}>
            {gettext("Off: invitations and password links are copied by hand.")}
          </.notice>
          <.notice :if={@state == :on} kind={:success}>
            {gettext("On since %{day}.", day: Format.day(@mail_verified_at))}
          </.notice>
          <.notice :if={@state == :unreadable} kind={:error}>
            {gettext("Off: the saved password cannot be read. Enter it again and save.")}
          </.notice>
        </div>

        <.form
          for={@form}
          id="mail_form"
          method="post"
          phx-submit="save"
          phx-target={@myself}
          class="q-form"
          novalidate
        >
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
              value={nil}
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
          <SettingsComponents.save :if={!@step} id="mail-save">
            <.button type="submit" variant="primary" loading_text={gettext("Sending")}>
              {gettext("Save")}
            </.button>
            <:note>
              {gettext("Saving sends a test link to %{email}. Mail is off until you follow it.",
                email: @current_scope.user.email
              )}
            </:note>
          </SettingsComponents.save>
          <div :if={@step} id="mail-save" class="q-su-acts">
            {render_slot(@back)}
            <.button type="submit" variant="primary" size="md" loading_text={gettext("Sending")}>
              {gettext("Save and send a test")}
            </.button>
            <span class="grow"></span>
            {render_slot(@actions)}
          </div>
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
          {if @mail_saved_by_id == @current_scope.user.id,
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
    </div>
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

  # The settings are read once, as the form first renders; a save reads them again.
  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = assign_new(socket, :step, fn -> false end)
    socket = assign_new(socket, :actions, fn -> [] end)
    socket = assign_new(socket, :back, fn -> [] end)

    if Map.has_key?(socket.assigns, :source),
      do: {:ok, socket},
      else: {:ok, socket |> assign(:sent, nil) |> load()}
  end

  # An event the form never sends is refused in silence, before any clause reads it
  # (`sent?/2`): the page stays up, so no crash report prints the event, and a password in
  # it with the rest of its terms.
  @impl true
  def handle_event(event, params, socket) do
    if sent?(event, params), do: handle(event, params, socket), else: {:noreply, socket}
  end

  # Whether an event and its parameters are what the form sends: `save`, its fields under
  # `mail`, each name and each value text, as a browser encodes a form, `_unused_` ones
  # among them. So the clause below, `Apiary.Mail.save_settings/3` and the form shown
  # again are given text only: a value of another type, or bytes that are not text, never
  # reach a cast, a query or a render that could fail on them and print them.
  defp sent?("save", %{"mail" => %{} = fields}),
    do: Enum.all?(fields, fn {name, value} -> text?(name) and text?(value) end)

  defp sent?(_event, _params), do: false

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp handle("save", %{"mail" => params}, socket) when is_map(params) do
    url_fun = &url(~p"/instance/mail/confirm/#{&1}")

    case Mail.save_settings(socket.assigns.current_scope, params, url_fun) do
      {:ok, _settings, sent} ->
        if sent == :sent and socket.assigns.step, do: send(self(), {__MODULE__, :sent})
        {:noreply, socket |> assign(sent: sent) |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, sent: nil, form: to_form(changeset, as: "mail", action: :save))}

      {:error, :env} ->
        {:noreply, socket |> assign(sent: nil) |> load()}

      # The sign-in has grown old since the page opened: as the settings page's mount does.
      {:error, :sudo} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You must re-authenticate to access this page."))
         |> redirect(to: ~p"/users/log-in")}

      # No longer an instance admin: the page itself is not found now.
      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: socket.assigns.path)}
    end
  end

  # What the form shows, read now: where mail comes from, and the saved settings, their
  # state, whether a test link waits, and the form. None of it holds a password, given or
  # saved (`Apiary.Mail.shown/0`): of the settings, the form keeps when mail turned on and
  # who saved them, and the form.
  defp load(socket) do
    %{settings: settings, state: state, password_saved: password_saved} = Mail.shown()

    assign(socket,
      source: Mail.source(),
      env: env_shown(),
      default_sender: Apiary.Mailer.default_address(),
      mail_verified_at: settings && settings.mail_verified_at,
      mail_saved_by_id: settings && settings.mail_saved_by_id,
      state: state,
      link_waiting: Mail.test_link_waiting?(settings),
      password_saved: password_saved,
      form: settings_form(settings)
    )
  end

  # The environment's settings the form shows: never the password.
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
