defmodule ApiaryWeb.InstanceLive.Configuration do
  @moduledoc """
  Instance › Configuration, `/instance/configuration`: what whoever runs the server set
  for the whole instance, read only, for the instance's admins
  (`Apiary.Access.instance_admin?/1`); anyone else is answered as a path that does not
  exist (`ApiaryWeb.NotFound`). In the core edition it is the Instance level's one page,
  so it has no second column; an edition's sections come before it
  (`ApiaryWeb.Layouts.instance_sections/1`).

  Each line is a value the application already reads, as it read it when the server
  started, with the setting of the server's environment it comes from where it has one:
  the features
  (`Apiary.Features`, `QORY_FEATURES`), whether an integration may come from an address
  (`Apiary.Integrations.Source.url_sources?/0`, `INTEGRATION_URL_SOURCES`), how long the
  audit trail keeps an entry and its address (`Apiary.Audit`), the grace period before a
  deleted workspace or organisation is purged (`Apiary.Deletion.grace_days/0`), the
  invitations an organisation sends a day (`Apiary.Instance.invitations_per_day/0`), and
  whether the server prunes runs by their workspace's retention
  (`Apiary.Retention.Scheduler.enabled?/0`, the application's configuration, which no
  setting of the environment changes). Nothing here changes them: the server reads them
  when it starts.
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
      <.settings_page
        heading={gettext("Instance")}
        section={:configuration}
        title={gettext("Configuration")}
      >
        <:subtitle>
          {gettext(
            "What whoever runs this server set for the whole instance, as the server read it when it started. Nothing here changes it."
          )}
        </:subtitle>

        <SettingsComponents.part id="config-features" title={gettext("Features")}>
          <dl class="grid gap-4">
            <.setting
              :for={feature <- @features}
              id={"config-feature-#{feature.name}"}
              label={feature.label}
              value={if feature.on, do: gettext("On"), else: gettext("Off")}
              variable="QORY_FEATURES"
              mono_label
            >
              {feature.description}
            </.setting>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part id="config-integrations" title={gettext("Integrations")}>
          <dl class="grid gap-4">
            <.setting
              id="config-url-sources"
              label={gettext("From an address")}
              value={if @url_sources, do: gettext("Allowed"), else: gettext("Not allowed")}
              variable="INTEGRATION_URL_SOURCES"
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
              variable="AUDIT_RETENTION_DAYS"
            >
              {gettext("How long the audit log keeps an entry. Older entries are deleted once a day.")}
            </.setting>
            <.setting
              id="config-audit-address-retention"
              label={gettext("Addresses in the audit log")}
              value={days(@address_days)}
              variable="AUDIT_ADDRESS_RETENTION_DAYS"
            >
              {gettext("How long an audit log entry keeps the address and the client it came from.")}
            </.setting>
            <.setting
              id="config-run-pruning"
              label={gettext("Pruning runs")}
              value={if @pruning, do: gettext("Once a day"), else: gettext("Off")}
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
              variable="DELETION_GRACE_DAYS"
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
              variable="INVITATIONS_PER_DAY"
            >
              {gettext("How many invitations an organisation sends in 24 hours.")}
            </.setting>
          </dl>
        </SettingsComponents.part>

        <p id="config-note" class="q-foot-note">
          {gettext(
            "To change a value, whoever runs the server changes the setting it is set by and starts the server again."
          )}
        </p>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :variable, :string, default: nil, doc: "the setting of the server's environment"
  attr :mono_label, :boolean, default: false, doc: "the label is a name the setting takes"
  slot :inner_block, doc: "one sentence: what the value decides"

  # One value: what it is, its value, one sentence of what it decides, and the setting of
  # the server's environment it comes from.
  defp setting(assigns) do
    ~H"""
    <div id={@id} class="grid gap-x-6 gap-y-1 text-[13px]/[20px] sm:grid-cols-[200px_minmax(0,1fr)]">
      <dt class={["text-muted", @mono_label && "q-mono"]}>{@label}</dt>
      <dd class="m-0 flex min-w-0 flex-col gap-0.5">
        <span id={"#{@id}-value"} class="font-medium">{@value}</span>
        <span :if={@inner_block != []} class="text-muted">{render_slot(@inner_block)}</span>
        <span :if={@variable} class="text-[12px] text-faint">
          {gettext("Set by")} <code class="q-mono">{@variable}</code>
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
         page_title: gettext("Configuration") <> " · " <> gettext("Instance"),
         features: features(),
         url_sources: Source.url_sources?(),
         audit_days: Audit.retention_days(),
         address_days: Audit.address_retention_days(),
         pruning: Scheduler.enabled?(),
         grace_days: Deletion.grace_days(),
         invitations: Instance.invitations_per_day()
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
        "Runs, their terminal log and timeline, the network access they made, and how long they are kept."
      )

  defp description(:security),
    do: gettext("The security policy, which each run receives with its run configuration.")

  defp description(_feature), do: nil

  defp days(n), do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))
end
