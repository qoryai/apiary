defmodule ApiaryWeb.InstanceLive.Mail do
  @moduledoc """
  Instance settings › Mail, `/instance/mail`: the mail server Qory Apiary sends its email
  through (`Apiary.Mail`), for the instance's admins (`Apiary.Access.instance_admin?/1`);
  anyone else is answered as a path that does not exist
  (`ApiaryWeb.NotFound`). It comes after an edition's sections and before Configuration
  (`ApiaryWeb.Layouts.instance_sections/1`).

  The page holds the mail server's form (`ApiaryWeb.InstanceLive.MailForm`), which the
  mail step of the instance's connections holds too: where the server's environment sets
  mail, its settings, read only; otherwise whether mail is on, and the form, whose save
  sends a test link to the admin who saved.

  The page asks for a recent sign-in, as Account settings does (`ApiaryWeb.UserAuth`'s
  sudo mode): whoever controls the mail receives every log-in link. A save after the
  sign-in has grown old leads to the log-in page the same way.
  """
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.Access
  alias ApiaryWeb.InstanceLive.MailForm
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

        <.live_component
          module={MailForm}
          id="mail"
          current_scope={@current_scope}
          path={~p"/instance/mail"}
        />
      </.settings_page>
    </Layouts.app>
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
           ])
       )}
    else
      raise ApiaryWeb.NotFound
    end
  end

  # The form's events go to the form (`ApiaryWeb.InstanceLive.MailForm`); one sent to the
  # page is refused in silence, before anything reads it, so no crash report prints it.
  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}
end
