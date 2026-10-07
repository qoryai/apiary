defmodule ApiaryWeb.InstanceLive.Configuration do
  @moduledoc """
  Instance › Configuration, `/instance/configuration`: what whoever runs the server set
  for the whole instance, read only, for the instance's admins
  (`Apiary.Access.instance_admin?/1`); anyone else is answered as a path that does not
  exist (`ApiaryWeb.NotFound`). In the core edition it is the Instance level's one page,
  so it has no second column; an edition's sections come before it
  (`ApiaryWeb.Layouts.instance_sections/1`).

  Each line is a value the application already reads, as it read it when the server
  started, with where it comes from: the setting of the server's environment that set it,
  or the default, where that setting is not set (`config/runtime.exs` keeps each as it
  read it). They are the features
  (`Apiary.Features`, `QORY_FEATURES`), whether an integration may come from an address
  (`Apiary.Integrations.Source.url_sources?/0`, `INTEGRATION_URL_SOURCES`), how long the
  audit trail keeps an entry and its address (`Apiary.Audit`), the grace period before a
  deleted workspace or organisation is purged (`Apiary.Deletion.grace_days/0`), the
  invitations an organisation sends a day (`Apiary.Instance.invitations_per_day/0`), and
  whether and when the server prunes runs by their workspace's retention
  (`Apiary.Retention.Scheduler`, the application's configuration, which no setting of the
  environment changes). Nothing here changes them: the server reads them when it starts.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Audit, Deletion, Features, Instance}
  alias Apiary.Integrations.Source
  alias Apiary.Retention.Scheduler
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
      section={:configuration}
    >
      <.settings_page section={:configuration} title={gettext("Configuration")}>
        <:subtitle>
          {gettext(
            "What whoever runs this server set for the whole instance, or the default, as the server read it when it started. Nothing here changes it."
          )}
        </:subtitle>

        <SettingsComponents.part id="config-features" title={gettext("Features")}>
          <dl class="grid gap-4">
            <.setting
              :for={feature <- @features}
              id={"config-feature-#{feature.name}"}
              label={feature.label}
              value={if feature.on, do: gettext("On"), else: gettext("Off")}
              mono_label
            >
              {feature.description}
            </.setting>
          </dl>
          <p id="config-features-source" class="text-[12px] text-faint">
            <.rich text={@sources.features} />
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-integrations" title={gettext("Integrations")}>
          <dl class="grid gap-4">
            <.setting
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
            </.setting>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-retention" title={gettext("Retention")}>
          <dl class="grid gap-4">
            <.setting
              id="config-audit-retention"
              label={gettext("Audit log entries")}
              value={days(@audit_days)}
              source={@sources.audit}
            >
              {gettext("How long the audit log keeps an entry. Older entries are deleted once a day.")}
            </.setting>
            <.setting
              id="config-audit-address-retention"
              label={gettext("IP addresses in the audit log")}
              value={days(@address_days)}
              source={@sources.address}
            >
              {gettext(
                "How long an audit log entry keeps the IP address and the browser or program it came from, never longer than the entries."
              )}
            </.setting>
            <.setting
              id="config-run-pruning"
              label={gettext("Run pruning")}
              value={pruning(@pruning)}
              source={@sources.pruning}
            >
              {if @pruning,
                do:
                  gettext(
                    "The server prunes each workspace's runs as its own retention says (Workspace settings › Runs)."
                  ),
                else:
                  gettext(
                    "The server does not prune runs on its own: a workspace's retention takes effect when the pruning job is run by hand."
                  )}
            </.setting>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-deletion" title={gettext("Deletion")}>
          <dl class="grid gap-4">
            <.setting
              id="config-grace"
              label={gettext("Grace period")}
              value={days(@grace_days)}
              source={@sources.grace}
            >
              {gettext(
                "How long a deleted workspace or organisation is kept, and its deletion can still be cancelled, before it is purged."
              )}
            </.setting>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-invitations" title={gettext("Invitations")}>
          <dl class="grid gap-4">
            <.setting
              id="config-invitations-per-day"
              label={gettext("Invitations a day")}
              value={Format.number(@invitations)}
              source={@sources.invitations}
            >
              {gettext("How many invitations an organisation sends in 24 hours.")}
            </.setting>
          </dl>
        </SettingsComponents.part>

        <p id="config-note" class="q-foot-note">
          {gettext(
            "To change a value, whoever runs the server changes the setting named beside it and starts the server again."
          )}
        </p>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  attr :source, :any,
    default: nil,
    doc: "rich text: the setting the value comes from, or that it is the default"

  attr :mono_label, :boolean, default: false, doc: "the label is a name the setting takes"
  slot :inner_block, doc: "one sentence: what the value decides"

  # One value: what it is, its value, one sentence of what it decides, and where it comes
  # from: the setting that set it, or the default.
  defp setting(assigns) do
    ~H"""
    <div id={@id} class="grid gap-x-6 gap-y-1 text-[13px]/[20px] sm:grid-cols-[200px_minmax(0,1fr)]">
      <dt class={["text-muted", @mono_label && "q-mono"]}>{@label}</dt>
      <dd class="m-0 flex min-w-0 flex-col gap-0.5">
        <span id={"#{@id}-value"} class="font-medium">{@value}</span>
        <span :if={@inner_block != []} class="text-muted">{render_slot(@inner_block)}</span>
        <span :if={@source} id={"#{@id}-source"} class="text-[12px] text-faint">
          <.rich text={@source} />
        </span>
      </dd>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Access.instance_admin?(socket.assigns.current_scope) do
      {:ok,
       assign(socket,
         page_title:
           SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
             gettext("Configuration")
           ]),
         features: features(),
         url_sources: Source.url_sources?(),
         audit_days: Audit.retention_days(),
         address_days: Audit.address_retention_days(),
         pruning: Scheduler.enabled?() && pruning_hour(),
         grace_days: Deletion.grace_days(),
         invitations: Instance.invitations_per_day(),
         sources: sources()
       )}
    else
      raise ApiaryWeb.NotFound
    end
  end

  # The features built so far, each on or off as the instance has it, by the name
  # `QORY_FEATURES` takes, with what it covers where the core knows it.
  defp features do
    enabled = Features.enabled()

    for feature <- Features.built() do
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
        "The security policy, which Qory serves to a workspace's runs once it has a rule or a mode set."
      )

  defp description(_feature), do: nil

  # Where each value comes from: the setting of the server's environment, as
  # `config/runtime.exs` read it, where whoever runs the server set it; the default where
  # it is not set, or set to a blank value, which every reader of these settings takes for
  # unset.
  # Pruning is the application's configuration, which no setting of the environment changes.
  defp sources do
    %{
      features: env_source("QORY_FEATURES", :features_setting),
      url_sources: env_source("INTEGRATION_URL_SOURCES", :integration_url_sources_setting),
      audit: env_source("AUDIT_RETENTION_DAYS", :audit_retention_setting),
      address: env_source("AUDIT_ADDRESS_RETENTION_DAYS", :audit_address_retention_setting),
      grace: env_source("DELETION_GRACE_DAYS", :deletion_grace_setting),
      invitations: env_source("INVITATIONS_PER_DAY", :invitations_per_day_setting),
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
          else: rich_gettext("Set by %{variable}", variable: {:code, variable, "q-mono"})
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
