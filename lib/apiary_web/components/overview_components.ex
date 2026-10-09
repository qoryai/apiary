defmodule ApiaryWeb.OverviewComponents do
  @moduledoc """
  The components of the workspace overview, each a level of its own look (`docs/ui.md`,
  Lists): the summary (the largest numbers on the page), then blocks, each one box with a
  band and rows or lines and nothing boxed inside it: To review, the fourteen-day
  chart, the active targets and Guard; and the empty workspace's one box.

  Every number here is a count the workspace already keeps: `runs` columns the projector
  folded, `access_keys` timestamps, `retention_runs` rows, the policy's mode and version.
  Nothing is inferred. Every component that renders inside a list takes its `id` from the
  caller, so a live update patches a row in place and never by index. Times tick in the
  browser under the `Ticker` hook, as everywhere.

  The policy's parts are the `security` feature's: the policy lines of `guard/1`, the
  attention items of kinds `:denied` (an allow is a rule), `:behind`, `:enforce` and
  `:unmanaged`. None of them asks for itself; the caller leaves them out where the feature
  is off, and what remains names, links to and offers nothing of the policy.
  """
  use Phoenix.Component
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText

  import ApiaryWeb.CoreComponents,
    only: [
      button: 1,
      code_block: 1,
      icon: 1,
      listening: 1,
      sparkline: 1,
      steps: 1
    ]

  import ApiaryWeb.RunComponents,
    only: [
      beat: 1,
      format_seconds: 1,
      given_title: 1,
      heard_at: 1,
      relative_time: 1,
      rule_panel: 1,
      short_id: 1,
      state_label: 1,
      target_name: 1,
      tool_mark: 1
    ]

  alias ApiaryWeb.Format
  alias Phoenix.LiveView.JS

  ## The summary

  @doc """
  The summary: four numbers, the largest type on the page, each a link to the list it
  counts: alive now, runs, runs that ended badly and denied attempts over the chart's
  days. `facts` is nil while the activity read is in flight; `quiet` is how many alive
  runs have gone quiet; `destinations` the count of denied destinations when it could be
  made, else nil.
  """
  attr :id, :string, default: "overview-strip"
  attr :alive, :integer, required: true
  attr :quiet, :integer, default: 0
  attr :facts, :any, required: true, doc: "nil while loading, else the 14-day totals"

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :destinations, :any, default: nil
  attr :days, :integer, default: 14

  attr :from, Date,
    default: nil,
    doc: "the first of the days counted, so a number leads to the list of what it counts"

  def summary(assigns) do
    assigns =
      assign(assigns,
        range:
          if(assigns.from,
            do: %{"from" => Date.to_iso8601(assigns.from)},
            else: %{"since" => "14d"}
          )
      )

    ~H"""
    <section
      id={@id}
      class="q-sum"
      aria-label={gettext("Summary")}
      aria-busy={to_string(is_nil(@facts))}
    >
      <div class="q-sum-in">
        <.link
          id={"#{@id}-alive"}
          navigate={
            ~p"/#{@scope.organisation}/#{@scope.workspace}/runs?#{%{"state" => "pending,running"}}"
          }
          class="q-sum-c"
          aria-label={
            ngettext(
              "%{number} run alive now: open them",
              "%{number} runs alive now: open them",
              @alive,
              number: Format.number(@alive)
            )
          }
        >
          <span class="q-sum-k">{gettext("Alive now")}</span>
          <span class="q-sum-v">{Format.number(@alive)}</span>
          <span class="q-sum-s">{alive_sub(@alive, @quiet)}</span>
        </.link>
        <.summary_cell
          id={"#{@id}-runs"}
          label={
            ngettext("Runs, %{number} day", "Runs, %{number} days", @days,
              number: Format.number(@days)
            )
          }
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs?#{@range}"}
          value={@facts && @facts.runs}
          sub={@facts && runs_sub(@facts)}
        />
        <.summary_cell
          id={"#{@id}-bad"}
          label={
            ngettext("Ended badly, %{number} day", "Ended badly, %{number} days", @days,
              number: Format.number(@days)
            )
          }
          navigate={
            ~p"/#{@scope.organisation}/#{@scope.workspace}/runs?#{Map.put(@range, "state", Enum.join(Apiary.Runs.Run.ended_badly_states(), ","))}"
          }
          value={@facts && @facts.ended_badly}
          sub={@facts && bad_sub(@facts)}
        />
        <.summary_cell
          id={"#{@id}-denied"}
          label={
            ngettext("Denied attempts, %{number} day", "Denied attempts, %{number} days", @days,
              number: Format.number(@days)
            )
          }
          navigate={
            ~p"/#{@scope.organisation}/#{@scope.workspace}/network?#{%{"decision" => "denied"}}"
          }
          short={
            ngettext("Denied, %{number} day", "Denied, %{number} days", @days,
              number: Format.number(@days)
            )
          }
          value={@facts && @facts.denied}
          sub={@facts && denied_sub(@facts, @destinations)}
        />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :short, :string, default: nil, doc: "the label where the strip is narrow"
  attr :navigate, :string, required: true
  attr :value, :any, required: true
  attr :sub, :any, required: true

  defp summary_cell(assigns) do
    ~H"""
    <.link :if={@value} id={@id} navigate={@navigate} class="q-sum-c">
      <span class={["q-sum-k", @short && "q-sum-long"]}>{@label}</span>
      <span :if={@short} class="q-sum-k q-sum-short">{@short}</span>
      <span class="q-sum-v">{Format.number(@value)}</span>
      <span class="q-sum-s">{@sub}</span>
    </.link>
    <div :if={is_nil(@value)} class="q-sum-c" aria-hidden="true">
      <span class="q-sum-k">{@short || @label}</span>
      <span class="skeleton q-skel-v"></span>
      <span class="skeleton q-skel-line w-3/4"></span>
    </div>
    """
  end

  defp alive_sub(0, _quiet), do: gettext("none")

  defp alive_sub(_alive, quiet) when quiet > 0,
    do:
      ngettext("%{number} gone quiet", "%{number} gone quiet", quiet,
        number: Format.number(quiet)
      )

  defp alive_sub(_alive, _quiet), do: gettext("starting or running")

  defp runs_sub(%{runs: 0}), do: gettext("none")

  defp runs_sub(facts),
    do: gettext("%{number} ended well", number: Format.number(facts.ended_well))

  defp bad_sub(%{runs: 0}), do: gettext("none")

  defp bad_sub(facts),
    do:
      gettext("%{percent}% of the runs",
        percent: Format.number(round(facts.ended_badly / facts.runs * 100))
      )

  defp denied_sub(%{denied: 0}, _destinations), do: gettext("none")

  defp denied_sub(_facts, destinations) when is_integer(destinations) and destinations > 0 do
    ngettext("to %{number} destination", "to %{number} destinations", destinations,
      number: Format.number(destinations)
    )
  end

  defp denied_sub(_facts, _destinations), do: ""

  @doc "A sum of dollars: two decimals, four when the sum is under a cent."
  def cost_text(%Decimal{} = cost) do
    if Decimal.compare(cost, Decimal.new("0.01")) == :lt and Decimal.compare(cost, 0) == :gt,
      do: "$" <> Format.number(cost, digits: 4),
      else: "$" <> Format.number(cost, digits: 2)
  end

  def cost_text(_cost), do: gettext("n/a")

  ## To review

  @doc """
  The list of acts: one line an item, its mark, its subject (the only strong text), where
  it is, the reason in a few words, when, and the one act that settles it. `items` is
  ordered and bounded by the caller; an empty list renders nothing at all: when there is
  nothing to do the block is absent. `shared` is the target paths on more than one
  system, whose system is shown. A denied destination's Allow opens its panel
  (`RunComponents.rule_panel/1`, the page's `panel`) inside the item, under its subject.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :count, :integer, required: true, doc: "the items not yet resolved, shown and beyond"
  attr :more, :map, default: nil, doc: "%{count:, navigate:, title:}, and `label:`, what it says"
  attr :shared, :any, default: MapSet.new()

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :can_set_mode?, :boolean, default: false
  attr :now, :any, required: true

  attr :panel, :map,
    default: nil,
    doc: "the page's open panel of an item's Allow (`RunComponents.rule_panel/1`), by `item_id`"

  def attention(assigns) do
    ~H"""
    <section :if={@items != []} id={@id} class="q-blk q-att" aria-labelledby={"#{@id}-h"}>
      <div class="q-band">
        <h2 id={"#{@id}-h"}>{gettext("To review")}</h2>
        <span id={"#{@id}-n"} class="q-band-n">{Format.number(@count)}</span>
      </div>
      <ul
        id={"#{@id}-list"}
        class="q-rows"
        aria-label={
          ngettext("%{number} item to review", "%{number} items to review", @count,
            number: Format.number(@count)
          )
        }
      >
        <.attention_item
          :for={item <- @items}
          scope={@scope}
          item={item}
          shared={@shared}
          can_set_mode?={@can_set_mode?}
          now={@now}
          panel={@panel && @panel.item_id == item.id && @panel}
        />
      </ul>
      <.link
        :if={@more}
        id={"#{@id}-more"}
        navigate={@more.navigate}
        class="q-more"
        title={@more.title}
      >
        {@more[:label] ||
          ngettext("and %{number} more", "and %{number} more", @more.count,
            number: Format.number(@more.count)
          )}
        <.icon name="hero-arrow-right-micro" class="size-3.5" />
      </.link>
    </section>
    """
  end

  attr :scope, :map, required: true
  attr :item, :map, required: true
  attr :shared, :any, required: true
  attr :can_set_mode?, :boolean, required: true
  attr :now, :any, required: true
  attr :panel, :any, default: nil

  defp attention_item(assigns) do
    ~H"""
    <li
      id={@item.id}
      class={["q-ar", @item.resolved && "q-resolved", @item.arrived && "q-arrived"]}
      data-kind={@item.kind}
    >
      <.attention_mark item={@item} />
      <span class="q-ar-subj"><.attention_subject scope={@scope} item={@item} /></span>
      <span class="q-ar-where"><.attention_where item={@item} shared={@shared} /></span>
      <span class="q-ar-why" title={reason_title(@item, @can_set_mode?)}>
        <%= if @item.resolved && @item.resolved[:what] do %>
          {@item.resolved.what}
        <% else %>
          <.attention_reason item={@item} now={@now} />
        <% end %>
      </span>
      <span class="q-ar-when"><.attention_when item={@item} /></span>
      <span class="q-ar-act">
        <%= if @item.resolved do %>
          <span :if={@item.resolved[:done]} class="q-done" id={"#{@item.id}-done"} tabindex="-1">
            <.icon name="hero-check-micro" class="size-3" />{@item.resolved.done}
          </span>
        <% else %>
          <.attention_act
            scope={@scope}
            item={@item}
            shared={@shared}
            can_set_mode?={@can_set_mode?}
          />
        <% end %>
      </span>
      <div :if={@panel && !@item.resolved} id={"#{@item.id}-panel"} class="q-ar-panel">
        <.rule_panel panel={@panel} />
      </div>
    </li>
    """
  end

  attr :item, :map, required: true

  defp attention_mark(%{item: %{resolved: %{mark: mark}}} = assigns) when not is_nil(mark) do
    ~H"""
    <span :if={@item.resolved.mark == :allowed} class="q-amk q-mark-ok" title={gettext("Allowed")}>
      <.icon name="hero-check-micro" class="size-3.5" /><span class="sr-only">{gettext("Allowed")}</span>
    </span>
    <span
      :if={@item.resolved.mark == :resolved}
      class="q-amk q-mark-faint"
      title={gettext("Resolved")}
    >
      <.icon name="hero-check-micro" class="size-3.5" /><span class="sr-only">{gettext("Resolved")}</span>
    </span>
    """
  end

  defp attention_mark(assigns) do
    assigns = assign(assigns, mark: mark(assigns.item))

    ~H"""
    <span class={["q-amk", "q-amk-#{@mark.tone}"]} title={@mark.word}>
      <.icon :if={@mark.icon} name={@mark.icon} class="size-3.5" />
      <span class="sr-only">{@mark.word}</span>
    </span>
    """
  end

  # The one mark of a row, the only colour on it: red for a denial, amber for a run that
  # needs a look, grey for the policy and a key.
  defp mark(%{kind: :denied, locked: locked}) when is_binary(locked),
    do: %{tone: "plain", icon: "hero-lock-closed-micro", word: gettext("Locked")}

  defp mark(%{kind: :denied, above: above, level: %{name: name}}) when is_binary(above),
    do: %{
      tone: "plain",
      icon: "hero-lock-closed-micro",
      word: gettext("Decided by %{name}'s policy", name: name)
    }

  defp mark(%{kind: :denied}),
    do: %{tone: "denied", icon: "hero-no-symbol-micro", word: gettext("Not allowed")}

  defp mark(%{kind: :quiet}), do: %{tone: "quiet", icon: nil, word: gettext("Quiet")}
  defp mark(%{kind: :lost}), do: %{tone: "lost", icon: nil, word: gettext("Lost")}

  defp mark(%{kind: :behind}),
    do: %{
      tone: "warn",
      icon: "hero-exclamation-triangle-micro",
      word: gettext("Behind the policy in force")
    }

  defp mark(%{kind: :enforce}),
    do: %{tone: "plain", icon: "hero-shield-exclamation-micro", word: gettext("Policy")}

  defp mark(%{kind: :unmanaged}),
    do: %{tone: "plain", icon: "hero-shield-check-micro", word: gettext("Policy")}

  defp mark(%{kind: :idle_key}),
    do: %{tone: "faint", icon: "hero-key-micro", word: gettext("Access key")}

  attr :scope, :map, required: true
  attr :item, :map, required: true

  # A denied destination of a tool's host is a denied request to that tool: it leads with
  # the tool, then the path, then the host, as the list of what enforce would start
  # denying names it (`Apiary.Policy.denied_destinations/2`).
  defp attention_subject(%{item: %{kind: :denied, tool: tool}} = assigns) when is_binary(tool) do
    ~H"""
    <span class="q-host q-dest-tool q-ar-t q-mono" title={destination_title(@item)}>
      <.tool_mark name={@item.tool} /><span
        :if={@item.path != ""}
        class="q-path"
      >{@item.path}</span><span class="q-port">{@item.host}:{@item.port}</span>
    </span>
    """
  end

  defp attention_subject(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <span class="q-host q-ar-t q-mono" title={destination_title(@item)}>
      {@item.host}<span class="q-port">:{@item.port}</span><span
        :if={@item.held && @item.path != ""}
        class="q-path"
      >{@item.path}</span>
    </span>
    """
  end

  defp attention_subject(%{item: %{kind: kind}} = assigns)
       when kind in [:quiet, :lost, :behind] do
    ~H"""
    <.link
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@item.run.run_id}"}
      class="q-ar-t"
      title={row_title(@item.run)}
    >
      <bdi :if={given_title(@item.run)}>{given_title(@item.run)}</bdi>
      {if !given_title(@item.run), do: row_title(@item.run)}
    </.link>
    <span class="q-ar-id">{short_id(@item.run.run_id)}</span>
    """
  end

  defp attention_subject(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <span class="q-ar-t">
      <.rich text={
        rich_gettext("%{observe} is the workspace's default",
          observe: {:term, gettext("Observe"), mode_tip()}
        )
      } />
    </span>
    """
  end

  defp attention_subject(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    <span class="q-ar-t">{gettext("Qory Apiary serves no policy yet")}</span>
    """
  end

  defp attention_subject(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <span class="q-ar-t q-mono" title={@item.key.label}>{@item.key.label}</span>
    <span class="q-ar-id">{@item.key.key_id}</span>
    """
  end

  attr :item, :map, required: true
  attr :shared, :any, required: true

  defp attention_where(%{item: %{kind: :denied, targets: [target]}} = assigns) do
    assigns = assign(assigns, :target, target)

    ~H"""
    <.target_name system={@target.system} path={@target.path} shared={@shared} />
    """
  end

  defp attention_where(%{item: %{kind: :denied, targets: []}} = assigns) do
    ~H"""
    <span class="q-faint">{gettext("no target")}</span>
    """
  end

  defp attention_where(%{item: %{kind: :denied, targets: targets}} = assigns) do
    assigns = assign(assigns, :n, length(targets))

    ~H"""
    {ngettext("%{number} target", "%{number} targets", @n, number: Format.number(@n))}
    """
  end

  defp attention_where(%{item: %{kind: kind, run: run}} = assigns)
       when kind in [:quiet, :lost, :behind] do
    assigns = assign(assigns, :run, run)

    ~H"""
    <.target_name
      :if={@run.target_system && @run.target_path}
      system={@run.target_system}
      path={@run.target_path}
      shared={@shared}
    />
    <span :if={!(@run.target_system && @run.target_path)} class="q-faint">
      {gettext("no target")}
    </span>
    """
  end

  defp attention_where(%{item: %{kind: kind}} = assigns) when kind in [:enforce, :unmanaged] do
    ~H"""
    {gettext("Policy")}
    """
  end

  defp attention_where(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    {@item.key.node.name}
    """
  end

  attr :item, :map, required: true
  attr :now, :any, required: true

  defp attention_reason(%{item: %{kind: :denied, locked: locked}} = assigns)
       when is_binary(locked) do
    ~H"""
    {gettext("Denied by a locked rule")}
    """
  end

  defp attention_reason(%{item: %{kind: :denied, above: above, level: %{}}} = assigns)
       when is_binary(above) do
    ~H"""
    {gettext("Denied by %{name}'s policy", name: @item.level.name)}
    """
  end

  defp attention_reason(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    {gettext("Denied %{times} in %{runs}", times: times(@item.denied), runs: runs_count(@item.runs))}
    """
  end

  defp attention_reason(%{item: %{kind: :quiet}} = assigns) do
    ~H"""
    <.rich text={
      rich_gettext("No heartbeat for %{since}",
        since: since(%{__changed__: nil, at: heard_at(@item.run)})
      )
    } />
    """
  end

  defp attention_reason(%{item: %{kind: :lost}} = assigns) do
    ~H"""
    {lost_words(@item.run)}
    """
  end

  defp attention_reason(%{item: %{kind: :behind}} = assigns) do
    ~H"""
    <.rich text={
      rich_gettext("On %{reported}; %{in_force} in force",
        reported: version_word(%{__changed__: nil, version: @item.reported}),
        in_force: version_word(%{__changed__: nil, version: @item.in_force})
      )
    } />
    """
  end

  defp attention_reason(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <%= cond do %>
      <% @item.uncovered == 0 -> %>
        {gettext("Enforce would deny nothing today")}
      <% is_integer(@item.uncovered) -> %>
        {ngettext(
          "Enforce would deny %{number} destination",
          "Enforce would deny %{number} destinations",
          @item.uncovered,
          number: Format.number(@item.uncovered)
        )}
      <% true -> %>
        {gettext("What enforce would deny is not counted")}
    <% end %>
    """
  end

  defp attention_reason(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    {ngettext(
      "%{number} run under the machines' policies",
      "%{number} runs under the machines' policies",
      @item.runs,
      number: Format.number(@item.runs)
    )}
    """
  end

  defp attention_reason(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <%= if @item.key.last_used_at do %>
      {gettext("Not seen for %{days}", days: days(@item.days))}
    <% else %>
      {gettext("Never used in %{days}", days: days(@item.days))}
    <% end %>
    """
  end

  # The longer sentence behind a reason, on hover: what a reader needs to decide.
  defp reason_title(%{resolved: resolved}, _can) when not is_nil(resolved), do: nil

  defp reason_title(%{kind: :denied, locked: locked}, _can) when is_binary(locked),
    do:
      gettext("A locked workspace rule denies %{rule}. Only an owner can change it.",
        rule: locked
      )

  defp reason_title(%{kind: :denied, above: above, level: %{name: name}}, _can)
       when is_binary(above),
       do:
         gettext("%{name}'s policy denies %{rule}; nothing in this workspace allows it.",
           name: name,
           rule: above
         )

  defp reason_title(%{kind: :denied, elsewhere: %{name: name}}, _can),
    do: gettext("Only %{name}'s policy allows a host here", name: name)

  defp reason_title(%{kind: :quiet, run: run}, _can) do
    interval = beat(run)

    gettext(
      "Heartbeats are due every %{interval}; after %{silence} of silence it is marked lost.",
      interval: format_seconds(interval),
      silence: format_seconds(interval * 3)
    )
  end

  defp reason_title(%{kind: :lost, run: run}, _can), do: lost_tip(run)

  defp reason_title(%{kind: :behind}, _can),
    do: gettext("A run reloads the policy at its next heartbeat.")

  defp reason_title(%{kind: :enforce}, false),
    do: gettext("Only an owner or an admin sets a mode.")

  defp reason_title(%{kind: :enforce}, true), do: mode_tip()

  defp reason_title(%{kind: :unmanaged}, _can),
    do:
      gettext(
        "The first rule you add, or a mode you set, puts the runs under the workspace's policy."
      )

  defp reason_title(%{kind: :idle_key}, _can),
    do: gettext("A key nobody uses is a key to revoke.")

  defp reason_title(_item, _can), do: nil

  attr :item, :map, required: true

  defp attention_when(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <.relative_time at={@item.last_seen_at} />
    """
  end

  defp attention_when(%{item: %{kind: kind}} = assigns) when kind in [:quiet, :lost, :behind] do
    ~H"""
    <.relative_time at={@item.at || @item.run.started_at || @item.run.inserted_at} />
    """
  end

  defp attention_when(%{item: %{kind: :idle_key, key: key}} = assigns) do
    assigns = assign(assigns, :at, key.last_used_at || key.received_at || key.inserted_at)

    ~H"""
    <span class="tabular-nums">{Format.day(@at)}</span>
    """
  end

  defp attention_when(assigns), do: ~H""

  attr :scope, :map, required: true
  attr :item, :map, required: true
  attr :shared, :any, default: MapSet.new()
  attr :can_set_mode?, :boolean, required: true

  defp attention_act(%{item: %{kind: :denied, locked: locked}} = assigns)
       when is_binary(locked) do
    ~H"""
    <.link
      id={"#{@item.id}-rule"}
      navigate={ApiaryWeb.ConnectionLive.Rules.rule_path(@scope, nil, @item.locked)}
      class="q-act"
    >
      {gettext("Open the rule")}
    </.link>
    """
  end

  # A destination the level above decides, by a deny of its own or because it allows only
  # its own hosts: no allow written here would be in force. The way to its page for one who
  # may change it there, and a lock with the reason for the rest, as Network access does.
  defp attention_act(%{item: %{kind: :denied, above: above, level: %{} = level}} = assigns)
       when is_binary(above) do
    assigns =
      assign(assigns,
        link: level.link,
        tip: gettext("Decided by %{name}'s policy", name: level.name)
      )

    ~H"""
    <.link
      :if={@link}
      id={"#{@item.id}-rule"}
      navigate={@link.path <> "?" <> URI.encode_query(%{"rule" => @item.above})}
      class="q-act"
    >
      {gettext("Open the rule")}
    </.link>
    <span :if={!@link} id={"#{@item.id}-act"} class="q-act-lock" title={@tip}>
      <.icon name="hero-lock-closed-micro" class="size-3.5" /><span class="sr-only">{@tip}</span>
    </span>
    """
  end

  defp attention_act(%{item: %{kind: :denied, elsewhere: %{} = level}} = assigns) do
    assigns =
      assign(assigns,
        level: level,
        tip: gettext("Only %{name}'s policy allows a host here", name: level.name)
      )

    ~H"""
    <.link
      :if={@level.link && @level.link.can_change}
      id={"#{@item.id}-act"}
      navigate={
        @level.link.path <>
          "?" <>
          URI.encode_query(%{
            "allow" => @item.host,
            "back" => ~p"/#{@scope.organisation}/#{@scope.workspace}"
          })
      }
      class="q-act"
      title={@tip}
      aria-label={gettext("Allow %{host} in %{name}'s policy", host: @item.host, name: @level.name)}
    >
      {gettext("Allow in %{name}'s policy", name: @level.name)}
    </.link>
    <span
      :if={!(@level.link && @level.link.can_change)}
      id={"#{@item.id}-act"}
      class="q-act-lock"
      title={@tip}
    >
      <.icon name="hero-lock-closed-micro" class="size-3.5" /><span class="sr-only">{@tip}</span>
    </span>
    """
  end

  defp attention_act(%{item: %{kind: :denied, targets: [target]}} = assigns) do
    assigns = assign(assigns, :target, target)

    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="q-act"
      aria-label={
        gettext("Allow %{host} for %{target}",
          host: @item.host,
          target: ApiaryWeb.TargetComponents.target_label(@target.system, @target.path, @shared)
        )
      }
      aria-expanded={to_string(@item[:expanded] == true)}
      aria-controls={"#{@item.id}-panel"}
      phx-click={JS.push("rule_open", value: %{id: @item.id, level: "target"})}
    >
      {gettext("Allow here")}
    </button>
    """
  end

  defp attention_act(%{item: %{kind: :denied, targets: []}} = assigns) do
    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="q-act"
      aria-label={gettext("Allow %{host} for the workspace", host: @item.host)}
      aria-expanded={to_string(@item[:expanded] == true)}
      aria-controls={"#{@item.id}-panel"}
      phx-click={JS.push("rule_open", value: %{id: @item.id, level: "workspace"})}
    >
      {gettext("Allow")}
    </button>
    """
  end

  defp attention_act(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="q-act"
      aria-label={gettext("Allow %{host}, choose a scope", host: @item.host)}
      aria-expanded={to_string(@item[:expanded] == true)}
      aria-controls={"#{@item.id}-panel"}
      phx-click={JS.push("rule_open", value: %{id: @item.id, level: "choose"})}
    >
      {gettext("Allow")}
    </button>
    """
  end

  defp attention_act(%{item: %{kind: :lost}} = assigns) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@item.run.run_id}"}
      class="q-act"
      aria-label={gettext("Open %{run}", run: row_title(@item.run))}
    >
      {gettext("Open")}
    </.link>
    """
  end

  defp attention_act(%{item: %{kind: :behind, compare: compare}} = assigns)
       when is_binary(compare) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={@item.compare}
      class="q-act"
      aria-label={gettext("What changed for %{run}", run: row_title(@item.run))}
    >
      {gettext("What changed")}
    </.link>
    """
  end

  defp attention_act(%{item: %{kind: kind}} = assigns) when kind in [:quiet, :behind] do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@item.run.run_id}"}
      class="q-act"
      aria-label={gettext("Open %{run}", run: row_title(@item.run))}
    >
      {gettext("Open")}
    </.link>
    """
  end

  defp attention_act(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <%= cond do %>
      <% !@can_set_mode? -> %>
        <.link
          id={"#{@item.id}-act"}
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy"}
          class="q-act"
        >
          {gettext("Open policy")}
        </.link>
      <% @item.uncovered == 0 -> %>
        <.link
          id={"#{@item.id}-act"}
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy?confirm=enforce"}
          class="q-act"
        >
          {gettext("Set to enforce")}
        </.link>
      <% true -> %>
        <.link
          id={"#{@item.id}-act"}
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy"}
          class="q-act"
        >
          {gettext("Review")}
        </.link>
    <% end %>
    """
  end

  defp attention_act(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy"}
      class="q-act"
    >
      {gettext("Open policy")}
    </.link>
    """
  end

  defp attention_act(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={
        ~p"/#{@scope.organisation}/#{@scope.workspace}/nodes/#{@item.key.node.public_id}/access-key/keys/#{@item.key.key_id}/revoke"
      }
      class="q-act"
      aria-label={gettext("Revoke %{key}", key: @item.key.label)}
    >
      {gettext("Revoke")}
    </.link>
    """
  end

  attr :version, :any, required: true

  defp version_word(%{version: %{n: _}} = assigns) do
    ~H"""
    <.link :if={@version[:path]} navigate={@version.path} class="q-ver">v{@version.n}</.link>
    <span :if={!@version[:path]} class="q-ver q-ver-plain">v{@version.n}</span>
    """
  end

  defp version_word(assigns) do
    ~H"""
    <span class="text-faint">{gettext("another configuration")}</span>
    """
  end

  attr :at, :any, required: true

  # Seconds since a moment, ticking in the browser on the server's clock.
  defp since(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <time
      data-tick="seconds"
      data-since={iso(@at)}
      data-now={iso(@now)}
      aria-live="off"
      class="tabular-nums"
    >{format_seconds(max(DateTime.diff(@now, @at, :second), 0))}</time>
    """
  end

  defp destination_title(%{tool: tool, host: host, port: port, path: path})
       when is_binary(tool),
       do:
         gettext("%{destination}, a host the tool %{tool} serves",
           destination: "#{host}:#{port}#{path}",
           tool: tool
         )

  defp destination_title(%{host: host, port: port, path: path}), do: "#{host}:#{port}#{path}"

  # A run Apiary marked lost when nothing was heard, which a heartbeat still revives, or one
  # whose exit said it was lost (`Apiary.Runs.Fold`): the session stopped responding, or the
  # run's end was never recorded. Only the second has an exit time.
  defp lost_words(%{exited_at: nil}), do: gettext("Lost, never posted its exit")
  defp lost_words(%{reason: "session_lost"}), do: gettext("Lost, stopped responding")
  defp lost_words(_run), do: gettext("Lost, end not recorded")

  defp lost_tip(%{exited_at: nil}),
    do:
      gettext(
        "Nothing was heard for three heartbeat intervals. The run may still be going; the record is not."
      )

  defp lost_tip(_run), do: gettext("The run's end was not recorded; how it went is not known.")

  defp mode_tip,
    do:
      gettext(
        "Enforce: a connection no rule allows is denied. Observe: it is let through and recorded. A deny rule holds in either mode."
      )

  defp times(n), do: ngettext("once", "%{number} times", n, number: Format.number(n))

  defp runs_count(n), do: ngettext("%{number} run", "%{number} runs", n, number: Format.number(n))

  defp days(n), do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

  @doc """
  The title a run gave (`ApiaryWeb.RunComponents.given_title/1`), else its command line,
  else its short id: what a row calls it.
  """
  def row_title(run), do: given_title(run) || command_title(run)

  defp command_title(%{command: command, args: args}) when is_binary(command) do
    line = Enum.join([command | args || []], " ")
    if String.length(line) > 40, do: String.slice(line, 0, 39) <> "…", else: line
  end

  defp command_title(%{run_id: run_id}), do: short_id(run_id)

  ## Active targets

  @doc """
  The targets with the most runs over the chart's days, one line each: the target (the
  title), its last run as a dot and when, with a word only when it is running or ended
  badly, its runs a day as a sparkline and their count, and its denied attempts. `rows`
  is nil while the read is in flight; `quiet_ids` are the alive runs gone quiet.
  """
  attr :id, :string, default: "overview-targets"

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :rows, :any, required: true, doc: "nil while loading"
  attr :targets, :integer, default: 0, doc: "how many targets the workspace has"
  attr :quiet_ids, :any, default: MapSet.new()
  attr :days, :integer, default: 14

  def active_targets(assigns) do
    ~H"""
    <section
      id={@id}
      class="q-blk q-ov-rep"
      aria-labelledby={"#{@id}-h"}
      aria-busy={to_string(is_nil(@rows))}
    >
      <div class="q-band">
        <h2 id={"#{@id}-h"}>{gettext("Active targets")}</h2>
        <span :if={@rows} class="q-band-n">{Format.number(length(@rows))}</span>
        <span class="q-band-hint">
          {ngettext("the most runs in %{number} day", "the most runs in %{number} days", @days,
            number: Format.number(@days)
          )}
        </span>
      </div>
      <ul :if={is_nil(@rows)} class="q-rows" aria-hidden="true">
        <li :for={n <- 1..4} class="q-rr">
          <span class={["skeleton q-skel-line", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
          <span class="skeleton q-skel-line w-24"></span>
          <span class="skeleton q-skel-line w-24"></span>
          <span></span>
        </li>
      </ul>
      <p :if={@rows == []} id={"#{@id}-none"} class="q-blk-none">
        {ngettext(
          "No run named a target in the last %{number} day.",
          "No run named a target in the last %{number} days.",
          @days,
          number: Format.number(@days)
        )}
      </p>
      <ul :if={@rows not in [nil, []]} id={"#{@id}-list"} class="q-rows">
        <li :for={row <- @rows} id={"active-#{row.id}"}>
          <.link
            navigate={
              ApiaryWeb.TargetComponents.target_path(@scope, row.system, row.path, [], row.shared?)
            }
            class="q-rr"
          >
            <span class="q-rr-p">
              <.target_name
                system={row.system}
                path={row.path}
                shared={if row.shared?, do: MapSet.new([row.path]), else: MapSet.new()}
              />
            </span>
            <span class="q-rr-last">
              <.last_run
                :if={row.last}
                run={row.last}
                quiet={MapSet.member?(@quiet_ids, row.last.id)}
              />
            </span>
            <span class="q-rr-sp">
              <.sparkline values={row.days} />
              <span class="q-rr-n">
                {ngettext("%{number} run", "%{number} runs", row.runs,
                  number: Format.number(row.runs)
                )}
              </span>
            </span>
            <span class="q-rr-den">
              <span :if={row.denied > 0} class="inline-flex items-center gap-1">
                <.icon name="hero-no-symbol-micro" class="size-3 text-error" />
                {ngettext("%{number} denied", "%{number} denied", row.denied,
                  number: Format.number(row.denied)
                )}
              </span>
            </span>
          </.link>
        </li>
      </ul>
      <.link
        id={"#{@id}-all"}
        navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/targets"}
        class="q-more"
      >
        {ngettext("All %{number} target", "All %{number} targets", @targets,
          number: Format.number(@targets)
        )}
        <.icon name="hero-arrow-right-micro" class="size-3.5" />
      </.link>
    </section>
    """
  end

  @doc """
  A run's state as a dot, with its word only when the run needs a look (running, ended
  badly) or was cancelled, grey; a run that completed is its dot, and a screen reader hears
  the word. Then when it started.
  """
  attr :run, :map, required: true
  attr :quiet, :boolean, default: false

  def last_run(assigns) do
    assigns =
      assign(assigns,
        tone: if(assigns.quiet, do: "quiet", else: assigns.run.state),
        said?: Apiary.Runs.Run.current_state(assigns.run.state) not in ["completed", "pending"]
      )

    ~H"""
    <span class={["q-rs", "q-rs-#{@tone}"]}>
      <span class="q-rs-dot" aria-hidden="true"></span>
      <span class={if(@said?, do: "q-rs-w", else: "sr-only")}>{state_label(@run.state)}</span>
    </span>
    <.relative_time at={@run.started_at || @run.inserted_at} class="q-rs-t" />
    """
  end

  ## The fourteen-day chart

  @slots 14
  @top 22
  @h_runs 104
  @gap 30
  @h_den 36
  @axis 20

  @doc """
  Two plots on one day axis: runs per day above, denied attempts per day below, fourteen
  columns each, today last and in ink. `days` holds fourteen maps `%{day:, runs:, alive:,
  ended_well:, cancelled:, ended_badly:, denied:}`, oldest first, zeros filled in by the
  caller.
  `width` is the drawing's width in pixels, as the `DaysChart` hook measured it, so its
  words are never scaled; `table?` shows the table twin instead of the drawing.
  """
  attr :id, :string, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :table?, :boolean, default: false
  attr :width, :integer, default: 640

  def days_chart(assigns) do
    days = assigns.days
    w = assigns.width
    slot_w = w / @slots
    col = min(26, Float.round(slot_w * 0.64, 1))
    every = if w < 420, do: 4, else: if(w < 720, do: 3, else: 2)
    total = days |> Enum.map(& &1.runs) |> Enum.sum()
    denied = days |> Enum.map(& &1.denied) |> Enum.sum()
    max_runs = days |> Enum.map(& &1.runs) |> Enum.max(fn -> 0 end)
    max_den = days |> Enum.map(& &1.denied) |> Enum.max(fn -> 0 end)
    peak = Enum.find(days, &(&1.runs == max_runs))

    assigns =
      assign(assigns,
        total: total,
        max_runs: max_runs,
        max_den: max_den,
        height: @top + @h_runs + @gap + @h_den + @axis,
        label: chart_label(total, denied, peak, max_runs, assigns.today),
        indexed: Enum.with_index(days),
        w: w,
        col: col,
        every: every,
        slot_w: slot_w,
        slots: @slots,
        top: @top,
        h_runs: @h_runs,
        gap: @gap,
        h_den: @h_den,
        axis: @axis
      )

    ~H"""
    <div
      id={@id}
      class={["q-chart", @total == 0 && "q-chart-empty"]}
      phx-hook="DaysChart"
      data-table={if @table?, do: "1", else: "0"}
      data-width={@w}
    >
      <%= if @table? do %>
        <div
          id={"#{@id}-plot"}
          class="q-chart-table overflow-x-auto"
          tabindex="0"
          role="region"
          aria-label={gettext("Runs and denied attempts per day")}
        >
          <table class="table">
            <thead>
              <tr>
                <th scope="col">{gettext("Day")}</th>
                <th scope="col" class="q-num">{gettext("Runs")}</th>
                <th scope="col" class="q-num">{gettext("Ended well")}</th>
                <th scope="col" class="q-num">{gettext("Cancelled")}</th>
                <th scope="col" class="q-num">{gettext("Denied attempts")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @days} id={"#{@id}-row-#{Date.to_iso8601(day.day)}"}>
                <td class="q-hot">{day_label(day.day, @today)}</td>
                <td class="q-num">{day.runs}</td>
                <td class="q-num">{day.ended_well}</td>
                <td class="q-num">{day.cancelled}</td>
                <td class={["q-num", day.denied > 0 && "q-hot"]}>{day.denied}</td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <svg
          id={"#{@id}-plot"}
          viewBox={"0 0 #{@w} #{@height}"}
          width={@w}
          height={@height}
          role="group"
          aria-label={@label}
          xmlns="http://www.w3.org/2000/svg"
        >
          <text class="q-ttl" x="0" y="12">{gettext("Runs per day")}</text>
          <text :if={@max_runs > 0} class="q-max" x={@w} y="12" text-anchor="end">
            {gettext("max %{max}", max: Format.number(@max_runs))}
          </text>
          <text class="q-ttl" x="0" y={@top + @h_runs + @gap - 10}>
            {gettext("Denied attempts per day")}
          </text>
          <text
            :if={@max_den > 0}
            class="q-max"
            x={@w}
            y={@top + @h_runs + @gap - 10}
            text-anchor="end"
          >
            {gettext("max %{max}", max: Format.number(@max_den))}
          </text>
          <%= for {day, i} <- @indexed do %>
            <.link
              navigate={day_path(@scope, day)}
              data-day={Date.to_iso8601(day.day)}
              data-label={day_label(day.day, @today)}
              data-runs={runs_count(day.runs)}
              data-den={denied_count(day.denied)}
              aria-label={slot_label(day, @today)}
            >
              <rect
                class="q-slot"
                x={fmt(i * @slot_w + 1)}
                y="0"
                width={fmt(@slot_w - 2)}
                height={@height - @axis + 2}
                rx="4"
              />
              <.column
                cx={(i + 0.5) * @slot_w}
                col={@col}
                base={@top + @h_runs}
                value={day.runs}
                max={@max_runs}
                plot={@h_runs}
                class={["q-col-runs", Date.compare(day.day, @today) == :eq && "q-col-today"]}
              />
              <.column
                cx={(i + 0.5) * @slot_w}
                col={@col}
                base={@top + @h_runs + @gap + @h_den}
                value={day.denied}
                max={@max_den}
                plot={@h_den}
                class="q-col-den"
              />
            </.link>
            <text
              :if={(rem(i, @every) == 0 and i <= @slots - 1 - @every) or i == @slots - 1}
              class={["q-ax", i == @slots - 1 && "q-ax-today"]}
              x={fmt(axis_x(i, @slot_w, @slots))}
              y={@height - 5}
              text-anchor={axis_anchor(i, @slots)}
            >
              {day_label(day.day, @today)}
            </text>
          <% end %>
          <line class="q-base" x1="0" x2={@w} y1={@top + @h_runs} y2={@top + @h_runs} />
          <line
            class="q-base"
            x1="0"
            x2={@w}
            y1={@top + @h_runs + @gap + @h_den}
            y2={@top + @h_runs + @gap + @h_den}
          />
        </svg>
      <% end %>
      <%!-- What the day's name already says, drawn; nothing for a screen reader here. --%>
      <div class="q-chart-tt" aria-hidden="true" phx-update="ignore" id={"#{@id}-tip"}></div>
    </div>
    """
  end

  # The first label starts at the axis's left edge and the last ends at its right, so no
  # word is cut; the others sit under their column.
  defp axis_x(0, _slot_w, _slots), do: 0
  defp axis_x(i, slot_w, slots) when i == slots - 1, do: slots * slot_w
  defp axis_x(i, slot_w, _slots), do: (i + 0.5) * slot_w

  defp axis_anchor(0, _slots), do: "start"
  defp axis_anchor(i, slots) when i == slots - 1, do: "end"
  defp axis_anchor(_i, _slots), do: "middle"

  attr :cx, :float, required: true
  attr :col, :any, default: 22
  attr :base, :integer, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true
  attr :plot, :integer, required: true
  attr :class, :any, default: nil

  # A column at most 26 px wide, rounded at the top, square at the baseline; a 2 px stub
  # for a day with nothing, so the day is visibly there and visibly empty.
  defp column(%{value: value, max: max} = assigns) when value > 0 and max > 0 do
    h = max(round(value / max * assigns.plot), 2)
    r = min(4, h)
    col = assigns.col
    x = assigns.cx - col / 2
    y = assigns.base - h

    d =
      "M#{fmt(x)} #{assigns.base}V#{fmt(y + r)}a#{r} #{r} 0 0 1 #{r} -#{r}h#{fmt(col - 2 * r)}a#{r} #{r} 0 0 1 #{r} #{r}V#{assigns.base}z"

    assigns = assign(assigns, :d, d)

    ~H"""
    <path class={@class} d={@d} />
    """
  end

  defp column(assigns) do
    assigns =
      assign(assigns,
        x1: fmt(assigns.cx - assigns.col / 2),
        x2: fmt(assigns.cx + assigns.col / 2)
      )

    ~H"""
    <line class="q-stub" x1={@x1} x2={@x2} y1={@base - 1} y2={@base - 1} />
    """
  end

  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 2)
  defp fmt(x), do: Integer.to_string(x)

  defp day_path(scope, %{day: day}) do
    iso = Date.to_iso8601(day)
    params = %{"from" => iso, "to" => iso}
    params = if Map.get(day, :denied, 0) > 0, do: Map.put(params, "denials", "1"), else: params
    ~p"/#{scope.organisation}/#{scope.workspace}/runs?#{params}"
  end

  @doc "\"7 Sept\", or \"Today\" for the day the reader is living in."
  def day_label(day, today) do
    if Date.compare(day, today) == :eq,
      do: gettext("Today"),
      else: Format.short_date(day)
  end

  defp denied_count(n) do
    ngettext("%{number} denied attempt", "%{number} denied attempts", n, number: Format.number(n))
  end

  defp slot_label(%{runs: 0} = day, today) do
    gettext("%{day}: no runs, %{denied}, open that day's runs",
      day: day_label(day.day, today),
      denied: denied_count(day.denied)
    )
  end

  defp slot_label(day, today) do
    if Date.compare(day.day, today) == :eq do
      gettext(
        "%{day}: %{runs} (%{well} ended well, %{cancelled} cancelled, %{other} alive or ended badly), %{denied}, open that day's runs",
        day: day_label(day.day, today),
        runs: runs_count(day.runs),
        well: Format.number(day.ended_well),
        cancelled: Format.number(day.cancelled),
        other: Format.number(day.alive + day.ended_badly),
        denied: denied_count(day.denied)
      )
    else
      gettext(
        "%{day}: %{runs} (%{well} ended well, %{cancelled} cancelled, %{bad} ended badly), %{denied}, open that day's runs",
        day: day_label(day.day, today),
        runs: runs_count(day.runs),
        well: Format.number(day.ended_well),
        cancelled: Format.number(day.cancelled),
        bad: Format.number(day.ended_badly),
        denied: denied_count(day.denied)
      )
    end
  end

  defp chart_label(0, _denied, _peak, _max, _today), do: gettext("No run in the last 14 days.")

  defp chart_label(total, denied, peak, max_runs, today) do
    gettext("%{runs} and %{denied} in 14 days; most runs on %{peak}, %{max}.",
      runs: runs_count(total),
      denied: denied_count(denied),
      peak: if(peak, do: peak_word(peak.day, today), else: gettext("no day")),
      max: Format.number(max_runs)
    )
  end

  defp peak_word(day, today),
    do: if(Date.compare(day, today) == :eq, do: gettext("today"), else: day_label(day, today))

  ## Guard

  @doc """
  Guard, a few lines of key and value, each with a muted detail under it and the one link
  that opens more: the policy's mode and the version in force, the targets with rules of
  their own, and retention. `policy` is nil while its read is in flight and absent where
  `security` is off, which leaves the retention line alone, under its own name.
  """
  attr :id, :string, default: "overview-guard"

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :security?, :boolean, required: true
  attr :policy, :any, default: nil
  attr :policy_failed?, :boolean, default: false
  attr :workspace, :map, required: true

  attr :retention, :any,
    required: true,
    doc: "nil while loading, else the last retention run or none"

  attr :now, :any, required: true

  def guard(assigns) do
    ~H"""
    <section id={@id} class="q-blk q-ov-grd" aria-labelledby={"#{@id}-h"}>
      <div class="q-band">
        <h2 id={"#{@id}-h"}>{if @security?, do: gettext("Guard"), else: gettext("Retention")}</h2>
      </div>
      <div class={["q-gl", !@security? && "q-gl-one"]}>
        <div :if={@security?} id="overview-policy" class="q-gr">
          <span class="q-gr-k">{gettext("Policy")}</span>
          <%= cond do %>
            <% @policy_failed? -> %>
              <span class="q-gr-v q-faint">{gettext("n/a")}</span>
              <span></span>
              <span class="q-gr-d" id="policy-error">{not_loaded()}</span>
            <% is_nil(@policy) -> %>
              <span class="skeleton q-skel-line w-24"></span>
              <span></span>
              <span class="skeleton q-skel-line q-gr-d w-3/4"></span>
            <% true -> %>
              <span class="q-gr-v" id="overview-policy-version">
                {mode_word(@policy.summary.mode)}<span :if={@policy.version}> · v{@policy.version.version}</span>
              </span>
              <.link
                id="overview-policy-open"
                navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy"}
                class="q-do"
              >
                {gettext("Open")}
              </.link>
              <span class="q-gr-d" id="overview-policy-mode">{policy_detail(@policy)}</span>
          <% end %>
        </div>
        <div :if={@security? && @policy && !@policy_failed?} id="overview-own" class="q-gr">
          <span class="q-gr-k">{gettext("Own rules")}</span>
          <span class="q-gr-v">
            {ngettext("%{number} target", "%{number} targets", @policy.with_rules,
              number: Format.number(@policy.with_rules)
            )}
          </span>
          <.link
            id="overview-own-review"
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/policy/targets"}
            class="q-do"
          >
            {gettext("Review")}
          </.link>
          <span class="q-gr-d">
            <.rich text={own_detail(@scope, @policy)} />
          </span>
        </div>
        <div id="overview-retention" class="q-gr">
          <span class="q-gr-k">{gettext("Retention")}</span>
          <span class="q-gr-v" id="overview-retention-setting">{retention_value(@workspace)}</span>
          <.link
            id="overview-retention-settings"
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/settings/runs"}
            class="q-do"
          >
            {gettext("Change")}
          </.link>
          <span :if={is_nil(@retention)} class="skeleton q-skel-line q-gr-d w-3/4"></span>
          <span :if={@retention} class="q-gr-d" id="overview-retention-last">
            <%= cond do %>
              <% not retention_set?(@workspace) -> %>
                {gettext("Nothing is pruned: runs, events and log output stay.")}
              <% @retention == [] -> %>
                {gettext("No prune has run yet. The job runs nightly.")}
              <% match?([%{runs_pruned: 0} | _], @retention) -> %>
                {nothing_pruned(hd(@retention), @now)}
              <% true -> %>
                <.rich text={pruned(hd(@retention), @now)} />
            <% end %>
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp mode_word("enforce"), do: gettext("enforce")
  defp mode_word("observe"), do: gettext("observe")
  defp mode_word(mode), do: mode

  defp policy_detail(%{summary: %{managed?: false}}),
    do: gettext("Machines use their own policy until the first change here.")

  defp policy_detail(%{version: %{rendered_at: at}} = policy) do
    [
      gettext("In force since %{date}; %{following} of %{targets} follow it.",
        date: Format.short_date(at),
        following: Format.number(policy.following),
        targets:
          ngettext("%{number} target", "%{number} targets", policy.targets,
            number: Format.number(policy.targets)
          )
      ),
      review_detail(policy.suggestions)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp policy_detail(policy),
    do:
      gettext("%{following} of %{targets} follow it.",
        following: Format.number(policy.following),
        targets:
          ngettext("%{number} target", "%{number} targets", policy.targets,
            number: Format.number(policy.targets)
          )
      )

  defp review_detail(%{hosts: hosts, targets: targets}) when hosts > 0 do
    ngettext(
      "%{number} declared host to review in %{targets}.",
      "%{number} declared hosts to review in %{targets}.",
      hosts,
      number: Format.number(hosts),
      targets:
        ngettext("%{number} target", "%{number} targets", targets, number: Format.number(targets))
    )
  end

  defp review_detail(_suggestions), do: nil

  # Who sets a mode of their own: none, the one by name, or how many and which modes.
  defp own_detail(_scope, %{own: []}), do: gettext("Every target follows the workspace's mode.")

  defp own_detail(scope, %{own: [%{target: target, own_mode: "observe"}]} = policy),
    do:
      rich_gettext("%{target} observes; the rest follow the workspace.",
        target: own_link(scope, target, policy[:shared])
      )

  defp own_detail(scope, %{own: [%{target: target}]} = policy),
    do:
      rich_gettext("%{target} enforces; the rest follow the workspace.",
        target: own_link(scope, target, policy[:shared])
      )

  defp own_detail(_scope, %{own: own}) do
    observe = Enum.count(own, &(&1.own_mode == "observe"))

    gettext("%{own} set a mode of their own: %{observe} observe, %{enforce} enforce.",
      own:
        ngettext("%{number} target", "%{number} targets", length(own),
          number: Format.number(length(own))
        ),
      observe: Format.number(observe),
      enforce: Format.number(length(own) - observe)
    )
  end

  # The target's Policy tab, the target named as it is addressed: its system in its name
  # and its address only where its path is `shared` (the policy's read says).
  defp own_link(scope, target, shared) do
    assigns = %{scope: scope, target: target, shared: shared}

    ~H"""
    <.link
      navigate={
        ApiaryWeb.TargetComponents.target_path(
          @scope,
          @target.system,
          @target.path,
          ["policy"],
          @shared
        )
      }
      class="q-mono hover:underline"
    >{ApiaryWeb.TargetComponents.target_label(@target.system, @target.path, @shared)}</.link>
    """
  end

  # The setting in a few words: how long log output is kept, else events, else all of it.
  defp retention_value(%{events_retention_days: nil, log_retention_days: nil}),
    do: gettext("Everything is kept")

  defp retention_value(%{log_retention_days: log}) when is_integer(log),
    do: gettext("%{days} of log output", days: days(log))

  defp retention_value(%{events_retention_days: events}),
    do: gettext("%{days} of events", days: days(events))

  defp retention_set?(workspace),
    do: is_integer(workspace.events_retention_days) or is_integer(workspace.log_retention_days)

  # Last night when the job finished since yesterday's evening, else the date.
  defp last_night?(run, now) do
    at = run.finished_at || run.started_at
    Format.days_back(at, now) <= 1
  end

  defp prune_day(run), do: Format.short_date(run.finished_at || run.started_at)

  defp nothing_pruned(run, now) do
    if last_night?(run, now),
      do: gettext("Nothing was old enough to prune last night."),
      else: gettext("Nothing was old enough to prune on %{date}.", date: prune_day(run))
  end

  # The last prune: when, how many runs, and whether it finished.
  defp pruned(run, now) do
    runs = runs_count(run.runs_pruned)

    case {last_night?(run, now), run.complete} do
      {true, true} ->
        rich_gettext("Last night pruned %{runs}.", runs: runs)

      {true, _} ->
        rich_gettext("Last night pruned %{runs}; not finished, the next night goes on.",
          runs: runs
        )

      {false, true} ->
        rich_gettext("%{date} pruned %{runs}.", date: prune_day(run), runs: runs)

      {false, _} ->
        rich_gettext("%{date} pruned %{runs}; not finished, the next night goes on.",
          date: prune_day(run),
          runs: runs
        )
    end
  end

  defp not_loaded,
    do:
      gettext(
        "This could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
      )

  ## The empty workspace

  @doc """
  The empty workspace's one box, with the state of each step read from the record: step 1
  ticks on a node or pool, step 2 on a key of one (every key the list holds is active),
  step 3 on the first run; a key's `last_used_at` changes step 3's words. Step 2,
  "Connect it", is the two ways a node or pool gets its key: a command run on the machine,
  or a key generated in the browser. While it is current, it names `target`, the newest
  node or pool with no active key, and the panel asks a reader who may connect it
  (`may_key`) how, with the two ways as rows, its kind's own first and primary (a node:
  Get the command; a pool: Generate a key). Get the command makes the command in place
  (the caller's `get_command` event): `command`, once got, is shown in the panel, with
  Copy, until when it works, and that the box waits for the machine. Anyone else reads who
  connects it. `landed` is the first run while the page is open; the box leaves at the
  next navigation.
  """
  attr :id, :string, default: "onboarding"

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :nodes, :integer, required: true, doc: "how many nodes and node pools are in use"

  attr :keys, :list,
    required: true,
    doc: "the keys of the workspace's nodes in use, not revoked, each with its node, newest first"

  attr :may_add, :boolean, required: true, doc: "whether the reader may add a node"

  attr :target, :any,
    default: nil,
    doc: "the newest node or pool in use that holds no active key, or nil"

  attr :may_key, :boolean,
    default: false,
    doc: "whether the reader may connect `target`: add a key and make its enrolment code"

  attr :command, :any,
    default: nil,
    doc:
      "the command got for `target`, shown once: `%{code: fun, expires_at: at}`, the code in a function, or nil"

  attr :server, :string, required: true, doc: "this server's address, for the command"
  attr :landed, :any, default: nil, doc: "the first run, once it has landed under the reader"

  def onboarding(assigns) do
    used =
      assigns.keys
      |> Enum.filter(& &1.last_used_at)
      |> Enum.max_by(& &1.last_used_at, DateTime, fn -> nil end)

    current =
      cond do
        assigns.landed -> 4
        assigns.keys != [] -> 3
        assigns.nodes > 0 -> 2
        true -> 1
      end

    assigns =
      assign(assigns,
        used: used,
        current: current,
        asks: current == 2 and assigns.target != nil and assigns.may_key,
        ways: key_ways(assigns.target),
        target_path: target_path(assigns.scope, assigns.target)
      )

    ~H"""
    <section id={@id} class="q-onb" aria-labelledby={"#{@id}-h"} data-step={@current}>
      <div class="q-onb-steps">
        <h2 id={"#{@id}-h"}>{gettext("Send your first run")}</h2>
        <p :if={@current == 1} class="q-onb-lead">
          {gettext(
            "Nothing has posted to this workspace yet. A machine posts once it is connected to a node."
          )}
        </p>
        <p :if={@current > 1} class="q-onb-lead">
          {gettext(
            "A node or pool is connected once it has a key. Qory Apiary keeps only the key's public half."
          )}
        </p>
        <.steps current={@current} class="my-5">
          <:step title={gettext("Add a node")}>
            {gettext("One per machine, or a node pool for short-lived instances that share one key.")}
          </:step>
          <:step title={gettext("Connect it")}>
            {pgettext(
              "plain",
              "Run one command on the machine, or generate a key for a CI or another system."
            )}
          </:step>
          <:step title={gettext("See runs here")}>
            {if @used,
              do:
                gettext("The machine has verified with its key. The first run it starts lands here."),
              else:
                gettext("From the first post on, every run of that machine lands in this workspace.")}
          </:step>
        </.steps>
        <div :if={@current == 1 and @may_add} class="flex flex-wrap gap-2">
          <.button
            id={"#{@id}-new-node"}
            variant="primary"
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/nodes/new"}
            class="max-[479px]:w-full"
          >
            <.icon name="hero-server" class="size-4" /> {gettext("New node")}
          </.button>
          <.button
            id={"#{@id}-new-pool"}
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/nodes/new-pool"}
            class="max-[479px]:w-full"
          >
            <.icon name="hero-server-stack" class="size-4" /> {gettext("New node pool")}
          </.button>
        </div>
        <p :if={@current == 1 and !@may_add} id={"#{@id}-members"} class="text-[13px]/5 text-muted">
          {gettext("An owner or admin adds nodes and connects them.")}
        </p>
        <p :if={@asks} id={"#{@id}-target"} class="text-[13px]/5">
          <.rich text={
            rich_gettext("%{node} has no key yet.",
              node: {:link, @target_path, @target.name, "q-link font-medium"}
            )
          } />
        </p>
        <p
          :if={(@current == 2 and @target) && !@may_key}
          id={"#{@id}-members-key"}
          class="text-[13px]/5 text-muted"
        >
          {gettext("An owner or admin connects %{node}.", node: @target.name)}
        </p>
        <.button
          :if={@current == 3 or (@current == 2 and !@asks)}
          id={"#{@id}-nodes"}
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/nodes"}
          class="max-[479px]:w-full"
        >
          {gettext("Go to nodes")}
        </.button>
        <p :if={@landed} id={"#{@id}-landed"} class="q-landed">
          <.icon name="hero-check-micro" class="size-4" /> {gettext("The first run has landed.")}
          <.link
            navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@landed.run_id}"}
            class="q-link"
          >{gettext("Open it")}</.link>
        </p>
      </div>
      <div id={"#{@id}-panel"} class="q-onb-paste">
        <%= cond do %>
          <% @current < 2 or (@current == 2 and !@asks) -> %>
            <span class="q-onb-lbl">{gettext("Two ways to connect a machine")}</span>
            <div class="grid gap-3 text-[13px]/5">
              <div class="flex gap-3">
                <.icon name="hero-command-line" class="mt-0.5 size-4.5 flex-none text-muted" />
                <p>
                  <span class="font-medium">{gettext("Connect with a command.")}</span>
                  {gettext(
                    "For a laptop or a server you can open a terminal on: you run one command there, and the key's secret never leaves the machine."
                  )}
                </p>
              </div>
              <div class="flex gap-3">
                <.icon name="hero-key" class="mt-0.5 size-4.5 flex-none text-muted" />
                <p>
                  <span class="font-medium">{gettext("Generate a key in the browser.")}</span>
                  {pgettext(
                    "plain",
                    "For a CI job, a pool, or a machine you can't type on: this page shows the key's secret once, and you copy it into that system."
                  )}
                </p>
              </div>
              <%!-- Said only to one who may add a node and connect it. --%>
              <p :if={@may_add} id={"#{@id}-choose"} class="text-muted">
                {gettext("You choose one for each node, once you have added it.")}
              </p>
            </div>
            <.listening>{gettext("Listening for the first post from a machine.")}</.listening>
          <% @asks and @command == nil -> %>
            <span id={"#{@id}-ask"} class="q-onb-lbl">
              {gettext("How do you want to connect %{node}?", node: @target.name)}
            </span>
            <div id={"#{@id}-ways"} class="grid text-[13px]/5">
              <div
                :for={{way, index} <- Enum.with_index(@ways)}
                id={"#{@id}-way-#{way}"}
                class={["flex items-start gap-3 py-3", index > 0 && "border-t border-line"]}
              >
                <.icon name={way_icon(way)} class="mt-0.5 size-4.5 flex-none text-muted" />
                <div class="grid min-w-0 flex-1 gap-1">
                  <p class="font-medium">{way_title(way)}</p>
                  <p class="text-muted">{way_for(way)}</p>
                </div>
                <.button
                  :if={way == :enrol}
                  id={"#{@id}-enrol"}
                  variant={if index == 0, do: "primary", else: "default"}
                  phx-click="get_command"
                  aria-label={way_label(way, @target.name)}
                  class="flex-none"
                >
                  {way_words(way)}
                </.button>
                <.button
                  :if={way == :generate}
                  id={"#{@id}-generate"}
                  variant={if index == 0, do: "primary", else: "default"}
                  navigate={generate_path(@scope, @target)}
                  aria-label={way_label(way, @target.name)}
                  class="flex-none"
                >
                  {way_words(way)}
                </.button>
              </div>
            </div>
            <.listening>{gettext("Listening for the first post from a machine.")}</.listening>
          <% @asks -> %>
            <span class="q-onb-lbl">
              {gettext("What you run on %{node}", node: @target.name)}
            </span>
            <ApiaryWeb.NodeComponents.unreachable_server id={"#{@id}-unreachable"} url={@server} />
            <.code_block
              id={"#{@id}-command"}
              code={ApiaryWeb.NodeComponents.enrol_command(@server, @command.code.())}
              copy_label={gettext("Copy command")}
              wrap
            />
            <p id={"#{@id}-works"} class="text-[13px]/5 text-muted">
              {gettext("It works once, until %{time}. This is the only time it is shown.",
                time: Format.time(@command.expires_at)
              )}
            </p>
            <.listening id={"#{@id}-waiting"}>
              {gettext("Waiting for %{node} to run it.", node: @target.name)}
            </.listening>
          <% !@landed -> %>
            <.listening>
              <span :if={!@used}>{gettext("Listening for the first post from a machine.")}</span>
              <span :if={@used}>
                <.rich text={
                  rich_gettext("Listening for the first run. %{key} verified %{when}.",
                    key: {:m, @used.label, "font-mono text-[12.5px]"},
                    when: relative_time(%{__changed__: nil, at: @used.last_used_at})
                  )
                } />
              </span>
            </.listening>
          <% true -> %>
        <% end %>
      </div>
    </section>
    <p :if={!@landed} class="q-onb-after">
      {gettext(
        "Runs, targets and the policy fill in once the first run lands; until then there is nothing to glance at."
      )}
    </p>
    """
  end

  # The two ways to connect a node or pool, its kind's way first: a machine runs a
  # command, a pool's shared key is generated in the browser.
  defp key_ways(%{kind: :pool}), do: [:generate, :enrol]
  defp key_ways(_target), do: [:enrol, :generate]

  defp target_path(_scope, nil), do: nil

  defp target_path(scope, target),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{target}/access-key"

  defp generate_path(scope, target),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{target}/access-key/generate"

  defp way_icon(:enrol), do: "hero-command-line"
  defp way_icon(:generate), do: "hero-key"

  defp way_title(:enrol), do: gettext("Connect with a command")
  defp way_title(:generate), do: gettext("Generate a key in the browser")

  defp way_for(:enrol), do: gettext("For a laptop or a server you can open a terminal on.")

  defp way_for(:generate),
    do: gettext("For a CI job, a pool of short-lived machines, or a machine you can't type on.")

  defp way_words(:enrol), do: gettext("Get the command")
  defp way_words(:generate), do: gettext("Generate a key")

  defp way_label(:enrol, node), do: gettext("Get the command for %{node}", node: node)
  defp way_label(:generate, node), do: gettext("Generate a key for %{node}", node: node)

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil
end
