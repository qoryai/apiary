defmodule ApiaryWeb.InstanceLive.General do
  @moduledoc """
  Instance settings › General, `/instance/general`: the product's name on this instance
  (`Apiary.ProductName`), for the instance's admins (`Apiary.Access.instance_admin?/1`);
  anyone else is answered as a path that does not exist (`ApiaryWeb.NotFound`). It is the
  Instance level's first section, before an edition's and the core's Mail and
  Configuration (`ApiaryWeb.Layouts.instance_sections/1`).

  The form holds one field, the name. Empty, it shows the edition's name
  (`Apiary.ProductName.edition_name/0`) as its placeholder, and saving it empty sets no
  name: the defaults show again (`Apiary.ProductName`). The name's rules are an
  organisation's name's, and its errors show under the field. Saving reloads the page, so
  its browser title and its sidebar show the new name at once. Every page opened after it
  shows the new name, and every email sent after it, except where a live page opened
  before sends one: that page, and its emails, keep the name it read as it connected until
  the person leaves it (`Apiary.ProductName.hold/0`).
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, ProductName}
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
      section={:general}
    >
      <.settings_page section={:general} title={gettext("General")}>
        <:subtitle>
          {gettext("The name this instance shows on its pages and in its email.")}
        </:subtitle>

        <SettingsComponents.part id="instance-name">
          <.form for={@form} id="instance-name-form" phx-submit="save" class="q-form" novalidate>
            <.input
              field={@form[:product_name]}
              type="text"
              label={gettext("Name")}
              placeholder={@default}
              hint={
                gettext(
                  "Shown in the browser tab, the sidebar, the log-in pages and every email. Empty: %{name}.",
                  name: @default
                )
              }
              autocomplete="off"
            />
            <SettingsComponents.save id="instance-name-save">
              <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
                {gettext("Save")}
              </.button>
              <:note :if={@attribution}>
                {gettext(
                  "When a name other than Qory Apiary is set, the sidebar, the log-in pages and every email also say “Powered by Qory Apiary”."
                )}
              </:note>
            </SettingsComponents.save>
          </.form>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Access.instance_admin?(socket.assigns.current_scope) do
      {:ok,
       assign(socket,
         page_title:
           SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
             gettext("General")
           ]),
         default: ProductName.edition_name(),
         attribution: Apiary.Edition.attribution?(),
         form: to_form(ProductName.change(), as: "instance")
       )}
    else
      raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_event("save", %{"instance" => params}, socket) when is_map(params) do
    case ProductName.rename(socket.assigns.current_scope, params) do
      # A reload, so the browser title and the sidebar name the instance as it is now.
      {:ok, name} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Instance renamed to %{name}.", name: name || socket.assigns.default)
         )
         |> redirect(to: ~p"/instance/general")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "instance"))}

      # No longer an instance admin: the page itself is not found now.
      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: ~p"/instance/general")}
    end
  end
end
