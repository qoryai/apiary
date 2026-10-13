defmodule ApiaryWeb.InstanceLive.Configuration do
  @moduledoc """
  Instance settings › Configuration, `/instance/configuration`: the settings of the whole
  instance, for the instance's admins (`Apiary.Access.instance_admin?/1`), who reach it
  from the Qory Apiary menu's Instance settings; anyone else is answered as a path that
  does not exist (`ApiaryWeb.NotFound`). In the core edition it is the Instance level's one
  page, so it has no second column; an edition's sections come before it
  (`ApiaryWeb.Layouts.instance_sections/1`).

  Each line is a value the application reads, with where it comes from where that is not
  its field: the setting of the server's environment that set it, or the default, where
  that setting is not set (`config/runtime.exs` keeps each as it read it). They are the
  features (`Apiary.Features`, `QORY_FEATURES`; an opt-in feature only where it is on),
  with the `secrets` feature whether an integration may come from an address
  (`Apiary.Integrations.Source.url_sources?/0`, `INTEGRATION_URL_SOURCES`), how long the
  audit trail keeps an entry and its address, the grace period before a deleted workspace
  or organisation is purged, the invitations an organisation sends a day
  (`Apiary.InstanceConfig`), and whether and when the server prunes runs by their
  workspace's retention (`Apiary.Retention.Scheduler`, the application's configuration,
  which no setting of the environment changes).

  The audit trail's two periods, the grace period and the invitations a day are forms an
  instance admin saves after a recent sign-in (`Apiary.InstanceConfig.save/3`), each part
  with its Save, unless the environment sets the value, which wins and shows read only;
  the edition's parts (`c:ApiaryWeb.Edition.configuration_parts/1`) follow. The features,
  the integration sources and run pruning are read when the server starts, read only.

  The page asks for a recent sign-in, as Mail does (`ApiaryWeb.UserAuth`'s sudo mode): a
  shorter retention deletes what it no longer keeps. A save after the sign-in has grown
  old, a part of the edition's included (`{:configuration, :sudo}`), leads to the log-in
  page the same way. An edition's part that saved has the page show its toast
  (`{:configuration, {:saved, text}}`).
  """
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.{Access, Features, InstanceConfig}
  alias Apiary.Integrations.Source
  alias Apiary.Retention.Scheduler
  alias ApiaryWeb.InstanceLive.ConfigurationComponents
  alias ApiaryWeb.SettingsComponents

  # The parts with a form, by the name their hidden `part` field gives: nothing else is
  # saved.
  @parts %{"retention" => :retention, "deletion" => :deletion, "invitations" => :invitations}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:configuration}
    >
      <.settings_page section={:configuration} title={gettext("Configuration")}>
        <:subtitle>
          {gettext(
            "The settings of the whole instance. A setting with a field is changed here; a value set in the server's environment wins, and shows here read only. The others are read when Qory Apiary starts, from the server's environment or the application's configuration, as each says."
          )}
        </:subtitle>

        <SettingsComponents.part id="config-features" title={gettext("Features")}>
          <dl class="grid gap-4">
            <ConfigurationComponents.setting
              :for={feature <- @features}
              id={"config-feature-#{feature.name}"}
              label={feature.label}
              value={if feature.on, do: gettext("On"), else: gettext("Off")}
              mono_label
            >
              {feature.description}
            </ConfigurationComponents.setting>
          </dl>
          <p id="config-features-source" class="text-[12px] text-faint">
            <.rich text={@sources.features} />
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@secrets}
          id="config-integrations"
          title={gettext("Integrations")}
        >
          <dl class="grid gap-4">
            <ConfigurationComponents.setting
              id="config-url-sources"
              label={gettext("From an https address")}
              value={if @url_sources, do: gettext("Allowed"), else: gettext("Not allowed")}
              source={@sources.url_sources}
            >
              {if @url_sources,
                do:
                  gettext(
                    "An integration may be added from an https address of its description.json, as well as from a release on github.com, gitlab.com or codeberg.org."
                  ),
                else:
                  gettext(
                    "An integration is added only from a release on github.com, gitlab.com or codeberg.org."
                  )}
            </ConfigurationComponents.setting>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-retention" title={gettext("Retention")}>
          <.part_form part={:retention} form={@forms.retention}>
            <dl class="grid gap-4">
              <.config_setting
                id="config-audit-retention"
                key={:audit_retention_days}
                label={gettext("Audit log entries")}
                variable="AUDIT_RETENTION_DAYS"
                config={@config}
                form={@forms.retention}
              >
                {gettext(
                  "How long the audit log keeps an entry. Older entries are deleted once a day."
                )}
              </.config_setting>
              <.config_setting
                id="config-audit-address-retention"
                key={:audit_address_retention_days}
                label={gettext("IP addresses in the audit log")}
                variable="AUDIT_ADDRESS_RETENTION_DAYS"
                config={@config}
                form={@forms.retention}
              >
                {gettext(
                  "How long an audit log entry keeps the IP address and the browser or program it came from, never longer than the entries."
                )}
              </.config_setting>
              <ConfigurationComponents.setting
                id="config-run-pruning"
                label={gettext("Run pruning")}
                value={pruning(@pruning)}
                source={@sources.pruning}
              >
                {if @pruning,
                  do:
                    gettext(
                      "Qory Apiary prunes each workspace's runs as that workspace's retention says (Workspace settings › Runs)."
                    ),
                  else:
                    gettext(
                      "Qory Apiary does not prune runs automatically: a workspace's retention takes effect when the pruning job is run by hand."
                    )}
              </ConfigurationComponents.setting>
            </dl>
            <:note>
              {pgettext(
                "plain",
                "A change applies at the next daily job, at 02:40 UTC. A shorter period deletes or clears what it no longer keeps then; setting it longer again does not bring it back."
              )}
            </:note>
          </.part_form>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-deletion" title={gettext("Deletion")}>
          <.part_form part={:deletion} form={@forms.deletion}>
            <dl class="grid gap-4">
              <.config_setting
                id="config-grace"
                key={:deletion_grace_days}
                label={gettext("Grace period")}
                variable="DELETION_GRACE_DAYS"
                config={@config}
                form={@forms.deletion}
              >
                {gettext(
                  "How long a deleted workspace or organisation is kept, and its deletion can still be cancelled, before it is purged."
                )}
              </.config_setting>
            </dl>
            <:note>
              {pgettext(
                "plain",
                "A change applies to what is deleted after it; what is already deleted keeps its purge date."
              )}
            </:note>
          </.part_form>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-invitations" title={gettext("Invitations")}>
          <.part_form part={:invitations} form={@forms.invitations}>
            <dl class="grid gap-4">
              <.config_setting
                id="config-invitations-per-day"
                key={:invitations_per_day}
                label={gettext("Invitations a day")}
                variable="INVITATIONS_PER_DAY"
                config={@config}
                form={@forms.invitations}
              >
                {gettext("How many invitations an organisation sends in 24 hours.")}
              </.config_setting>
            </dl>
            <:note>{pgettext("plain", "A change applies at once.")}</:note>
          </.part_form>
        </SettingsComponents.part>

        <.live_component
          :for={{module, i} <- Enum.with_index(@edition_parts, 1)}
          module={module}
          id={"config-part-#{i}"}
          current_scope={@current_scope}
        />

        <p id="config-note" class="q-foot-note">
          {gettext(
            "To change a value without a field, whoever runs Qory Apiary changes the setting named beside it and starts it again."
          )}
        </p>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :part, :atom, required: true

  attr :form, :any,
    required: true,
    doc: "the part's form; nil where the environment sets every field"

  slot :inner_block, required: true, doc: "the part's rows"
  slot :note, required: true, doc: "when a change takes effect"

  # A part's rows, in its form with its Save where one of its settings has a field; only
  # the rows where the environment sets every one.
  defp part_form(%{form: nil} = assigns) do
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  defp part_form(assigns) do
    ~H"""
    <.form for={@form} id={"config-#{@part}-form"} phx-submit="save" class="q-form" novalidate>
      <input type="hidden" name="part" value={@part} />
      {render_slot(@inner_block)}
      <SettingsComponents.save id={"config-#{@part}-save"}>
        <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
          {gettext("Save")}
        </.button>
        <:note>{render_slot(@note)}</:note>
      </SettingsComponents.save>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :key, :atom, required: true
  attr :label, :string, required: true
  attr :variable, :string, required: true, doc: "the variable of the environment that sets it"
  attr :config, :map, required: true, doc: "what the page read of the settings (`config/1`)"
  attr :form, :any, required: true
  slot :inner_block, required: true

  # One setting of `Apiary.InstanceConfig`: its value, read only, with the variable that
  # sets it, where the environment does; else its field, which holds the saved value and
  # is empty where none is saved, with what empty gives.
  defp config_setting(assigns) do
    if assigns.config.env[assigns.key],
      do: env_setting(assigns),
      else: field_setting(assigns)
  end

  defp env_setting(assigns) do
    ~H"""
    <ConfigurationComponents.setting
      id={@id}
      label={@label}
      value={shown(@key, @config.values[@key])}
      source={ConfigurationComponents.env_line(@variable)}
    >
      {render_slot(@inner_block)}
    </ConfigurationComponents.setting>
    """
  end

  defp field_setting(assigns) do
    field = assigns.form[assigns.key]
    errors = Enum.map(field.errors, &translate_error/1)
    default = assigns.config.defaults[assigns.key]
    input_id = "#{assigns.id}-input"

    # The field's errors, then what empty gives.
    described_by =
      errors
      |> Enum.with_index()
      |> Enum.map(&error_id(assigns.id, &1))
      |> Enum.concat(["#{assigns.id}-hint"])
      |> Enum.join(" ")

    assigns =
      assign(assigns,
        field: field,
        errors: errors,
        input_id: input_id,
        described_by: described_by,
        placeholder: Integer.to_string(default),
        hint: gettext("Empty: %{default}.", default: shown(assigns.key, default))
      )

    ~H"""
    <ConfigurationComponents.setting
      id={@id}
      label={@label}
      for={@input_id}
      hint={@hint}
      errors={@errors}
    >
      <:field>
        <input
          type="text"
          inputmode="numeric"
          id={@input_id}
          name={@field.name}
          value={Phoenix.HTML.Form.normalize_value("text", @field.value)}
          placeholder={@placeholder}
          autocomplete="off"
          class={["input input-sm w-28", @errors != [] && "input-error"]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@described_by}
        />
        <span :if={@key != :invitations_per_day} id={"#{@id}-unit"} class="text-muted">
          {gettext("days")}
        </span>
      </:field>
      {render_slot(@inner_block)}
    </ConfigurationComponents.setting>
    """
  end

  defp error_id(id, {_message, 0}), do: "#{id}-error"
  defp error_id(id, {_message, i}), do: "#{id}-error-#{i + 1}"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if Access.instance_admin?(scope) do
      {:ok,
       socket
       |> assign(
         page_title:
           SettingsComponents.page_title(scope, :instance, [
             gettext("Configuration")
           ]),
         features: features(),
         # The Integrations part asks `on?(:secrets)`, of the instance.
         secrets: Features.on?(:secrets),
         url_sources: Source.url_sources?(),
         pruning: Scheduler.enabled?() && pruning_hour(),
         sources: sources(),
         edition_parts: ApiaryWeb.Edition.configuration_parts(scope),
         forms: %{}
       )
       |> load(Map.values(@parts))}
    else
      raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_event("save", %{"part" => name} = params, socket) when is_map_key(@parts, name) do
    part = Map.fetch!(@parts, name)

    attrs =
      case params["config"] do
        %{} = attrs -> attrs
        _none -> %{}
      end

    case InstanceConfig.save(socket.assigns.current_scope, part, attrs) do
      {:ok, _values} ->
        {:noreply, socket |> ConfigurationComponents.saved(saved(part)) |> load([part])}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, forms: Map.put(socket.assigns.forms, part, config_form(changeset)))}

      # The sign-in has grown old since the page opened: as the mount does.
      {:error, :sudo} ->
        {:noreply, sudo(socket)}

      # No longer an instance admin: the page itself is not found now.
      {:error, :forbidden} ->
        {:noreply, push_navigate(socket, to: ~p"/instance/configuration")}
    end
  end

  # A part the page does not have: nothing to save.
  def handle_event("save", _params, socket), do: {:noreply, socket}

  # An edition's part whose save found the sign-in grown old.
  @impl true
  def handle_info({:configuration, :sudo}, socket), do: {:noreply, sudo(socket)}

  # An edition's part that saved: its toast (`ConfigurationComponents.saved/2`).
  def handle_info({:configuration, {:saved, text}}, socket) when is_binary(text),
    do: {:noreply, put_flash(socket, :info, text)}

  defp sudo(socket) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp saved(:retention), do: gettext("Retention saved.")
  defp saved(:deletion), do: gettext("Grace period saved.")
  defp saved(:invitations), do: gettext("Invitations a day saved.")

  # What the page shows of the settings, read from the database now, as Mail's page reads
  # its settings, and the forms of `parts` afresh: each part's other forms stay as they
  # are, with what they hold.
  defp load(socket, parts) do
    config = config(InstanceConfig.load())

    forms =
      Enum.reduce(parts, socket.assigns.forms, fn part, forms ->
        Map.put(forms, part, part_form_of(part, config))
      end)

    assign(socket, config: config, forms: forms)
  end

  # The saved settings; the value of each; the environment's value of each, nil where the
  # variable is not set or is blank; and what an empty field gives, the value with that
  # setting not saved.
  defp config(stored) do
    %{
      stored: stored,
      values: InstanceConfig.values(stored),
      env: Map.new(InstanceConfig.keys(), &{&1, InstanceConfig.env(&1)}),
      defaults:
        Map.new(InstanceConfig.keys(), fn key ->
          {key, InstanceConfig.values(Map.put(stored, key, nil))[key]}
        end)
    }
  end

  # The form of a part: the saved value of each of its settings that the environment does
  # not set, empty where none is saved; nil where the environment sets every one.
  defp part_form_of(part, config) do
    case Enum.reject(InstanceConfig.fields(part), &config.env[&1]) do
      [] ->
        nil

      fields ->
        fields
        |> Map.new(&{Atom.to_string(&1), to_string(config.stored[&1])})
        |> config_form()
    end
  end

  defp config_form(source), do: to_form(source, as: "config")

  # A value as its row shows it: a number of days, or of invitations.
  defp shown(:invitations_per_day, n), do: Format.number(n)
  defp shown(_days, n), do: days(n)

  # The built features (`Features.built/0`), each on or off as the instance has it, and an
  # opt-in feature (`Features.opt_in/0`) only where it is on, in the order of
  # `Features.all/0`, by the name `QORY_FEATURES` takes, with what it covers where the
  # core knows it.
  defp features do
    enabled = Features.enabled()
    built = Features.built()
    opt_in = Features.opt_in()

    for feature <- Features.all(),
        feature in built or (feature in opt_in and feature in enabled) do
      %{
        name: feature,
        label: Atom.to_string(feature),
        on: feature in enabled,
        description: description(feature)
      }
    end
  end

  defp description(:observability),
    do:
      gettext(
        "Runs, their terminal log and timeline, the connections they made, and how long they are kept."
      )

  # As `Apiary.Policy.managed?/1` has it: no policy is served until the first rule or the
  # first mode set in the workspace, a target's included.
  defp description(:security),
    do:
      gettext(
        "The security policy, which Qory Apiary serves to a workspace's runs once it has a rule or a mode set."
      )

  defp description(:secrets),
    do: gettext("Stored secrets, variables and integrations, in each workspace's settings.")

  defp description(_feature), do: nil

  # Where each value read only at start comes from: the setting of the server's
  # environment, as `config/runtime.exs` read it, where whoever runs the server set it; the
  # default where it is not set, or set to a blank value, which every reader of these
  # settings takes for unset.
  # Pruning is the application's configuration, which no setting of the environment changes.
  defp sources do
    %{
      features: env_source("QORY_FEATURES", :features_setting),
      url_sources: env_source("INTEGRATION_URL_SOURCES", :integration_url_sources_setting),
      pruning:
        if(Keyword.take(scheduler_config(), [:enabled, :hour]) == [],
          do: gettext("The default: the application's configuration does not set it"),
          else: gettext("Set in the application's configuration")
        )
    }
  end

  # Set to a blank value is not unset: the default either way, said as it is.
  defp env_source(variable, key) do
    case Application.get_env(:apiary, key) do
      nil ->
        rich_gettext("The default: %{variable} is not set", variable: {:code, variable, "q-mono"})

      value ->
        if String.trim(value) == "",
          do:
            rich_gettext("The default: %{variable} is empty",
              variable: {:code, variable, "q-mono"}
            ),
          else: ConfigurationComponents.env_line(variable)
    end
  end

  # The hour of the night the pruning starts, UTC, as `Apiary.Retention.Scheduler` reads it
  # from the application's configuration: 3 when it names none. It prunes at a moment
  # within that hour, chosen at random.
  defp pruning_hour, do: Keyword.get(scheduler_config(), :hour, 3)

  defp scheduler_config, do: Application.get_env(:apiary, Scheduler, [])

  defp pruning(false), do: gettext("Off")

  defp pruning(hour),
    do: gettext("Every day, %{from}–%{to} UTC", from: clock(hour), to: clock(rem(hour + 1, 24)))

  defp clock(hour), do: String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00"

  defp days(n), do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))
end
