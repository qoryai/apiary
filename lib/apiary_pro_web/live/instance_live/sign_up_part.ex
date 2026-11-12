defmodule ApiaryProWeb.InstanceLive.SignUpPart do
  @moduledoc """
  Sign-up, the edition's part of Instance settings › Configuration
  (`c:ApiaryWeb.Edition.configuration_parts/1`), after the core's Invitations: whether
  someone without an invitation may sign up and create an organisation, and an operator
  (`ApiaryPro.SignUp`), each Closed or Open.

  Built from the core's rows (`ApiaryWeb.InstanceLive.ConfigurationComponents`). A setting
  the server's environment sets, `SIGNUP_ORGANISATIONS` or `SIGNUP_OPERATORS`, is shown
  read only, with the variable that sets it; the others have a field, which shows the
  setting in effect, Closed until one is saved. The form and its Save are there while one
  of them has a field.

  Saving is an instance admin's after a recent sign-in (`ApiaryPro.SignUp.save/2`), and
  applies at once. A save after the sign-in has grown old sends the page
  `{:configuration, :sudo}`, and the page leads to the log-in page; one by a person no
  longer an instance admin opens the page again, which then is not found. Once saved, the
  page shows the toast (`ApiaryWeb.InstanceLive.ConfigurationComponents.saved/2`).
  """
  use ApiaryProWeb, :live_component

  alias ApiaryPro.SignUp
  alias ApiaryWeb.InstanceLive.ConfigurationComponents
  alias ApiaryWeb.SettingsComponents

  # The rows, in the order of the page: the kind and the name of its field.
  @rows [organisation: :organisations, operator: :operators]

  @impl true
  def render(assigns) do
    ~H"""
    <section id="config-sign-up" class="q-part" aria-labelledby="config-sign-up-title">
      <h2 id="config-sign-up-title" class="q-part-h">{gettext("Sign-up")}</h2>
      <.form
        :if={@form}
        for={@form}
        id="config-sign-up-form"
        phx-submit="save"
        phx-target={@myself}
        class="q-form"
        novalidate
      >
        <.rows settings={@settings} env={@env} form={@form} />
        <SettingsComponents.save id="config-sign-up-save">
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Save")}
          </.button>
        </SettingsComponents.save>
      </.form>
      <.rows :if={!@form} settings={@settings} env={@env} form={nil} />
    </section>
    """
  end

  attr :settings, :map, required: true
  attr :env, :map, required: true
  attr :form, :any, required: true

  defp rows(assigns) do
    ~H"""
    <dl class="grid gap-4">
      <.row
        id="config-sign-up-organisations"
        kind={:organisation}
        label={gettext("Organisations")}
        settings={@settings}
        env={@env}
        form={@form}
      >
        {gettext(
          "Whether someone without an invitation may sign up and create an organisation, and whether someone signed in may create one from the organisation menu."
        )}
      </.row>
      <.row
        id="config-sign-up-operators"
        kind={:operator}
        label={gettext("Operators")}
        settings={@settings}
        env={@env}
        form={@form}
      >
        {gettext(
          "Whether someone without an invitation may sign up and create an operator, an organisation that provides a harness its clients run, and whether someone signed in may create one from the organisation menu."
        )}
      </.row>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :label, :string, required: true
  attr :settings, :map, required: true
  attr :env, :map, required: true
  attr :form, :any, required: true
  slot :inner_block, required: true

  # A setting the environment sets: its value, read only, with the variable that sets it.
  defp row(%{env: env, kind: kind} = assigns) when is_map_key(env, kind) do
    ~H"""
    <ConfigurationComponents.setting
      id={@id}
      label={@label}
      value={shown(@settings[@kind])}
      source={ConfigurationComponents.env_line(SignUp.variable(@kind))}
    >
      {render_slot(@inner_block)}
    </ConfigurationComponents.setting>
    """
  end

  # Else its field, which shows the setting in effect: closed until one is saved.
  defp row(assigns) do
    field = assigns.form[Keyword.fetch!(@rows, assigns.kind)]
    errors = Enum.map(field.errors, &translate_error/1)
    input_id = "#{assigns.id}-input"

    described_by =
      errors
      |> Enum.with_index()
      |> Enum.map_join(" ", fn
        {_message, 0} -> "#{assigns.id}-error"
        {_message, i} -> "#{assigns.id}-error-#{i + 1}"
      end)

    assigns =
      assign(assigns,
        field: field,
        errors: errors,
        input_id: input_id,
        described_by: described_by
      )

    ~H"""
    <ConfigurationComponents.setting id={@id} label={@label} for={@input_id} errors={@errors}>
      <:field>
        <select
          id={@input_id}
          name={@field.name}
          class={["select select-sm w-28", @errors != [] && "select-error"]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@described_by != "" && @described_by}
        >
          {Phoenix.HTML.Form.options_for_select(
            [{gettext("Closed"), "closed"}, {gettext("Open"), "open"}],
            @field.value
          )}
        </select>
      </:field>
      {render_slot(@inner_block)}
    </ConfigurationComponents.setting>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(Map.has_key?(socket.assigns, :settings), do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("save", params, socket) do
    attrs =
      case params["sign_up"] do
        %{} = attrs -> attrs
        _none -> %{}
      end

    case SignUp.save(socket.assigns.current_scope, attrs) do
      {:ok, _settings} ->
        {:noreply, socket |> ConfigurationComponents.saved(gettext("Sign-up saved.")) |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "sign_up"))}

      # The sign-in has grown old since the page opened: the page leads to the log-in
      # page.
      {:error, :sudo} ->
        send(self(), {:configuration, :sudo})
        {:noreply, socket}

      # No longer an instance admin: the page itself is not found now.
      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: ~p"/instance/configuration")}
    end
  end

  # What the part shows, read from the database now, as the page reads its settings: the
  # setting in effect of each kind; the environment's, where it sets one; and the form of
  # the others, holding the setting in effect, nil where the environment sets both.
  defp load(socket) do
    settings = SignUp.settings(SignUp.load())

    env =
      for {kind, _name} <- @rows, setting = SignUp.env(kind), into: %{}, do: {kind, setting}

    form =
      case for {kind, name} <- @rows, not is_map_key(env, kind), do: {name, settings[kind]} do
        [] -> nil
        fields -> to_form(Map.new(fields, fn {name, s} -> {"#{name}", "#{s}"} end), as: "sign_up")
      end

    assign(socket, settings: settings, env: env, form: form)
  end

  defp shown(:open), do: gettext("Open")
  defp shown(:closed), do: gettext("Closed")
end
