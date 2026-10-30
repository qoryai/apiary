defmodule ApiaryWeb.HostComponents do
  @moduledoc """
  The two read-only lists of hosts that no host rule decides.

  **Harness fetch** (`harness_fetches/1`), under the destinations on Network access: the
  hosts runs reached to fetch their harness (`Apiary.Runs.harness_fetches/3`), each with
  the source of the harness it belongs to. A row has no Allow, no Deny and no expander,
  only a lock whose hint says why. The rows are no destination of the page: the page's
  views, counts, facets and rule options never read them.

  **Allowed for every run** (`allowed_hosts/1`), on the Policy page: the hosts allowed
  for every run of the workspace, by group, each with its source and who requires it. A host that is an IP address shows as "Address hidden" to
  anyone but an instance admin.

  What Forager reported (a harness fetch's host) is untrusted: it is interpolated, never
  passed to `raw/1`.
  """
  use ApiaryWeb, :html

  alias Apiary.ExternalText

  attr :rows, :list, required: true, doc: "the `rows` of `Apiary.Runs.harness_fetches/3`"
  attr :total, :integer, required: true, doc: "its `total`: more than the rows when it cut them"

  def harness_fetches(assigns) do
    ~H"""
    <section
      :if={@rows != []}
      id="harness-fetches"
      class="q-psec mt-6"
      aria-labelledby="harness-fetches-h"
    >
      <div class="q-psec-h">
        <h2 id="harness-fetches-h">{gettext("Harness fetch")}</h2>
      </div>
      <p id="harness-fetches-line" class="q-psec-p">
        {pgettext(
          "plain",
          "Hosts that runs reached to fetch their harness, before the first session started. Host rules do not apply to these fetches."
        )}
      </p>
      <div
        class="q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
        tabindex="0"
        role="region"
        aria-label={gettext("Harness fetches of this workspace")}
      >
        <table class="table q-cxt q-cxt-ws">
          <thead>
            <tr>
              <th scope="col">{gettext("Host")}</th>
              <th scope="col">{gettext("Source")}</th>
              <th scope="col" class="q-num q-cx-runs">{gettext("Runs")}</th>
              <th scope="col" class="q-num q-from-lg">{gettext("Attempts")}</th>
              <th scope="col">{gettext("Allowed / denied")}</th>
              <th scope="col" class="q-cx-seen">{gettext("Last seen")}</th>
              <th scope="col" class="q-cx-acts">
                <span class="sr-only">{gettext("Rule actions")}</span>
              </th>
            </tr>
          </thead>
          <tbody id="harness-fetch-rows">
            <tr
              :for={row <- @rows}
              id={fetch_id(row.host)}
              class="q-row q-cxr"
              data-channel="stack"
            >
              <td class="q-cx-d">
                <span class="q-dest q-cx-t">
                  <span class="q-cx-h"><bdi>{shown(row.host)}</bdi></span>
                  <span id={fetch_id(row.host) <> "-stack"} class="q-cx-path">
                    {gettext("Harness fetch")}
                  </span>
                </span>
              </td>
              <td id={fetch_id(row.host) <> "-source"}>
                <span :for={source <- row.sources} class="block">{source_words(source)}</span>
              </td>
              <td class="q-num q-cx-runs">{Format.number(row.runs)}</td>
              <td class="q-num q-from-lg">{Format.number(row.attempts)}</td>
              <td class="q-cx-nw">
                <.split_counts allowed={row.allowed} denied={row.denied} />
              </td>
              <td class="q-meta q-cx-nw q-cx-seen"><.relative_time at={row.last_seen_at} /></td>
              <td class="q-cx-acts">
                <span class="q-acts-pair">
                  <.lock
                    id={fetch_id(row.host) <> "-lock"}
                    tip={pgettext("plain", "Host rules do not apply to a harness fetch.")}
                  />
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@total > length(@rows)} id="harness-fetches-cut" class="q-psec-note">
        {gettext("Showing %{shown} of %{total} hosts.",
          shown: Format.number(length(@rows)),
          total: Format.number(@total)
        )}
      </p>
    </section>
    """
  end

  attr :groups, :list, required: true, doc: "the groups of the workspace's required hosts"
  attr :target_required?, :boolean, required: true
  attr :admin?, :boolean, required: true, doc: "whether the reader is an instance admin"

  def allowed_hosts(assigns) do
    ~H"""
    <section
      :if={@groups != []}
      id="required-hosts"
      class="q-psec"
      aria-labelledby="required-hosts-h"
    >
      <div class="q-psec-h">
        <h2 id="required-hosts-h">{gettext("Allowed for every run")}</h2>
      </div>
      <p id="required-hosts-line" class="q-psec-p">
        {gettext("Qory Apiary allows these hosts for every run. Host rules do not remove them.")}
      </p>
      <div
        class="q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
        tabindex="0"
        role="region"
        aria-label={gettext("Hosts allowed for every run")}
      >
        <table class="table q-cxt">
          <thead>
            <tr>
              <th scope="col">{gettext("Host")}</th>
              <th scope="col">{gettext("Source")}</th>
              <th scope="col">{gettext("Required by")}</th>
              <th scope="col" class="q-cx-acts">
                <span class="sr-only">{gettext("Rule actions")}</span>
              </th>
            </tr>
          </thead>
          <tbody :for={group <- @groups} id={"required-hosts-#{group.key}"}>
            <tr class="q-row-group">
              <th scope="rowgroup" colspan="4" class="text-left">{group_title(group.key)}</th>
            </tr>
            <tr
              :for={{row, n} <- Enum.with_index(group.rows)}
              id={"required-host-#{group.key}-#{n}"}
              class="q-row q-cxr"
            >
              <td class="q-cx-d">
                <span class="q-dest q-cx-t">
                  <span class="q-cx-h">
                    <bdi :if={!hidden?(row.host, @admin?)}>{row.host}</bdi>
                    <span :if={hidden?(row.host, @admin?)} class="text-faint">
                      {gettext("Address hidden")}
                    </span>
                  </span>
                </span>
              </td>
              <td>
                <span class="block">{source_words(row.source)}</span>
                <span :if={group.key == :forge} class="block text-faint">
                  {gettext("To read and change the target")}
                </span>
              </td>
              <td>{required_by_words(row.required_by)}</td>
              <td class="q-cx-acts">
                <span class="q-acts-pair">
                  <.lock
                    id={"required-host-#{group.key}-#{n}-lock"}
                    tip={gettext("Host rules do not remove this host.")}
                  />
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p id="required-hosts-run" class="q-psec-note">
        {if @target_required?,
          do:
            gettext(
              "A run also reaches the hosts of its target's system, of the harness sources its target adds, and of the model provider it uses."
            ),
          else: gettext("A run also reaches the host of the model provider it uses.")}
      </p>
    </section>
    """
  end

  attr :allowed, :integer, required: true
  attr :denied, :integer, required: true

  defp split_counts(assigns) do
    ~H"""
    <span
      class="q-cx-split"
      title={
        gettext("%{allowed} allowed, %{denied} denied",
          allowed: Format.number(@allowed),
          denied: Format.number(@denied)
        )
      }
    >
      <span class={@allowed == 0 && "q-zero"}>{Format.number(@allowed)}</span><span class="q-cx-sl">/</span><span class={
        if(@denied > 0, do: "q-cx-bad", else: "q-zero")
      }>{Format.number(@denied)}</span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :tip, :string, required: true

  # A faint lock whose hint the keyboard reaches.
  defp lock(assigns) do
    ~H"""
    <span
      id={@id}
      class="q-act-lock tooltip tooltip-left"
      tabindex="0"
      role="img"
      aria-label={@tip}
      data-tip={@tip}
    >
      <.icon name="hero-lock-closed-micro" class="size-3.5" />
    </span>
    """
  end

  defp fetch_id(host), do: "hf-" <> Base.url_encode64(host, padding: false)

  defp shown(host), do: ExternalText.present(host) || ExternalText.marked(host)

  @doc """
  hidden?/2 is whether a host is not shown to the reader: an IP address, to anyone but an
  instance admin (`admin?`).
  """
  def hidden?(host, admin?),
    do: not admin? and (ip?(host) or Apiary.Policy.Grammar.ends_in_number?(host))

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  @doc "source_words/1 is the words of a host's source."
  def source_words(:qory), do: gettext("The Qory harness")

  def source_words({:repository, name}),
    do: gettext("The harness source %{source}", source: name)

  def source_words(:hidden), do: gettext("A hidden harness")
  def source_words(:pending), do: gettext("The harness is not read yet")
  def source_words(:failed), do: gettext("The harness could not be read")
  def source_words(:none), do: gettext("Not a harness source")
  def source_words(:unrecorded), do: gettext("Source not recorded")
  def source_words({:integration, name}), do: gettext("The integration %{name}", name: name)
  def source_words({:provider, name}), do: gettext("The model provider %{name}", name: name)
  def source_words(:instance), do: gettext("This Qory Apiary")
  def source_words(:registry), do: gettext("The image registry")
  def source_words({:adapter, name}), do: gettext("The adapter %{name}", name: name)

  defp required_by_words(:instance), do: gettext("The instance")
  defp required_by_words(:workspace), do: gettext("This workspace's choice")
  defp required_by_words(:organisation), do: gettext("The organisation's choice")

  defp group_title(:harness), do: gettext("Harness sources")
  defp group_title(:integrations), do: gettext("Integrations")
  defp group_title(:providers), do: gettext("Model providers")
  defp group_title(:registry), do: gettext("Registry and Qory Apiary")
  defp group_title(:forge), do: gettext("System of the target")
end
