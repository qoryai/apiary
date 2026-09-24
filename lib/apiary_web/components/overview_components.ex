defmodule ApiaryWeb.OverviewComponents do
  @moduledoc """
  The components of the hive overview (`docs/design/brief-overview.md`, od1 to od9): the
  Needs attention list, the activity strip, the alive rows, the fourteen-day chart, the
  last runs, the policy, access keys and retention glances, and the empty hive's checklist.

  Every number here is a count the hive already keeps (oa 2): `runs` columns the projector
  folded, `access_keys` timestamps, `retention_runs` rows, the policy's mode and version.
  Nothing is inferred. Every component that renders inside a list takes its `id` from the
  caller (oj 8), so a live update patches a row in place and never by index. Times tick
  in the browser under the `Ticker` hook, as everywhere (rd3).
  """
  use Phoenix.Component
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents,
    only: [badge: 1, button: 1, code_block: 1, icon: 1, listening: 1, steps: 1, term: 1]

  import ApiaryWeb.RunComponents,
    only: [
      alive: 1,
      beat: 1,
      delimited: 1,
      drift: 1,
      duration: 1,
      elapsed: 1,
      format_seconds: 1,
      heard_at: 1,
      quiet_for: 2,
      relative_time: 1,
      run_state: 1,
      short_id: 1
    ]

  import ApiaryWeb.PolicyComponents, only: [rule_mark: 1, sect: 1, version_pill: 1]

  alias ApiaryWeb.RunComponents
  alias Phoenix.LiveView.JS

  defp lost_tip,
    do:
      gettext(
        "Nothing was heard for three heartbeat intervals. The run may still be going; the record is not."
      )

  defp mode_tip,
    do:
      gettext(
        "Enforce: a connection no rule allows is denied. Observe: it is let through and recorded. A deny rule holds in either mode."
      )

  @doc """
  A translated sentence with markup in it (docs/lingo.md: whole sentences). `text` is the
  result of a gettext call whose `%{name}` placeholders for markup were bound to themselves
  (`gettext("Last heard %{when}.", when: "%{when}")`); `parts` fills each such placeholder
  with its markup, so a link, a time or a bold count sits inside the sentence without
  cutting it into pieces. The text around the parts is escaped, and so is a part that is a
  plain string; a placeholder no part names stays as text.
  """
  def sentence(text, parts) do
    parts = Map.new(parts, fn {name, part} -> {to_string(name), part} end)

    iodata =
      ~r/%\{\w+\}/
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn piece ->
        case Regex.run(~r/\A%\{(\w+)\}\z/, piece) do
          [_, name] when is_map_key(parts, name) -> Phoenix.HTML.Safe.to_iodata(parts[name])
          _ -> Phoenix.HTML.Safe.to_iodata(piece)
        end
      end)

    {:safe, iodata}
  end

  @doc "A part of a `sentence/2` in bold: a count, a time."
  def bold(content, class \\ nil) do
    assigns = %{content: content, class: class}

    ~H"""
    <b class={@class}>{@content}</b>
    """
  end

  # A part of a sentence in the monospace of a target.
  defp mono(content) do
    assigns = %{content: content}

    ~H"""
    <span class="font-mono text-[12.5px]">{@content}</span>
    """
  end

  # A part of a sentence in the monospace of a rule or a path.
  defp code(content, class) do
    assigns = %{content: content, class: class}

    ~H"""
    <code class={@class}>{@content}</code>
    """
  end

  ## od1. Needs attention

  @doc """
  The list of acts. `items` is ordered and bounded by the caller (od1); an empty list
  renders nothing at all: when there is nothing to do the section is absent (oa 3).
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :count, :integer, required: true, doc: "the items not yet resolved, shown and beyond"
  attr :more, :map, default: nil, doc: "%{count:, navigate:, title:}"
  attr :owner?, :boolean, default: false
  attr :now, :any, required: true

  def attention(assigns) do
    ~H"""
    <.sect
      :if={@items != []}
      id={@id}
      title={gettext("Needs attention")}
      count={"#{@count}"}
      class="q-att"
    >
      <:trailing>
        <.link
          :if={@more}
          id={"#{@id}-more"}
          navigate={@more.navigate}
          class="q-link"
          title={@more.title}
        >
          {ngettext("and %{count} more", "and %{count} more", @more.count)}
        </.link>
      </:trailing>
      <ul
        id={"#{@id}-list"}
        aria-label={
          ngettext("%{count} item needs attention", "%{count} items need attention", @count)
        }
      >
        <.attention_item :for={item <- @items} item={item} owner?={@owner?} now={@now} />
      </ul>
    </.sect>
    """
  end

  attr :item, :map, required: true
  attr :owner?, :boolean, required: true
  attr :now, :any, required: true

  defp attention_item(assigns) do
    ~H"""
    <li
      id={@item.id}
      class={["q-sugg-row", @item.resolved && "q-resolved", @item.arrived && "q-arrived"]}
      data-kind={@item.kind}
    >
      <span class="q-att-subj">
        <.attention_mark item={@item} />
        <.attention_subject item={@item} now={@now} />
      </span>
      <span class="q-sugg-what">
        <%= if @item.resolved && @item.resolved[:what] do %>
          {@item.resolved.what}
        <% else %>
          <.attention_sentence item={@item} owner?={@owner?} now={@now} />
        <% end %>
      </span>
      <span class="q-sugg-acts">
        <%= if @item.resolved do %>
          <span :if={@item.resolved[:done]} class="q-done" id={"#{@item.id}-done"} tabindex="-1">
            <.icon name="hero-check-micro" class="size-3" />{@item.resolved.done}
          </span>
        <% else %>
          <.attention_actions item={@item} owner?={@owner?} />
        <% end %>
      </span>
    </li>
    """
  end

  attr :item, :map, required: true

  defp attention_mark(%{item: %{resolved: %{mark: mark}}} = assigns) when not is_nil(mark) do
    ~H"""
    <span
      :if={@item.resolved.mark == :allowed}
      class="q-mark q-mark-ok"
      title={gettext("Allowed")}
    >
      <.icon name="hero-check-micro" class="size-3" /><span class="sr-only">{gettext("Allowed")}</span>
    </span>
    <span
      :if={@item.resolved.mark == :closed}
      class="q-mark q-mark-closed"
      title={gettext("Closed")}
    >
      <.icon name="hero-lock-closed-micro" class="size-3" /><span class="sr-only">{gettext("Closed")}</span>
    </span>
    <span
      :if={@item.resolved.mark == :resolved}
      class="q-mark q-mark-plain q-mark-faint"
      title={gettext("Resolved")}
    >
      <.icon name="hero-check-micro" class="size-3" /><span class="sr-only">{gettext("Resolved")}</span>
    </span>
    """
  end

  defp attention_mark(%{item: %{kind: :denied, locked: locked}} = assigns)
       when is_binary(locked) do
    ~H"""
    <span class="q-mark q-mark-lock" title={gettext("Locked")}>
      <.icon name="hero-lock-closed-micro" class="size-3" /><span class="sr-only">{gettext("Locked")}</span>
    </span>
    """
  end

  defp attention_mark(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <.rule_mark action="pending" />
    """
  end

  defp attention_mark(%{item: %{kind: :quiet}} = assigns) do
    ~H"""
    <span class="q-mark q-mark-amber q-mark-dot" title={gettext("Quiet")}><span class="sr-only">{gettext(
      "Quiet"
    )}</span></span>
    """
  end

  defp attention_mark(%{item: %{kind: :lost}} = assigns) do
    ~H"""
    <span class="q-mark q-mark-amber" title={gettext("Lost")}>
      <.icon name="hero-signal-slash-micro" class="size-3.5" /><span class="sr-only">{gettext("Lost")}</span>
    </span>
    """
  end

  defp attention_mark(%{item: %{kind: :behind}} = assigns) do
    ~H"""
    <span class="q-mark q-mark-amber" title={gettext("Behind the policy in force")}>
      <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
      <span class="sr-only">{gettext("Behind the policy in force")}</span>
    </span>
    """
  end

  defp attention_mark(%{item: %{kind: kind}} = assigns) when kind in [:enforce, :unmanaged] do
    ~H"""
    <span class="q-mark q-mark-plain" title={gettext("Policy")}>
      <.icon
        name={
          if @item.kind == :enforce,
            do: "hero-shield-exclamation-micro",
            else: "hero-shield-check-micro"
        }
        class="size-3.5"
      />
      <span class="sr-only">{gettext("Policy")}</span>
    </span>
    """
  end

  defp attention_mark(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <span class="q-mark q-mark-plain q-mark-faint" title={gettext("Access key")}>
      <.icon name="hero-key-micro" class="size-3.5" /><span class="sr-only">{gettext("Access key")}</span>
    </span>
    """
  end

  attr :item, :map, required: true
  attr :now, :any, required: true

  defp attention_subject(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <span class="q-host truncate font-mono text-[12.5px]" title={destination_title(@item)}>
      {@item.host}<span class="q-port">:{@item.port}</span><span
        :if={@item.held && @item.path != ""}
        class="q-path"
      >{@item.path}</span>
    </span>
    """
  end

  defp attention_subject(%{item: %{kind: kind}} = assigns)
       when kind in [:quiet, :lost, :behind] do
    run = assigns.item.run

    assigns =
      assign(assigns,
        run: run,
        quiet: if(kind == :quiet, do: quiet_for(run, assigns.now) || beat(run) + 1)
      )

    ~H"""
    <.run_state
      state={@run.state}
      quiet_for={@quiet}
      quiet_since={@quiet && heard_at(@run)}
      interval={beat(@run)}
      note={false}
      class="q-state-wrap"
    />
    <span class="q-att-task" title={run_title(@run)}>{run_title(@run)}</span>
    <span class="q-att-rid">{short_id(@run.run_id)}</span>
    <.drift
      :if={@item.kind == :behind && @item.in_force}
      id={"#{@item.id}-drift"}
      reported={@item.reported}
      in_force={@item.in_force}
    />
    """
  end

  defp attention_subject(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <b class="q-att-lead">
      {sentence(gettext("%{observe} is the hive's default", observe: "%{observe}"),
        observe:
          term(%{
            __changed__: nil,
            word: gettext("Observe"),
            standard: mode_tip(),
            class: "q-tip-wide"
          })
      )}
    </b>
    """
  end

  defp attention_subject(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    <b class="q-att-lead">{gettext("Qory serves no policy yet")}</b>
    """
  end

  defp attention_subject(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <span class="q-att-task" title={@item.key.label}>{@item.key.label}</span>
    <span class="q-att-rid">{@item.key.key_id}</span>
    """
  end

  attr :item, :map, required: true
  attr :owner?, :boolean, required: true
  attr :now, :any, required: true

  defp attention_sentence(%{item: %{kind: :denied, locked: locked}} = assigns)
       when is_binary(locked) do
    ~H"""
    {sentence(
      gettext("A locked hive rule denies %{rule}. Only an owner can change it.", rule: "%{rule}"),
      rule: code(@item.locked, "q-rule")
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <span :if={@item.held && @item.path != ""}>
      <b>{gettext("Host allowed, no path rule matches")}</b> <code class="q-rule">{@item.path}</code>.
    </span>
    {denied_sentence(@item)}
    """
  end

  defp attention_sentence(%{item: %{kind: :quiet}} = assigns) do
    assigns = assign(assigns, :interval, beat(assigns.item.run))

    ~H"""
    {sentence(
      gettext(
        "No heartbeat for %{since}. Heartbeats are due every %{interval}; after %{silence} of silence it is marked %{lost}.",
        since: "%{since}",
        interval: format_seconds(@interval),
        silence: format_seconds(@interval * 3),
        lost: "%{lost}"
      ),
      since: bold(since(%{__changed__: nil, at: heard_at(@item.run)}), "tabular-nums"),
      lost:
        term(%{__changed__: nil, word: gettext("lost"), standard: lost_tip(), class: "q-tip-wide"})
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :lost, run: %{elapsed_seconds: elapsed}}} = assigns)
       when is_integer(elapsed) do
    ~H"""
    {sentence(
      gettext(
        "Lost. Last heard %{when}, at least %{elapsed} in. The run never posted its exit.",
        when: "%{when}",
        elapsed: format_seconds(@item.run.elapsed_seconds)
      ),
      when: relative_time(%{__changed__: nil, at: heard_at(@item.run)})
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :lost}} = assigns) do
    ~H"""
    {sentence(
      gettext("Lost. Last heard %{when}. The run never posted its exit.", when: "%{when}"),
      when: relative_time(%{__changed__: nil, at: heard_at(@item.run)})
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :behind}} = assigns) do
    ~H"""
    {sentence(
      gettext(
        "Still on %{reported} after %{beats}; %{in_force} has been in force for %{since}. A run reloads at its next heartbeat.",
        reported: "%{reported}",
        beats: ngettext("%{count} heartbeat", "%{count} heartbeats", @item.beats),
        in_force: "%{in_force}",
        since: "%{since}"
      ),
      reported: version_word(%{__changed__: nil, version: @item.reported}),
      in_force: version_word(%{__changed__: nil, version: @item.in_force}),
      since: bold(since(%{__changed__: nil, at: @item.in_force.rendered_at}), "tabular-nums")
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <%= cond do %>
      <% @item.uncovered == 0 -> %>
        {ngettext(
          "%{count} allow rule is in force and every destination reached in the last 7 days is covered. Enforce would deny nothing today.",
          "%{count} allow rules are in force and every destination reached in the last 7 days is covered. Enforce would deny nothing today.",
          @item.rules
        )}
      <% is_integer(@item.uncovered) -> %>
        {ngettext("%{count} rule is in force.", "%{count} rules are in force.", @item.rules)}
        {sentence(
          ngettext(
            "Enforce would deny %{number} destination reached in the last 7 days.",
            "Enforce would deny %{number} destinations reached in the last 7 days.",
            @item.uncovered,
            number: "%{number}"
          ),
          number: bold(@item.uncovered)
        )}
      <% true -> %>
        {ngettext("%{count} rule is in force.", "%{count} rules are in force.", @item.rules)}
        {gettext(
          "What enforce would deny could not be counted: this hive recorded more than %{cap} connections in 7 days.",
          cap: delimited(Apiary.Policy.Activity.cap())
        )}
    <% end %>
    <span :if={!@owner?}>{gettext("Only an owner sets a mode.")}</span>
    """
  end

  defp attention_sentence(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    {sentence(
      gettext(
        "%{runs} landed under the machines' own policies. The first rule you add, or a mode you set, puts them under the hive's.",
        runs: "%{runs}"
      ),
      runs: bold(runs_count(@item.runs))
    )}
    """
  end

  defp attention_sentence(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <%= cond do %>
      <% @item.key.last_used_at && @item.key.last_runner_version -> %>
        {sentence(
          gettext(
            "Not seen for %{days}; last runner %{version}. A key nobody uses is a key to revoke.",
            days: "%{days}",
            version: @item.key.last_runner_version
          ),
          days: bold(days(@item.days))
        )}
      <% @item.key.last_used_at -> %>
        {sentence(
          gettext("Not seen for %{days}. A key nobody uses is a key to revoke.", days: "%{days}"),
          days: bold(days(@item.days))
        )}
      <% true -> %>
        {sentence(
          gettext(
            "Never used since it was created %{days} ago. A key nobody uses is a key to revoke.",
            days: "%{days}"
          ),
          days: bold(days(@item.days))
        )}
    <% end %>
    """
  end

  # Where a denied destination was reached from, each shape its own sentence.
  defp denied_sentence(%{targets: []} = item) do
    sentence(
      gettext("Denied %{times} in %{runs} without a target, last %{when}.",
        times: "%{times}",
        runs: runs_count(item.runs),
        when: "%{when}"
      ),
      times: bold(times(item.denied)),
      when: relative_time(%{__changed__: nil, at: item.last_seen_at})
    )
  end

  defp denied_sentence(%{targets: [target]} = item) do
    sentence(
      gettext("Denied %{times} in %{runs} of %{target}, last %{when}.",
        times: "%{times}",
        runs: runs_count(item.runs),
        target: "%{target}",
        when: "%{when}"
      ),
      times: bold(times(item.denied)),
      target: mono("#{target.system}/#{target.path}"),
      when: relative_time(%{__changed__: nil, at: item.last_seen_at})
    )
  end

  defp denied_sentence(%{targets: targets} = item) do
    sentence(
      ngettext(
        "Denied %{times} in %{runs} of %{count} target, last %{when}.",
        "Denied %{times} in %{runs} of %{count} targets, last %{when}.",
        length(targets),
        times: "%{times}",
        runs: runs_count(item.runs),
        when: "%{when}"
      ),
      times: bold(times(item.denied)),
      when: relative_time(%{__changed__: nil, at: item.last_seen_at})
    )
  end

  attr :item, :map, required: true
  attr :owner?, :boolean, required: true

  defp attention_actions(%{item: %{kind: :denied, locked: locked}} = assigns)
       when is_binary(locked) do
    ~H"""
    <.link
      id={"#{@item.id}-rule"}
      navigate={ApiaryWeb.ConnectionLive.Rules.rule_path(nil, @item.locked)}
      class="btn btn-xs btn-ghost"
    >
      {gettext("Open the rule")}
    </.link>
    """
  end

  defp attention_actions(%{item: %{kind: :denied, targets: [target]}} = assigns) do
    assigns = assign(assigns, :target, target)

    ~H"""
    <span
      id={"#{@item.id}-menu"}
      class="q-btn-split dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@item.id}-act"}
        type="button"
        class="btn btn-xs"
        aria-label={
          gettext("Allow %{host} for %{target}",
            host: @item.host,
            target: "#{@target.system}/#{@target.path}"
          )
        }
        aria-haspopup="dialog"
        aria-expanded={to_string(@item[:expanded] == true)}
        phx-click={JS.push("rule_open", value: %{id: @item.id, level: "target"})}
      >
        {gettext("Allow here")}
      </button>
      <button
        type="button"
        class="btn btn-xs"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={gettext("More ways to allow %{host}", host: @item.host)}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-chevron-down-micro" class="size-3" />
      </button>
      <ul class="menu menu-sm dropdown-content right-0 z-20 mt-1 w-52" role="menu">
        <li role="none">
          <button
            type="button"
            role="menuitem"
            data-menu-close
            phx-click={JS.push("rule_open", value: %{id: @item.id, level: "hive"})}
          >
            {gettext("Allow for the hive")}
          </button>
        </li>
        <li role="none">
          <.link
            role="menuitem"
            navigate={~p"/hive/policy/targets/#{@target.id}?#{%{"rule" => @item.host}}"}
          >
            {gettext("Allow with paths…")}
          </.link>
        </li>
      </ul>
    </span>
    """
  end

  defp attention_actions(%{item: %{kind: :denied, targets: []}} = assigns) do
    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="btn btn-xs"
      aria-label={gettext("Allow %{host} for the hive", host: @item.host)}
      aria-haspopup="dialog"
      aria-expanded={to_string(@item[:expanded] == true)}
      phx-click={JS.push("rule_open", value: %{id: @item.id, level: "hive"})}
    >
      {gettext("Allow for the hive")}
    </button>
    """
  end

  defp attention_actions(%{item: %{kind: :denied}} = assigns) do
    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="btn btn-xs"
      aria-label={gettext("Allow %{host}, choose a scope", host: @item.host)}
      aria-haspopup="dialog"
      aria-expanded={to_string(@item[:expanded] == true)}
      phx-click={JS.push("rule_open", value: %{id: @item.id, level: "choose"})}
    >
      {gettext("Allow")}
    </button>
    """
  end

  defp attention_actions(%{item: %{kind: :quiet}} = assigns) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={~p"/hive/runs/#{@item.run.run_id}"}
      class="btn btn-xs"
      aria-label={gettext("Open %{run}", run: run_title(@item.run))}
    >
      {gettext("Open")}
    </.link>
    """
  end

  defp attention_actions(%{item: %{kind: :lost}} = assigns) do
    ~H"""
    <button
      id={"#{@item.id}-act"}
      type="button"
      class="btn btn-xs"
      aria-label={gettext("Close %{run}", run: run_title(@item.run))}
      phx-click={JS.push("close_ask", value: %{id: @item.id})}
    >
      {gettext("Close")}
    </button>
    <.link
      navigate={~p"/hive/runs/#{@item.run.run_id}"}
      class="btn btn-xs btn-ghost"
      aria-label={gettext("Open %{run}", run: run_title(@item.run))}
    >
      {gettext("Open")}
    </.link>
    """
  end

  defp attention_actions(%{item: %{kind: :behind}} = assigns) do
    ~H"""
    <.link
      :if={@item.compare}
      id={"#{@item.id}-act"}
      navigate={@item.compare}
      class="btn btn-xs btn-ghost"
      aria-label={gettext("What changed for %{run}", run: run_title(@item.run))}
    >
      {gettext("What changed")}
    </.link>
    <.link
      navigate={~p"/hive/runs/#{@item.run.run_id}"}
      class="btn btn-xs"
      aria-label={gettext("Open %{run}", run: run_title(@item.run))}
    >
      {gettext("Open")}
    </.link>
    """
  end

  defp attention_actions(%{item: %{kind: :enforce}} = assigns) do
    ~H"""
    <%= cond do %>
      <% !@owner? -> %>
        <.link id={"#{@item.id}-act"} navigate={~p"/hive/policy"} class="btn btn-xs">
          {gettext("Open policy")}
        </.link>
      <% @item.uncovered == 0 -> %>
        <.link
          id={"#{@item.id}-act"}
          navigate={~p"/hive/policy?confirm=enforce"}
          class="btn btn-xs btn-primary"
        >
          {gettext("Set the default to enforce")}
        </.link>
      <% true -> %>
        <.link id={"#{@item.id}-act"} navigate={~p"/hive/policy"} class="btn btn-xs">
          {gettext("Review on the policy page")}
        </.link>
    <% end %>
    """
  end

  defp attention_actions(%{item: %{kind: :unmanaged}} = assigns) do
    ~H"""
    <.link id={"#{@item.id}-act"} navigate={~p"/hive/policy"} class="btn btn-xs">
      {gettext("Open policy")}
    </.link>
    """
  end

  defp attention_actions(%{item: %{kind: :idle_key}} = assigns) do
    ~H"""
    <.link
      id={"#{@item.id}-act"}
      navigate={~p"/hive/keys/#{@item.key.id}/revoke"}
      class="btn btn-xs q-btn-danger-ghost"
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

  # Seconds since a moment, ticking in the browser on the server's clock (rd3).
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

  defp destination_title(%{host: host, port: port, path: path}), do: "#{host}:#{port}#{path}"

  defp times(n), do: ngettext("once", "%{number} times", n, number: delimited(n))

  defp runs_count(n), do: ngettext("%{number} run", "%{number} runs", n, number: delimited(n))

  defp days(n), do: ngettext("%{count} day", "%{count} days", n)

  @doc "The task of a run, else its command line, else its short id: what a row calls it."
  def run_title(%{task: task}) when is_binary(task) and task != "", do: task

  def run_title(%{command: command, args: args}) when is_binary(command) do
    line = Enum.join([command | args || []], " ")
    if String.length(line) > 40, do: String.slice(line, 0, 39) <> "…", else: line
  end

  def run_title(%{run_id: run_id}), do: short_id(run_id)

  ## od6. The activity strip

  @doc """
  The four cells over the record (od6): alive now, runs in 14 days with the families,
  denied attempts, cost reported. `facts` is nil while the activity read is in flight;
  `destinations` is the count of denied destinations when it could be made, else nil.
  """
  attr :id, :string, default: "overview-strip"
  attr :alive, :integer, required: true
  attr :facts, :any, required: true, doc: "nil while loading, else the 14-day totals"
  attr :destinations, :any, default: nil
  attr :days, :integer, default: 14

  def strip(assigns) do
    ~H"""
    <dl id={@id} class="q-kvs q-strip" aria-busy={to_string(is_nil(@facts))}>
      <div class="q-kv relative">
        <dt>{gettext("Alive now")}</dt>
        <dd>
          <.link
            id={"#{@id}-alive"}
            navigate={~p"/hive/runs?#{%{"state" => "pending,running"}}"}
            class="q-rowlink"
            aria-label={
              ngettext(
                "%{number} run alive now: open them",
                "%{number} runs alive now: open them",
                @alive,
                number: delimited(@alive)
              )
            }
          >{@alive}</.link>
          <small>{if @alive == 0, do: gettext("none"), else: gettext("starting or running")}</small>
        </dd>
      </div>
      <div class="q-kv relative">
        <dt>{ngettext("Runs, %{count} day", "Runs, %{count} days", @days)}</dt>
        <dd :if={@facts}>
          <.link id={"#{@id}-runs"} navigate={~p"/hive/runs?since=30d"} class="q-rowlink">{delimited(
            @facts.runs
          )}</.link>
          <small>{families_sub(@facts)}</small>
        </dd>
        <dd :if={!@facts}>
          <span class="skeleton q-skel-v"></span><small><span class="skeleton q-skel-line w-3/4"></span></small>
        </dd>
      </div>
      <div class="q-kv relative">
        <dt>
          {ngettext("Denied attempts, %{count} day", "Denied attempts, %{count} days", @days)}
        </dt>
        <dd :if={@facts} class={@facts.denied > 0 && "q-bad"}>
          <.link
            id={"#{@id}-denied"}
            navigate={~p"/hive/connections?#{%{"decision" => "denied", "since" => "30d"}}"}
            class="q-rowlink"
          >{delimited(@facts.denied)}</.link>
          <small>{denied_sub(@facts, @destinations)}</small>
        </dd>
        <dd :if={!@facts}>
          <span class="skeleton q-skel-v"></span><small><span class="skeleton q-skel-line w-3/4"></span></small>
        </dd>
      </div>
      <div class="q-kv">
        <dt>{ngettext("Cost reported, %{count} day", "Cost reported, %{count} days", @days)}</dt>
        <dd :if={@facts && @facts.costed > 0} id={"#{@id}-cost"}>
          {cost_text(@facts.cost)}<small>{sentence(
            ngettext("by %{costed} of %{number} run", "by %{costed} of %{number} runs", @facts.runs,
              costed: "%{costed}",
              number: delimited(@facts.runs)
            ),
            costed: bold(delimited(@facts.costed))
          )}</small>
        </dd>
        <dd :if={@facts && @facts.costed == 0} id={"#{@id}-cost"} class="q-na">
          {gettext("n/a")}<small>{gettext("no run reported one")}</small>
        </dd>
        <dd :if={!@facts}>
          <span class="skeleton q-skel-v"></span><small><span class="skeleton q-skel-line w-3/4"></span></small>
        </dd>
      </div>
    </dl>
    """
  end

  defp families_sub(%{runs: 0}), do: gettext("none")

  defp families_sub(%{runs: 1, alive: 1} = facts) do
    if facts[:targets] == 1, do: gettext("in 1 target"), else: gettext("alive")
  end

  # A list of counts, one item per family that has runs.
  defp families_sub(facts) do
    [
      facts.ended_well > 0 &&
        gettext("%{number} ended well", number: delimited(facts.ended_well)),
      facts.ended_badly > 0 &&
        gettext("%{number} ended badly", number: delimited(facts.ended_badly)),
      facts.alive > 0 && gettext("%{number} alive", number: delimited(facts.alive))
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp denied_sub(%{denied: 0}, _destinations), do: gettext("none")

  defp denied_sub(_facts, destinations) when is_integer(destinations) and destinations > 0 do
    ngettext("to %{number} destination", "to %{number} destinations", destinations,
      number: delimited(destinations)
    )
  end

  defp denied_sub(%{with_denials: runs}, _destinations) when is_integer(runs),
    do: ngettext("in %{number} run", "in %{number} runs", runs, number: delimited(runs))

  defp denied_sub(_facts, _destinations), do: ""

  @doc "A sum of dollars: two decimals, four when the sum is under a cent."
  def cost_text(%Decimal{} = cost) do
    if Decimal.compare(cost, Decimal.new("0.01")) == :lt and Decimal.compare(cost, 0) == :gt,
      do: "$" <> Decimal.to_string(Decimal.round(cost, 4), :normal),
      else: "$" <> Decimal.to_string(Decimal.round(cost, 2), :normal)
  end

  def cost_text(_cost), do: gettext("n/a")

  ## od3. Alive rows

  @doc """
  The runs alive now, most recently started first, at most five; "and n more" when the
  hive has more; "No run alive now." when none, never hidden.
  """
  attr :id, :string, required: true
  attr :runs, :list, required: true
  attr :count, :integer, required: true
  attr :now, :any, required: true

  def alive_rows(assigns) do
    ~H"""
    <div class="q-part-h">
      <h3 id={"#{@id}-h"}>{gettext("Alive now")}</h3>
      <span class="q-sect-n" id={"#{@id}-n"}>{@count}</span>
      <span class="grow"></span>
      <.link
        :if={@count > length(@runs)}
        id={"#{@id}-more"}
        navigate={~p"/hive/runs?#{%{"state" => "pending,running"}}"}
        class="q-link"
      >
        {ngettext("and %{count} more", "and %{count} more", @count - length(@runs))}
      </.link>
    </div>
    <span :if={@runs == []} id={"#{@id}-none"} class="q-none">{gettext("No run alive now.")}</span>
    <div :if={@runs != []} id={"#{@id}-list"} role="list" aria-labelledby={"#{@id}-h"}>
      <.alive_row
        :for={run <- @runs}
        id={"alive-#{run.run_id}"}
        run={run}
        quiet_for={quiet_for(run, @now)}
        arrived={Map.get(run, :arrived, false)}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :quiet_for, :integer, default: nil
  attr :arrived, :boolean, default: false

  def alive_row(assigns) do
    ~H"""
    <div id={@id} class={["q-alive-row", @arrived && "q-arrived"]} role="listitem">
      <.run_state
        state={@run.state}
        quiet_for={@quiet_for}
        quiet_since={heard_at(@run)}
        interval={beat(@run)}
        note={false}
        class="q-state-wrap"
      />
      <div class="q-run-cell">
        <.link navigate={~p"/hive/runs/#{@run.run_id}"} class="q-rowlink truncate">
          <b :if={@run.task}>{@run.task}</b>
          <b
            :if={!@run.task && @run.state == "pending" && !@run.started_at}
            class="!font-normal text-faint"
          >
            {gettext("Ping only")}
          </b>
          <b
            :if={!@run.task && (@run.started_at || @run.state != "pending")}
            class="font-mono text-[12.5px] !font-normal"
          >
            {run_title(@run)}
          </b>
        </.link>
        <span>{short_id(@run.run_id)}</span>
      </div>
      <span class="q-where">
        <span class="q-target">
          <span :if={@run.target_system && @run.target_path}>
            <span class="q-system">{@run.target_system}/</span>{@run.target_path}
          </span>
          <span :if={!(@run.target_system && @run.target_path)} class="font-sans text-faint">
            {gettext("no target")}
          </span>
        </span>
        <span class="q-host">{@run.host || gettext("n/a")}</span>
      </span>
      <.alive
        id={"#{@id}-alive"}
        state={@run.state}
        last_heartbeat_at={@run.last_heartbeat_at}
        last_event_at={@run.last_event_at || @run.inserted_at}
        interval={beat(@run)}
        quiet={is_integer(@quiet_for)}
        run={@run}
      />
    </div>
    """
  end

  ## od5. The fourteen-day chart

  @w 640
  @w_narrow 320
  @slots 14
  @col 22
  @col_narrow 16
  @top 22
  @h_runs 56
  @gap 26
  @h_den 40
  @axis 18

  @doc """
  Two small multiples sharing one x axis (od5): runs per day above, denied attempts per
  day below, fourteen columns each, today last and in ink. `days` holds fourteen maps
  `%{day:, runs:, alive:, ended_well:, ended_badly:, denied:}`, oldest first, zeros
  filled in by the caller. `table?` shows the table twin instead of the SVG.
  """
  attr :id, :string, required: true
  attr :days, :list, required: true
  attr :today, :any, required: true
  attr :table?, :boolean, default: false

  attr :narrow?, :boolean,
    default: false,
    doc: "the phone geometry: 16 px columns, every third label"

  def days_chart(assigns) do
    days = assigns.days
    {w, col, every} = if assigns.narrow?, do: {@w_narrow, @col_narrow, 3}, else: {@w, @col, 2}
    total = days |> Enum.map(& &1.runs) |> Enum.sum()
    denied = days |> Enum.map(& &1.denied) |> Enum.sum()
    max_runs = days |> Enum.map(& &1.runs) |> Enum.max(fn -> 0 end)
    max_den = days |> Enum.map(& &1.denied) |> Enum.max(fn -> 0 end)
    peak = Enum.find(days, &(&1.runs == max_runs))

    assigns =
      assign(assigns,
        total: total,
        denied: denied,
        max_runs: max_runs,
        max_den: max_den,
        peak: peak,
        height: @top + @h_runs + @gap + @h_den + @axis,
        label: chart_label(total, denied, peak, max_runs, assigns.today),
        indexed: Enum.with_index(days),
        w: w,
        col: col,
        every: every,
        slot_w: w / @slots,
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
      data-narrow={if @narrow?, do: "1", else: "0"}
    >
      <div class="q-chart-totals">
        <span :if={@total > 0} id={"#{@id}-totals"}>
          {sentence(
            gettext("%{runs} · %{denied}, 14 days", runs: "%{runs}", denied: "%{denied}"),
            runs:
              sentence(
                ngettext("%{number} run", "%{number} runs", @total, number: "%{number}"),
                number: bold(delimited(@total))
              ),
            denied:
              sentence(
                ngettext("%{number} denied attempt", "%{number} denied attempts", @denied,
                  number: "%{number}"
                ),
                number: bold(delimited(@denied))
              )
          )}
        </span>
        <span :if={@total == 0} id={"#{@id}-totals"}>
          <b>{gettext("No run in the last 14 days")}</b>
        </span>
        <span class="grow"></span>
        <button
          id={"#{@id}-toggle"}
          type="button"
          class="btn btn-ghost btn-xs q-tbtn"
          aria-pressed={to_string(@table?)}
          aria-controls={"#{@id}-plot"}
          aria-label={gettext("Show the chart as a table")}
          phx-click={JS.push("chart_table", value: %{on: !@table?})}
        >
          <.icon
            name={if @table?, do: "hero-chart-bar-micro", else: "hero-table-cells-micro"}
            class="size-3"
          />
          {if @table?, do: gettext("As a chart"), else: gettext("As a table")}
        </button>
      </div>
      <%= if @table? do %>
        <div
          id={"#{@id}-plot"}
          class="overflow-x-auto rounded-box border border-line bg-base-100 q-chart-table"
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
                <th scope="col" class="q-num">{gettext("Denied attempts")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @days} id={"#{@id}-row-#{Date.to_iso8601(day.day)}"}>
                <td>{day_label(day.day, @today)}</td>
                <td class="q-num q-meta">{day.runs}</td>
                <td class="q-num q-meta">{day.ended_well}</td>
                <td class={["q-num", if(day.denied > 0, do: "q-bad", else: "q-meta")]}>
                  {day.denied}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <svg
          id={"#{@id}-plot"}
          viewBox={"0 0 #{@w} #{@height}"}
          role="group"
          aria-label={@label}
          xmlns="http://www.w3.org/2000/svg"
        >
          <text class="q-ttl" x="0" y="12">{gettext("Runs per day")}</text>
          <text :if={@max_runs > 0} class="q-max" x={@w} y="12" text-anchor="end">
            {gettext("max %{max}", max: @max_runs)}
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
            {gettext("max %{max}", max: @max_den)}
          </text>
          <%= for {day, i} <- @indexed do %>
            <.link
              navigate={day_path(day)}
              data-day={Date.to_iso8601(day.day)}
              data-label={day_label(day.day, @today)}
              data-runs={runs_count(day.runs)}
              data-den={denied_count(day.denied)}
              aria-label={slot_label(day, @today)}
              aria-expanded="false"
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
              :if={rem(i, @every) == 0 or i == @slots - 1}
              class={["q-ax", i == @slots - 1 && "q-ax-today"]}
              x={fmt((i + 0.5) * @slot_w)}
              y={@height - 4}
            >
              {axis_label(day.day, @today)}
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
      <div class="q-chart-tt" role="tooltip" phx-update="ignore" id={"#{@id}-tip"}></div>
    </div>
    """
  end

  attr :cx, :float, required: true
  attr :col, :integer, default: 22
  attr :base, :integer, required: true
  attr :value, :integer, required: true
  attr :max, :integer, required: true
  attr :plot, :integer, required: true
  attr :class, :any, default: nil

  # A column at most 24 px wide, rounded at the top, square at the baseline; a 2 px stub
  # for a day with nothing, so the day is visibly there and visibly empty.
  defp column(%{value: value, max: max} = assigns) when value > 0 and max > 0 do
    h = max(round(value / max * assigns.plot), 2)
    r = min(4, h)
    col = assigns.col
    x = assigns.cx - col / 2
    y = assigns.base - h

    d =
      "M#{fmt(x)} #{assigns.base}V#{fmt(y + r)}a#{r} #{r} 0 0 1 #{r} -#{r}h#{col - 2 * r}a#{r} #{r} 0 0 1 #{r} #{r}V#{assigns.base}z"

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

  defp day_path(%{day: day}) do
    iso = Date.to_iso8601(day)
    params = %{"from" => iso, "to" => iso}
    params = if Map.get(day, :denied, 0) > 0, do: Map.put(params, "denials", "1"), else: params
    ~p"/hive/runs?#{params}"
  end

  @doc "\"7 Sep\", or \"Today\" for the day the reader is living in."
  def day_label(day, today) do
    if Date.compare(day, today) == :eq,
      do: gettext("Today"),
      else: Calendar.strftime(day, "%-d %b")
  end

  defp axis_label(day, today), do: day_label(day, today)

  defp denied_count(n) do
    ngettext("%{number} denied attempt", "%{number} denied attempts", n, number: delimited(n))
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
        "%{day}: %{runs} (%{well} ended well, %{other} alive or ended badly), %{denied}, open that day's runs",
        day: day_label(day.day, today),
        runs: runs_count(day.runs),
        well: day.ended_well,
        other: day.alive + day.ended_badly,
        denied: denied_count(day.denied)
      )
    else
      gettext(
        "%{day}: %{runs} (%{well} ended well, %{bad} ended badly), %{denied}, open that day's runs",
        day: day_label(day.day, today),
        runs: runs_count(day.runs),
        well: day.ended_well,
        bad: day.ended_badly,
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
      max: max_runs
    )
  end

  defp peak_word(day, today),
    do: if(Date.compare(day, today) == :eq, do: gettext("today"), else: day_label(day, today))

  ## od4. Last runs

  @doc """
  The five most recently started runs of the hive, alive ones included: the runs table of
  rd8 without groups, with the Target column, at full width. Rows carry the runs list's
  own ids (`run-<run_id>`) and cell classes, so they reflow as rd8 does below 640 px.
  """
  attr :id, :string, required: true
  attr :runs, :any, required: true, doc: "nil while loading"
  attr :quiet_ids, :any, default: MapSet.new()
  attr :new_runs, :integer, default: 0
  attr :now, :any, required: true

  def recent_runs(assigns) do
    ~H"""
    <.sect id={@id} title={gettext("Last runs")}>
      <:trailing>
        <button
          :if={@new_runs > 0}
          id={"#{@id}-new"}
          type="button"
          class="q-link"
          phx-click="show_new"
        >
          {ngettext("%{number} new run", "%{number} new runs", @new_runs,
            number: delimited(@new_runs)
          )}
        </button>
        <.link id={"#{@id}-all"} navigate={~p"/hive/runs"} class="q-link">{gettext("All runs")}</.link>
      </:trailing>
      <div
        class="overflow-x-auto"
        tabindex="0"
        role="region"
        aria-label={gettext("Last runs")}
        aria-busy={to_string(is_nil(@runs))}
      >
        <table class="table q-runs q-last">
          <thead>
            <tr>
              <th scope="col">{gettext("State")}</th>
              <th scope="col">{gettext("Run")}</th>
              <th scope="col">{gettext("Target")}</th>
              <th scope="col">{gettext("Host")}</th>
              <th scope="col">{gettext("Started")}</th>
              <th scope="col" class="q-num">{gettext("Duration")}</th>
              <th scope="col" class="q-num">{gettext("Denials")}</th>
            </tr>
          </thead>
          <tbody :if={is_nil(@runs)} id={"#{@id}-loading"}>
            <tr :for={n <- 1..5} class="q-skel-row" aria-hidden="true">
              <td><span class="skeleton q-skel w-16"></span></td>
              <td>
                <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
              </td>
              <td><span class="skeleton q-skel w-32"></span></td>
              <td><span class="skeleton q-skel w-16"></span></td>
              <td><span class="skeleton q-skel w-24"></span></td>
              <td><span class="skeleton q-skel ml-auto w-14"></span></td>
              <td><span class="skeleton q-skel ml-auto w-5"></span></td>
            </tr>
          </tbody>
          <tbody :if={@runs}>
            <tr :if={@runs == []}>
              <td colspan="7" class="q-none">{gettext("No run has started yet.")}</td>
            </tr>
            <.recent_row
              :for={run <- @runs}
              run={run}
              quiet={MapSet.member?(@quiet_ids, run.id)}
              now={@now}
            />
          </tbody>
        </table>
      </div>
    </.sect>
    """
  end

  attr :run, :map, required: true
  attr :quiet, :boolean, required: true
  attr :now, :any, required: true

  defp recent_row(assigns) do
    {seconds, at} = elapsed(assigns.run)
    assigns = assign(assigns, seconds: seconds, at: at)

    ~H"""
    <tr id={"run-#{@run.run_id}"} class="q-row">
      <td class="q-c-state">
        <.run_state
          state={@run.state}
          exit_code={@run.exit_code}
          signal={@run.signal}
          quiet_for={if @quiet, do: quiet_for(@run, @now) || 0}
          quiet_since={heard_at(@run)}
          interval={beat(@run)}
          closed_at={@run.closed_at}
        />
      </td>
      <td class="q-c-run">
        <div class="q-run-cell">
          <.link navigate={~p"/hive/runs/#{@run.run_id}"} class="q-rowlink truncate">
            <b :if={@run.task}>{@run.task}</b>
            <b
              :if={!@run.task && @run.state == "pending" && !@run.started_at}
              class="!font-normal text-faint"
            >
              {gettext("Ping only")}
            </b>
            <b
              :if={!@run.task && (@run.started_at || @run.state != "pending")}
              class="font-mono text-[12.5px] !font-normal"
            >
              {run_title(@run)}
            </b>
          </.link>
          <span>{short_id(@run.run_id)}{if @run.started_at && is_nil(@run.task),
            do: " · " <> gettext("no task label")}</span>
        </div>
      </td>
      <td class="q-c-target">
        <span :if={@run.target_system && @run.target_path}><span class="q-system">{@run.target_system}/</span>{@run.target_path}</span>
        <span :if={!(@run.target_system && @run.target_path)} class="font-sans text-faint">
          {gettext("no target")}
        </span>
      </td>
      <td class="q-c-host q-meta">
        <span :if={@run.host} class="font-mono text-[12.5px]">{@run.host}</span>
        <span :if={!@run.host} class="text-faint">{gettext("n/a")}</span>
      </td>
      <td class="q-c-when q-meta"><.relative_time at={@run.started_at || @run.inserted_at} /></td>
      <td class="q-c-dur q-num q-meta">
        <%= cond do %>
          <% @run.state in ~w(succeeded failed timed_out) -> %>
            <.duration ms={@run.duration_ms} />
          <% @run.state == "running" and not @quiet -> %>
            <.duration elapsed_seconds={@seconds} elapsed_at={@at} />
          <% @run.state == "pending" -> %>
            <.duration />
          <% true -> %>
            <.duration at_least_seconds={@run.elapsed_seconds} />
        <% end %>
      </td>
      <td class="q-c-den q-num">
        <span :if={@run.denied_count == 0} class="q-zero">0</span>
        <span :if={@run.denied_count > 0} class="q-denials">
          <.icon name="hero-no-symbol-micro" class="size-3" />{delimited(@run.denied_count)}
          <span class="sr-only">{gettext("denied")}</span>
        </span>
      </td>
    </tr>
    """
  end

  ## od7. Policy at a glance

  @doc """
  The policy card (od7): the mode with its source and the targets that differ, the
  version in force, the target counts and what there is to review. `policy` is nil
  while the read is in flight; nothing on the card is a control.
  """
  attr :id, :string, default: "overview-policy"
  attr :policy, :any, required: true

  def policy_glance(assigns) do
    ~H"""
    <.sect id={@id} title={gettext("Policy")}>
      <:trailing>
        <.link id={"#{@id}-open"} navigate={~p"/hive/policy"} class="q-link">
          {gettext("Open policy")}
        </.link>
      </:trailing>
      <div :if={is_nil(@policy)} class="q-lines" aria-busy="true">
        <span class="skeleton q-skel-line w-4/5"></span>
        <span class="skeleton q-skel-line w-1/2"></span>
      </div>
      <dl :if={@policy} class="q-glance">
        <dt>{gettext("Mode")}</dt>
        <dd id={"#{@id}-mode"}>
          <b>{mode_word(@policy.summary.mode)}</b>
          <.badge :if={@policy.summary.managed?}>{gettext("Hive default")}</.badge>
          <.badge :if={!@policy.summary.managed?}>{gettext("Not served")}</.badge>
          <span class="q-muted">
            <%= cond do %>
              <% !@policy.summary.managed? -> %>
                {gettext("Machines use their own policy until the first change here.")}
              <% @policy.own == [] -> %>
                {gettext("Every target follows it.")}
              <% true -> %>
                {ngettext(
                  "%{count} target follows it",
                  "%{count} targets follow it",
                  @policy.following
                )} ·
                <%= case @policy.own do %>
                  <% [one] -> %>
                    {own_mode_sentence(one)}
                  <% many -> %>
                    <.link navigate={~p"/hive/policy/targets?mode=own"} class="q-link">
                      {ngettext("%{count} sets its own", "%{count} set their own", length(many))}
                    </.link>
                <% end %>
            <% end %>
          </span>
        </dd>
        <dt>{gettext("In force")}</dt>
        <dd id={"#{@id}-version"}>
          <%= if @policy.version do %>
            <.version_pill
              size="sm"
              version={@policy.version.version}
              digest={@policy.version.digest}
              navigate={~p"/hive/policy/versions/#{@policy.version.version}"}
            />
            <span class="q-muted">
              {gettext("since %{date}", date: short_day(@policy.version.rendered_at))}
            </span>
          <% else %>
            <span class="text-faint">{gettext("No version yet")}</span>
          <% end %>
        </dd>
        <dt>{gettext("Targets")}</dt>
        <dd id={"#{@id}-targets"}>
          <.link navigate={~p"/hive/policy/targets"} class="q-link">
            {sentence(
              ngettext("%{number} has posted a run", "%{number} have posted runs", @policy.targets,
                number: "%{number}"
              ),
              number: bold(@policy.targets)
            )}
          </.link>
          <span class="q-muted">·</span>
          <.link :if={@policy.with_rules > 0} navigate={~p"/hive/policy/targets"} class="q-link">
            {with_rules_sentence(@policy.with_rules)}
          </.link>
          <span :if={@policy.with_rules == 0} class="q-muted">{with_rules_sentence(0)}</span>
        </dd>
        <dt>{gettext("To review")}</dt>
        <dd id={"#{@id}-review"}>
          <%= cond do %>
            <% is_nil(@policy.suggestions) -> %>
              <span class="text-faint">…</span>
            <% @policy.suggestions.hosts == 0 -> %>
              <span class="text-faint">{gettext("Nothing declared and unallowed.")}</span>
            <% true -> %>
              <.link navigate={~p"/hive/policy/targets"} class="badge badge-info">
                {ngettext("%{count} to review", "%{count} to review", @policy.suggestions.hosts)}
              </.link>
              <span class="q-muted">
                {ngettext(
                  "in %{count} target",
                  "in %{count} targets",
                  @policy.suggestions.targets
                )}
              </span>
          <% end %>
        </dd>
      </dl>
    </.sect>
    """
  end

  defp mode_word("enforce"), do: gettext("enforce")
  defp mode_word("observe"), do: gettext("observe")
  defp mode_word(mode), do: mode

  # The one target that sets its own mode, and the mode it sets.
  defp own_mode_sentence(%{target: target, own_mode: "enforce"}),
    do:
      sentence(gettext("1 sets its own: %{target} enforces", target: "%{target}"),
        target: target_link(target)
      )

  defp own_mode_sentence(%{target: target, own_mode: "observe"}),
    do:
      sentence(gettext("1 sets its own: %{target} observes", target: "%{target}"),
        target: target_link(target)
      )

  defp own_mode_sentence(%{target: target, own_mode: mode}) do
    sentence(gettext("1 sets its own: %{target} %{mode}", target: "%{target}", mode: mode),
      target: target_link(target)
    )
  end

  defp target_link(target) do
    assigns = %{target: target}

    ~H"""
    <.link
      navigate={~p"/hive/policy/targets/#{@target.id}"}
      class="q-link font-mono text-[12.5px]"
    >{@target.system}/{@target.path}</.link>
    """
  end

  defp with_rules_sentence(n) do
    sentence(
      ngettext("%{number} with rules of its own", "%{number} with rules of their own", n,
        number: "%{number}"
      ),
      number: bold(n)
    )
  end

  defp short_day(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b")
  defp short_day(_at), do: gettext("n/a")

  ## od9. Retention

  @doc """
  The retention card (od9): the setting in the settings page's own words, then the last
  prune from `retention_runs`. A hive that keeps everything has one line.
  """
  attr :id, :string, default: "overview-retention"
  attr :hive, :map, required: true
  attr :runs, :any, required: true, doc: "nil while loading, else the last retention run or none"
  attr :now, :any, required: true

  def retention_glance(assigns) do
    ~H"""
    <.sect id={@id} title={gettext("Retention")}>
      <:trailing>
        <.link id={"#{@id}-settings"} navigate={~p"/hive/settings#retention"} class="q-link">
          {gettext("Settings")}
        </.link>
      </:trailing>
      <div :if={is_nil(@runs)} class="q-lines" aria-busy="true">
        <span class="skeleton q-skel-line w-4/5"></span>
        <span class="skeleton q-skel-line w-1/2"></span>
      </div>
      <div :if={@runs} class="q-lines">
        <span id={"#{@id}-setting"}>{retention_summary(@hive)}</span>
        <span :if={retention_set?(@hive)} id={"#{@id}-last"}>
          <%= case @runs do %>
            <% [] -> %>
              {gettext("No prune has run yet. The job runs nightly.")}
            <% [%{runs_pruned: 0} = run | _] -> %>
              {nothing_pruned(run, @now)}
            <% [run | _] -> %>
              {pruned(run, @now)}{cutoffs(run)}
          <% end %>
        </span>
      </div>
    </.sect>
    """
  end

  @doc "The setting in the settings page's own words."
  def retention_summary(%{events_retention_days: nil, log_retention_days: nil}),
    do: gettext("This hive keeps everything.")

  def retention_summary(%{events_retention_days: events, log_retention_days: nil}),
    do: gettext("Events and log output are pruned after %{days}.", days: days(events))

  def retention_summary(%{events_retention_days: nil, log_retention_days: log}),
    do: gettext("Log output is pruned after %{days}; events are kept.", days: days(log))

  def retention_summary(%{events_retention_days: events, log_retention_days: log}) do
    gettext("Log output is pruned after %{log_days}, events after %{events_days}.",
      log_days: days(log),
      events_days: days(events)
    )
  end

  defp retention_set?(hive),
    do: is_integer(hive.events_retention_days) or is_integer(hive.log_retention_days)

  # Last night when the job finished since yesterday's evening, else the date.
  defp last_night?(run, now) do
    at = run.finished_at || run.started_at
    Date.diff(DateTime.to_date(now), DateTime.to_date(at)) <= 1
  end

  defp prune_day(run), do: Calendar.strftime(run.finished_at || run.started_at, "%-d %b")

  defp nothing_pruned(run, now) do
    if last_night?(run, now),
      do: gettext("Nothing was old enough to prune last night."),
      else: gettext("Nothing was old enough to prune on %{date}.", date: prune_day(run))
  end

  # The last prune: when, how many runs, what went, and whether it finished.
  defp pruned(run, now) do
    bindings = [
      runs: "%{runs}",
      events:
        ngettext("%{number} event", "%{number} events", run.events_deleted,
          number: delimited(run.events_deleted)
        ),
      bytes: format_bytes(run.log_bytes_deleted),
      chunks:
        ngettext("%{number} chunk", "%{number} chunks", run.log_chunks_deleted,
          number: delimited(run.log_chunks_deleted)
        ),
      date: prune_day(run)
    ]

    text =
      case {last_night?(run, now), run.complete} do
        {true, true} ->
          gettext(
            "Last night pruned %{runs}: %{events} and %{bytes} of log output in %{chunks}.",
            bindings
          )

        {true, _} ->
          gettext(
            "Last night pruned %{runs}: %{events} and %{bytes} of log output in %{chunks}; not finished, the next night goes on.",
            bindings
          )

        {false, true} ->
          gettext(
            "%{date} pruned %{runs}: %{events} and %{bytes} of log output in %{chunks}.",
            bindings
          )

        {false, _} ->
          gettext(
            "%{date} pruned %{runs}: %{events} and %{bytes} of log output in %{chunks}; not finished, the next night goes on.",
            bindings
          )
      end

    sentence(text, runs: bold(runs_count(run.runs_pruned)))
  end

  defp cutoffs(%{log_cutoff: nil, events_cutoff: nil}), do: ""

  defp cutoffs(%{log_cutoff: log, events_cutoff: nil}),
    do: " " <> gettext("Pruned log output from before %{date}.", date: short_day(log))

  defp cutoffs(%{log_cutoff: nil, events_cutoff: events}),
    do: " " <> gettext("Pruned events from before %{date}.", date: short_day(events))

  defp cutoffs(%{log_cutoff: log, events_cutoff: events}) do
    " " <>
      gettext("Pruned log output from before %{log_date}, events from before %{events_date}.",
        log_date: short_day(log),
        events_date: short_day(events)
      )
  end

  @doc "1024 bytes as \"1.0 kB\", and so on."
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1000, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) do
    {value, unit} =
      cond do
        bytes >= 1_000_000_000 -> {bytes / 1_000_000_000, "GB"}
        bytes >= 1_000_000 -> {bytes / 1_000_000, "MB"}
        true -> {bytes / 1000, "kB"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  def format_bytes(_bytes), do: "0 B"

  ## od8. Access keys

  @doc """
  The access keys card (od8): at most five active keys, most recently seen first, each with
  the runner and contract version it last posted with, the hosts its runs came from in the
  last seven days and the last run it started. A key is not a machine: one key often serves
  many hosts (a pool of ephemeral instances shares one), so the row counts the hosts and
  names the one host when there is only one. `last_runs` maps a key's row id to its last
  run and `hosts` to `%{count:, host:}`; both nil while the read is in flight.
  """
  attr :id, :string, default: "overview-keys"
  attr :keys, :list, required: true, doc: "the active keys, in the order to show"
  attr :total, :integer, required: true, doc: "how many active keys the hive has"
  attr :last_runs, :any, required: true
  attr :hosts, :any, default: nil
  attr :create?, :boolean, default: true, doc: "the link to a new key, once a run has landed"

  def access_keys(assigns) do
    ~H"""
    <.sect id={@id} title={gettext("Access keys")} count={"#{@total}"}>
      <:trailing>
        <.link :if={@create?} id={"#{@id}-create"} navigate={~p"/hive/keys/new"} class="q-link">
          {gettext("Create another access key")}
        </.link>
      </:trailing>
      <div
        class="overflow-x-auto"
        tabindex="0"
        role="region"
        aria-label={gettext("Access keys")}
        aria-busy={to_string(is_nil(@last_runs))}
      >
        <table class="table q-keyrows">
          <thead>
            <tr>
              <th scope="col">{gettext("Key")}</th>
              <th scope="col">{gettext("Last seen")}</th>
              <th scope="col">{gettext("Runner")}</th>
              <th scope="col">{gettext("Hosts, 7 days")}</th>
              <th scope="col">{gettext("Last run")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={key <- @keys} id={"key-#{key.id}"}>
              <td class="q-c-key">
                <div class="q-kcell">
                  <b>
                    {key.label}
                    <.badge :if={Apiary.AccessKeys.AccessKey.status(key) == :rotating} color="warning">
                      {gettext("Rotating")}
                    </.badge>
                  </b>
                  <span>{key.key_id}</span>
                </div>
              </td>
              <td class="q-c-seen q-meta">
                <.relative_time :if={key.last_used_at} at={key.last_used_at} />
                <span :if={!key.last_used_at} class="text-faint">{gettext("Never posted")}</span>
              </td>
              <td class="q-c-rv q-meta">
                <span :if={key.last_runner_version} class="font-mono text-[12.5px]">
                  {String.trim_leading(key.last_runner_version, "v")}
                  <span
                    :if={key.last_contract_version}
                    class="font-mono text-[11.5px] text-faint"
                    title={gettext("Contract version %{version}", version: key.last_contract_version)}
                  >
                    v{key.last_contract_version}
                  </span>
                </span>
                <span :if={!key.last_runner_version} class="text-faint">{gettext("n/a")}</span>
              </td>
              <td class="q-c-hosts q-meta">
                <%= cond do %>
                  <% is_nil(@hosts) -> %>
                    <span class="skeleton q-skel-line w-16"></span>
                  <% is_nil(@hosts[key.id]) -> %>
                    <span class="text-faint">{gettext("none")}</span>
                  <% @hosts[key.id].count == 1 -> %>
                    <span class="font-mono text-[12.5px]" title={@hosts[key.id].host}>
                      {@hosts[key.id].host}
                    </span>
                  <% true -> %>
                    <span class="tabular-nums">
                      {ngettext("%{number} host", "%{number} hosts", @hosts[key.id].count,
                        number: delimited(@hosts[key.id].count)
                      )}
                    </span>
                <% end %>
              </td>
              <td class="q-c-last">
                <%= cond do %>
                  <% is_nil(@last_runs) -> %>
                    <span class="skeleton q-skel-line w-32"></span>
                  <% run = @last_runs[key.id] -> %>
                    <.link navigate={~p"/hive/runs/#{run.run_id}"} class="q-lastrun">
                      <.run_state
                        state={run.state}
                        exit_code={run.exit_code}
                        signal={run.signal}
                        note={false}
                      />
                      <span class={["q-lastrun-task", !run.task && "font-mono text-[12.5px]"]}>
                        {run_title(run)}
                      </span>
                      <span class="text-faint">
                        <.relative_time at={run.started_at || run.inserted_at} />
                      </span>
                    </.link>
                  <% true -> %>
                    <span class="text-faint">{gettext("No run yet")}</span>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <:footer :if={@total > length(@keys)}>
        <.link id={"#{@id}-more"} navigate={~p"/hive/keys"} class="q-link">
          {ngettext("and %{count} more", "and %{count} more", @total - length(@keys))}
        </.link>
      </:footer>
    </.sect>
    """
  end

  ## oe6. The empty hive

  @doc """
  The checklist card of `brief.md` h1 with the state of each step read from the record
  (oe6): step 1 ticks on an active key, step 2 on a key's `last_used_at`, step 3 on the
  first run. `landed` is the first run while the page is open; the card leaves at the next
  navigation.
  """
  attr :id, :string, default: "onboarding"
  attr :keys, :list, required: true, doc: "the active keys"
  attr :preview, :string, required: true
  attr :landed, :any, default: nil, doc: "the first run, once it has landed under the reader"

  def onboarding(assigns) do
    used =
      assigns.keys
      |> Enum.filter(& &1.last_used_at)
      |> Enum.max_by(& &1.last_used_at, DateTime, fn -> nil end)

    current =
      cond do
        assigns.landed -> 4
        used -> 3
        assigns.keys != [] -> 2
        true -> 1
      end

    assigns = assign(assigns, used: used, current: current, newest: List.first(assigns.keys))

    ~H"""
    <section
      id={@id}
      class="q-sect grid overflow-hidden md:grid-cols-2"
      aria-labelledby={"#{@id}-h"}
      data-step={@current}
    >
      <div class="grid content-start gap-5 p-5 md:p-7">
        <div>
          <h2 id={"#{@id}-h"} class="text-base/6 font-semibold tracking-[-0.01em]">
            {gettext("Send your first run")}
          </h2>
          <p :if={@current == 1} class="mt-1 text-muted">
            {gettext(
              "Nothing has posted to this hive yet. An access key is all a machine needs to start."
            )}
          </p>
          <p :if={@current > 1} class="mt-1 text-muted">
            {gettext(
              "The key is made. Paste its server block into the runner file on the machine; the secret was shown once, when the key was created."
            )}
          </p>
        </div>
        <.steps current={@current}>
          <:step title={gettext("Create an access key")}>
            {gettext("Label it after the machine or environment.")}
          </:step>
          <:step title={gettext("Paste the server block into the runner file")}>
            {gettext(
              "The secret is shown once, in the dialog that creates it. One key can serve many hosts: a pool of ephemeral instances shares one."
            )}
          </:step>
          <:step title={gettext("See runs here")}>
            {if @current == 3,
              do:
                gettext("The machine has verified with its key. The first run it starts lands here."),
              else: gettext("From the first post on, every run of that machine lands in this hive.")}
          </:step>
        </.steps>
        <div :if={@current == 1}>
          <.button
            id={"#{@id}-create"}
            variant="primary"
            navigate={~p"/hive/keys/new"}
            class="max-[479px]:w-full"
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("Create an access key")}
          </.button>
        </div>
        <div :if={@current in [2, 3]}>
          <.button id={"#{@id}-keys"} navigate={~p"/hive/keys"} class="max-[479px]:w-full">
            {gettext("Manage access keys")}
          </.button>
        </div>
        <div :if={@landed} id={"#{@id}-landed"} class="q-landed">
          <.icon name="hero-check-micro" class="size-4" /> {gettext("The first run has landed.")}
          <.link navigate={~p"/hive/runs/#{@landed.run_id}"} class="q-link">{gettext("Open it")}</.link>
        </div>
      </div>
      <div class="hidden content-start gap-3 border-l border-line bg-base-200 p-7 md:grid">
        <p class="text-xs/4 font-medium tracking-[0.005em] text-muted">
          {if @current >= 3, do: gettext("What you pasted"), else: gettext("What you will paste")}
        </p>
        <.code_block code={@preview} label="~/.config/qory/runner.yaml" />
        <.onboarding_listening :if={!@landed} used={@used} class="mt-1" />
      </div>
    </section>
    <.onboarding_listening :if={!@landed} used={@used} class="md:hidden" />
    """
  end

  attr :used, :any, required: true
  attr :class, :any, default: nil

  defp onboarding_listening(assigns) do
    ~H"""
    <.listening class={@class}>
      <span :if={!@used}>{gettext("Listening for the first post from a machine.")}</span>
      <span :if={@used}>
        {sentence(
          gettext("Listening for the first run. %{key} verified %{when}.",
            key: "%{key}",
            when: "%{when}"
          ),
          key: mono(@used.label),
          when: relative_time(%{__changed__: nil, at: @used.last_used_at})
        )}
      </span>
    </.listening>
    """
  end

  ## Skeletons (oe5)

  @doc "Faint lines in the shape of the rows that will come; never a spinner."
  attr :lines, :integer, default: 3
  attr :class, :any, default: nil

  def skeleton_lines(assigns) do
    ~H"""
    <div class={["grid gap-2.5", @class]} aria-busy="true" aria-hidden="true">
      <span
        :for={n <- 1..@lines}
        class={["skeleton q-skel-line", Enum.at(~w(w-4/5 w-3/5 w-2/3 w-1/2), rem(n, 4))]}
      ></span>
    </div>
    """
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil

  @doc false
  def delimited_count(n), do: RunComponents.delimited(n)
end
