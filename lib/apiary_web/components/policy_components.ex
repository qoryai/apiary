defmodule ApiaryWeb.PolicyComponents do
  @moduledoc """
  The components of the security policy: the version pill and the version link, the mark
  of a rule, the source chip, the mode switch, the rule composer with its reading line,
  the rules table with provenance, the suggestions of the harness, the history of changes
  with its diff, and the document well.

  The pages under `/:org/:workspace/policy` use all of them; the run page and the
  connections pages use the first four, so a version, a rule and where it came from look
  the same wherever a policy is named.

  Everything rendered here comes from `Apiary.Policy` or from a form: hosts, paths and
  names are only ever interpolated, never `raw/1`.
  """
  use Phoenix.Component
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents,
    only: [
      avatar: 1,
      badge: 1,
      button: 1,
      filter_menu: 1,
      filter_tokens: 1,
      icon: 1,
      list_search: 1,
      menu_divider: 1,
      menu_heading: 1,
      menu_item: 1,
      notice: 1,
      row_menu: 1,
      sort_menu: 1,
      views: 1
    ]

  import ApiaryWeb.RichText

  # `RunComponents` uses the shared components of this module, so nothing of it is imported
  # here: its functions are called by their full name, which is no compile-time dependency.
  alias ApiaryWeb.Format
  alias ApiaryWeb.PolicyLive.RuleList
  alias ApiaryWeb.RunComponents

  alias Phoenix.LiveView.JS

  ## Version pill and version link

  @doc """
  The version and digest, wherever a policy is named: page heads, history rows, the diff
  bar. `copy` adds the icon-only button that copies the full digest; `sm` is the 22 px
  pill of a history row, without shadow and without copy.
  """
  attr :id, :string, default: nil, doc: "required with `copy`: the copy button hangs on it"
  attr :version, :integer, default: nil, doc: "nil renders \"No version yet\""
  attr :digest, :string, default: nil, doc: "\"sha256=…\"; the first 12 hex characters show"
  attr :navigate, :string, default: nil, doc: "the version page"
  attr :copy, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(sm md)

  attr :scope, :string,
    default: nil,
    doc:
      "whose version, when shown away from its own page: \"workspace baseline\" or a system/path; a quiet suffix"

  attr :class, :any, default: nil

  def version_pill(%{version: nil} = assigns) do
    ~H"""
    <span id={@id} class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]}>
      <span class="q-vpill-dg">{gettext("No version yet")}</span>
    </span>
    """
  end

  def version_pill(assigns) do
    ~H"""
    <span id={@id} class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]} title={@digest}>
      <.link :if={@navigate} navigate={@navigate} class="q-vpill-v">
        <span class="sr-only">{gettext("Version")} </span>v{@version}
      </.link>
      <span :if={!@navigate} class="q-vpill-v"><span class="sr-only">{gettext("Version")} </span>v{@version}</span>
      <span :if={@digest} class="q-vpill-dg">
        <i :if={@size == "md"}>sha256</i>{short_digest(@digest)}
      </span>
      <span :if={@scope} class="q-vpill-scope"><span class="sr-only">{gettext("of")} </span>{@scope}</span>
      <button
        :if={@copy && @size == "md" && @digest && @id}
        id={"#{@id}-copy"}
        type="button"
        phx-hook="CopyToClipboard"
        data-copied-words={gettext("Copied")}
        data-copy={@digest}
        class="copy-btn q-vpill-copy tooltip tooltip-left"
        data-tip={gettext("Copy the digest")}
        aria-label={gettext("Copy the digest")}
      >
        <span class="copy-idle"><.icon name="hero-clipboard-document-micro" class="size-3" /></span>
        <span class="copy-done"><.icon name="hero-check-micro" class="size-3" /></span>
        <span class="sr-only" aria-live="polite"></span>
      </button>
    </span>
    """
  end

  @doc """
  A version inside running text (a timeline head, a summary line, the run header): not a
  pill but a link, mono 600, underlined in the field line.
  """
  attr :version, :integer, required: true
  attr :navigate, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil

  def version_link(%{navigate: nil} = assigns) do
    ~H"""
    <span class={["q-ver q-ver-plain", @class]} title={@title}>v{@version}</span>
    """
  end

  def version_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["q-ver", @class]} title={@title}>v{@version}</.link>
    """
  end

  @doc "The first twelve hex characters of a `sha256=…` digest, as every page shows one."
  def short_digest("sha256=" <> hex), do: String.slice(hex, 0, 12)
  def short_digest(digest) when is_binary(digest), do: String.slice(digest, 0, 12)
  def short_digest(_digest), do: nil

  ## The mark of a rule

  @doc """
  The 18 px mark of a rule, in the vocabulary of a connection's decision mark: allow is
  the soft green check, deny the solid red barred circle, `pending` the dashed red outline
  of a host nothing has decided yet (a suggestion, a destination enforce would deny).
  """
  attr :action, :string, required: true, values: ~w(allow deny pending)
  attr :class, :any, default: nil

  def rule_mark(assigns) do
    ~H"""
    <span class={["q-mark", rule_mark_class(@action), @class]} title={rule_mark_word(@action)}>
      <.icon
        name={if @action == "allow", do: "hero-check-micro", else: "hero-no-symbol-micro"}
        class="size-3"
      />
      <span class="sr-only">{rule_mark_word(@action)}</span>
    </span>
    """
  end

  defp rule_mark_class("allow"), do: "q-mark-ok"
  defp rule_mark_class("deny"), do: "q-mark-no"
  defp rule_mark_class("pending"), do: "q-mark-pend"

  defp rule_mark_word("allow"), do: gettext("Allow")
  defp rule_mark_word("deny"), do: gettext("Deny")
  defp rule_mark_word("pending"), do: gettext("Not allowed")

  ## Source chip

  @doc """
  Where a rule comes from: three shapes, three wordings, no status hue. `label` replaces
  the words where the same chip names a target's policy ("Own rules", "Workspace
  baseline") or marks a change the workspace made ("workspace").
  """
  attr :source, :atom, required: true, values: [:workspace, :target, :workspace_locked]
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def source_chip(assigns) do
    ~H"""
    <span class={["q-src", source_class(@source), @class]}>
      <.icon :if={@source == :target} name="hero-book-open-micro" class="size-3" />
      <.icon :if={@source == :workspace_locked} name="hero-lock-closed-micro" class="size-3" />
      <svg
        :if={@source == :workspace}
        viewBox="0 0 16 16"
        class="size-3"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="m8 2 5.2 3v6L8 14l-5.2-3V5z" />
      </svg>
      {@label || source_words(@source)}
    </span>
    """
  end

  defp source_class(:workspace), do: nil
  defp source_class(:target), do: "q-src-target"
  defp source_class(:workspace_locked), do: "q-src-lock"

  defp source_words(:workspace), do: gettext("Workspace")
  defp source_words(:target), do: gettext("This target")
  defp source_words(:workspace_locked), do: gettext("Workspace, locked")

  # A count beside a title, grouped as the reader's language groups it.
  defp count_label(n) when is_number(n), do: Format.number(n)
  defp count_label(other), do: other

  ## Section card

  @doc """
  A section card: a header with a title, a count and a trailing control, then whatever
  the section holds (a composer, a table), then a footer bar.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :any, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :trailing
  slot :description
  slot :inner_block, required: true
  slot :footer

  def sect(assigns) do
    ~H"""
    <section id={@id} class={["q-sect", @class]} aria-labelledby={"#{@id}-h"} {@rest}>
      <header>
        <h2 id={"#{@id}-h"}>{@title}</h2>
        <span :if={@count} id={"#{@id}-n"} class="q-sect-n">{count_label(@count)}</span>
        <span class="grow"></span>
        {render_slot(@trailing)}
        <p :if={@description != []}>{render_slot(@description)}</p>
      </header>
      {render_slot(@inner_block)}
      <footer :if={@footer != []}>{render_slot(@footer)}</footer>
    </section>
    """
  end

  ## Mode switch

  @doc """
  The workspace's default mode as two radio cards. Choosing the other card never switches
  at once: it sends `mode_ask`, and the page opens the confirm. Arrow keys move between
  the cards (the `PolicyPage` hook); Space or Enter asks. A mode is an owner's or an admin's
  to set: for a member the group is `aria-disabled`, keeps its look and its words, and
  does nothing.
  """
  attr :id, :string, default: "policy-mode"
  attr :mode, :string, required: true, values: ~w(observe enforce), doc: "the workspace's default"

  attr :can_edit, :boolean,
    default: false,
    doc: "whether the reader may set the mode (`security_policy.set_mode`)"

  attr :served, :boolean, default: true, doc: "false on a new workspace: nothing is served yet"
  attr :following, :integer, default: 0, doc: "targets that follow the default"
  attr :own, :list, default: [], doc: "the modes of the targets that set their own"

  attr :scope, :map,
    required: true,
    doc: "the caller's scope: its organisation and workspace name the links"

  attr :fact, :any,
    default: nil,
    doc: ":loading, nil, %{denied:, destinations:} or %{uncovered:, destinations:} or :none"

  attr :floor, :any,
    default: nil,
    doc: "`%{name:}` where the level above the workspace requires enforce: the switch is fixed"

  def mode_switch(assigns) do
    assigns =
      if assigns.floor,
        do: assign(assigns, mode: "enforce", can_edit: false, fact: nil),
        else: assigns

    ~H"""
    <section class="grid gap-2.5" aria-labelledby={"#{@id}-h"}>
      <h2 id={"#{@id}-h"} class="sr-only">{gettext("Mode")}</h2>
      <div
        id={@id}
        class="q-mode"
        role="radiogroup"
        aria-labelledby={"#{@id}-h"}
        aria-disabled={!@can_edit && "true"}
        data-floor={@floor && "true"}
        data-roving
      >
        <button
          :for={
            {mode, name, icon, sentence} <- [
              {"observe", gettext("Observe"), "hero-eye-micro",
               gettext(
                 "Records every connection and denies only what a deny rule names. A host no rule names is let through, and the record says so."
               )},
              {"enforce", gettext("Enforce"), "hero-shield-exclamation-micro",
               gettext(
                 "Denies a connection no rule allows, and records the denial. With no allow rule, a run reaches nothing."
               )}
            ]
          }
          id={"#{@id}-#{mode}"}
          type="button"
          class="q-mode-card"
          role="radio"
          aria-checked={to_string(@mode == mode)}
          aria-disabled={!@can_edit && "true"}
          aria-describedby={
            Enum.join(
              [
                "#{@id}-#{mode}-p",
                @mode == mode && (@fact || !@served) && "#{@id}-fact",
                !@can_edit && "#{@id}-owners"
              ]
              |> Enum.filter(&is_binary/1),
              " "
            )
          }
          tabindex={if @mode == mode, do: "0", else: "-1"}
          phx-click={@can_edit && @mode != mode && JS.push("mode_ask", value: %{mode: mode})}
        >
          <span class="q-mode-dot" aria-hidden="true"></span>
          <span class="q-mode-h">
            <.icon name={icon} class="size-4 text-faint" />{name}
            <.badge :if={@mode == mode && !@floor}>{gettext("Workspace default")}</.badge>
            <span :if={@mode == mode && @floor} id={"#{@id}-required"} class="contents">
              <.badge>
                <.icon name="hero-lock-closed-micro" class="size-3" />{gettext(
                  "Required by %{name}",
                  name: @floor.name
                )}
              </.badge>
            </span>
          </span>
          <span id={"#{@id}-#{mode}-p"} class="q-mode-p">{sentence}</span>
          <span :if={@mode == mode && (@fact || !@served)} id={"#{@id}-fact"} class="q-mode-fact">
            <.mode_fact
              scope={@scope}
              fact={if @served, do: @fact, else: :unserved}
              following={if @own != [], do: @following}
            />
          </span>
        </button>
      </div>
      <p :if={@floor} id={"#{@id}-under"} class="text-[12.5px]/[18px] text-faint">
        {gettext("No workspace or target may observe: %{name} requires enforce.", name: @floor.name)}
        <.rich text={floor_own_sentence(@scope, @own, @following)} />
        {gettext(
          "A wall's own refusals (the machine's address, a path that reads two ways) hold in either mode."
        )}
      </p>
      <p :if={!@floor} id={"#{@id}-under"} class="text-[12.5px]/[18px] text-faint">
        {gettext("This is the workspace's default.")}
        <.rich text={own_sentence(@scope, @own, @following)} />
        {gettext(
          "A wall's own refusals (the machine's address, a path that reads two ways) hold in either mode."
        )}
        <span :if={!@can_edit} id={"#{@id}-owners"}>{gettext("Only an owner or an admin sets a mode.")}</span>
      </p>
    </section>
    """
  end

  # Under a required mode, the targets that set observe for themselves are said to be
  # out of force, with the link to them.
  defp floor_own_sentence(scope, own, following) do
    case Enum.count(own, &(&1 == "observe")) do
      0 ->
        []

      n ->
        rich_gettext("%{own} is not in force.",
          own:
            {:link, ~p"/#{scope.organisation}/#{scope.workspace}/policy/targets?mode=own",
             ngettext(
               "The own observe of 1 of %{number} targets",
               "The own observe of %{n} of %{number} targets",
               n,
               n: Format.number(n),
               number: Format.number(following + length(own))
             )}
        )
    end
  end

  @doc """
  The line under a policy page's title where a level above the workspace holds
  (`Apiary.Policy.Above`): its tile and name, how many rules it has, whether it requires
  enforce and whether it allows only its own hosts, and the way to it where the edition
  gives one (`link`, `c:ApiaryWeb.Edition.above_policy_link/1`). Nothing without a level.
  """
  attr :id, :string, default: "policy-above"
  attr :above, :any, required: true, doc: "the `Apiary.Policy.Above`, or nil"
  attr :link, :any, default: nil, doc: "`%{path:, can_change:}` or nil"

  def above_line(%{above: nil} = assigns), do: ~H""

  def above_line(assigns) do
    assigns =
      assign(assigns,
        rules: Enum.count(assigns.above.rules, &(&1.kind == "host")),
        tile: String.first(assigns.above.name || "?")
      )

    ~H"""
    <p id={@id} class="q-above">
      <span class="q-tile" aria-hidden="true">{@tile}</span>
      <span>
        {pngettext(
          "plain",
          "%{name}'s policy applies here: %{number} rule",
          "%{name}'s policy applies here: %{number} rules",
          @rules,
          name: @above.name,
          number: Format.number(@rules)
        )}<span :if={@above.floor}>, {gettext("enforce required")}</span><span :if={
          !@above.own_allows
        }>, {gettext(
            "only its own hosts allowed"
          )}</span>.
      </span>
      <.link :if={@link} id={"#{@id}-view"} navigate={@link.path} class="q-above-link">
        {gettext("View it")}
      </.link>
    </p>
    """
  end

  # Whether the targets follow the default: a whole sentence per case, the count a link to
  # the targets that set their own.
  defp own_sentence(_scope, [], _following),
    do: [
      gettext(
        "A target follows it unless an owner or an admin sets a mode of its own: none does."
      )
    ]

  defp own_sentence(scope, [mode], following) do
    own =
      {:link, ~p"/#{scope.organisation}/#{scope.workspace}/policy/targets?mode=own",
       ngettext("1 of %{number} target does", "1 of %{number} targets does", following + 1,
         number: Format.number(following + 1)
       )}

    if mode == "observe",
      do:
        rich_gettext(
          "A target follows it unless an owner or an admin sets a mode of its own: %{own}, and observes.",
          own: own
        ),
      else:
        rich_gettext(
          "A target follows it unless an owner or an admin sets a mode of its own: %{own}, and enforces.",
          own: own
        )
  end

  defp own_sentence(scope, modes, following) do
    observe = Enum.count(modes, &(&1 == "observe"))
    enforce = length(modes) - observe

    own =
      {:link, ~p"/#{scope.organisation}/#{scope.workspace}/policy/targets?mode=own",
       ngettext(
         "%{number} of %{total} target do",
         "%{number} of %{total} targets do",
         following + length(modes),
         number: Format.number(length(modes)),
         total: Format.number(following + length(modes))
       )}

    cond do
      enforce == 0 ->
        rich_gettext(
          "A target follows it unless an owner or an admin sets a mode of its own: %{own}, and observe.",
          own: own
        )

      observe == 0 ->
        rich_gettext(
          "A target follows it unless an owner or an admin sets a mode of its own: %{own}, and enforce.",
          own: own
        )

      true ->
        rich_gettext(
          "A target follows it unless an owner or an admin sets a mode of its own: %{own}: %{observe}, %{enforce}.",
          own: own,
          observe:
            ngettext("%{number} observes", "%{number} observe", observe,
              number: Format.number(observe)
            ),
          enforce:
            ngettext("%{number} enforces", "%{number} enforce", enforce,
              number: Format.number(enforce)
            )
        )
    end
  end

  attr :fact, :any, required: true
  attr :following, :integer, default: nil, doc: "the targets that follow, when some do not"
  attr :scope, :map, required: true

  defp mode_fact(%{fact: :loading} = assigns) do
    ~H|<span class="skeleton q-skel inline-block w-64 align-middle"></span>|
  end

  defp mode_fact(%{fact: :unserved} = assigns) do
    ~H"""
    {pgettext("plain", "Not served yet: it applies from the first change here.")}
    """
  end

  defp mode_fact(%{fact: :none} = assigns) do
    ~H"""
    {gettext("No run has reached out in the last 7 days.")}
    """
  end

  defp mode_fact(%{fact: %{denied: _}} = assigns) do
    ~H"""
    <.rich text={denied_sentence(@fact)} />
    <.link
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/network?decision=denied&since=7d"}
      class="q-link"
    >
      {gettext("See them")}
    </.link>
    """
  end

  defp mode_fact(%{fact: %{uncovered: _}} = assigns) do
    ~H"""
    <.rich text={uncovered_sentence(@fact, @following)} />
    {gettext("Enforce would deny them.")}
    <.link
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/network?since=7d"}
      class="q-link"
    >
      {gettext("See them")}
    </.link>
    """
  end

  defp denied_sentence(fact) do
    rich_gettext("In the last 7 days it denied %{attempts} to %{destinations}.",
      attempts: attempts(fact.denied),
      destinations: destinations(fact.destinations)
    )
  end

  defp uncovered_sentence(fact, nil) do
    rich_gettext("In the last 7 days %{attempts} to %{destinations} had no rule.",
      attempts: attempts(fact.uncovered),
      destinations: destinations(fact.destinations)
    )
  end

  defp uncovered_sentence(fact, following) do
    rich_ngettext(
      "In the last 7 days %{attempts} to %{destinations} had no rule, in the %{number} target that follows it.",
      "In the last 7 days %{attempts} to %{destinations} had no rule, in the %{number} targets that follow it.",
      following,
      attempts: attempts(fact.uncovered),
      destinations: destinations(fact.destinations),
      number: Format.number(following)
    )
  end

  defp attempts(n),
    do:
      rich_ngettext("%{number} attempt", "%{number} attempts", n, number: {:b, Format.number(n)})

  defp destinations(n),
    do:
      rich_ngettext("%{number} destination", "%{number} destinations", n,
        number: {:b, Format.number(n)}
      )

  ## Target mode

  @doc """
  A target's mode, one line: the choice of following the workspace (by its name), observe
  or enforce, then whose the mode is (its own, who set it and when, and what the workspace
  does; or the workspace's) and what the mode in effect does. A radio sends
  `target_mode_ask`; for a reader who may not set a mode the others are `aria-disabled`.
  """
  attr :id, :string, required: true
  attr :setting, :string, required: true, values: ~w(follow observe enforce)
  attr :effective, :string, required: true, values: ~w(observe enforce)
  attr :workspace_default, :string, required: true, values: ~w(observe enforce)
  attr :workspace, :string, required: true, doc: "the workspace's name"

  attr :set, :any,
    default: nil,
    doc: "who set the target's own mode and when, `%{by:, at:}`, or nil when unknown"

  attr :can_edit, :boolean,
    default: false,
    doc: "whether the reader may set the mode (`security_policy.set_mode`)"

  attr :floor, :any,
    default: nil,
    doc: "`%{name:}` where the level above the workspace requires enforce: the radios are fixed"

  def target_mode(assigns) do
    assigns =
      if assigns.floor,
        do: assign(assigns, own: assigns.setting, setting: "enforce", can_edit: false),
        else: assign(assigns, own: nil)

    ~H"""
    <section id={@id} class="q-modeline" aria-labelledby={"#{@id}-h"} data-floor={@floor && "true"}>
      <h2 id={"#{@id}-h"} class="q-modeline-h">{gettext("Mode")}</h2>
      <div
        id={"#{@id}-radios"}
        class="q-seg q-modeline-seg"
        role="radiogroup"
        aria-labelledby={"#{@id}-h"}
        aria-describedby={"#{@id}-effect"}
        data-roving
      >
        <button
          :for={
            {setting, label, icon} <- [
              {"follow", gettext("Follow %{workspace}", workspace: @workspace),
               "hero-arrow-uturn-left-micro"},
              {"observe", gettext("Observe"), "hero-eye-micro"},
              {"enforce", gettext("Enforce"), "hero-shield-exclamation-micro"}
            ]
          }
          id={"#{@id}-#{setting}"}
          type="button"
          role="radio"
          aria-checked={to_string(@setting == setting)}
          aria-disabled={!@can_edit && @setting != setting && "true"}
          tabindex={if @setting == setting, do: "0", else: "-1"}
          phx-click={
            @can_edit && @setting != setting &&
              JS.push("target_mode_ask", value: %{setting: setting})
          }
        >
          <.icon name={icon} class="size-3.5" />{label}
        </button>
      </div>
      <span :if={@floor} id={"#{@id}-required"} class="q-modeline-req">
        <.icon name="hero-lock-closed-micro" class="size-3" />{gettext("Required by %{name}",
          name: @floor.name
        )}
      </span>
      <p :if={@floor} id={"#{@id}-effect"} class="q-modeline-p">
        <.rich text={floor_sentence(@own, @set, @floor.name)} />
      </p>
      <p :if={!@floor} id={"#{@id}-effect"} class="q-modeline-p">
        <.rich text={whose_sentence(@setting, @workspace_default, @workspace, @set)} />
        {effect_sentence(@effective, @workspace)}
        <span :if={!@can_edit} id={"#{@id}-owners"}>{gettext("Only an owner or an admin sets a mode.")}</span>
      </p>
    </section>
    """
  end

  # Under a required mode: a target's own observe is kept and said to be out of force;
  # its own enforce, or following the workspace, is what holds anyway.
  defp floor_sentence("observe", %{by: by, at: %DateTime{} = at}, name) when is_binary(by),
    do:
      rich_gettext(
        "Its own observe, set by %{by} %{when}, is not in force: %{name} requires enforce.",
        by: {:b, by},
        when: when_words(at),
        name: name
      )

  defp floor_sentence("observe", _set, name),
    do: [gettext("Its own observe is not in force: %{name} requires enforce.", name: name)]

  defp floor_sentence(_setting, _set, name),
    do: [gettext("%{name} requires enforce in every workspace and target.", name: name)]

  # Whose the mode is: the workspace's, or the target's own with who set it and when; a
  # whole sentence per case, the workspace's mode a verb of its own.
  defp whose_sentence("follow", "enforce", workspace, _set),
    do: [gettext("It follows %{workspace}, which enforces.", workspace: workspace)]

  defp whose_sentence("follow", _observe, workspace, _set),
    do: [gettext("It follows %{workspace}, which observes.", workspace: workspace)]

  defp whose_sentence(_own, default, workspace, %{by: by, at: %DateTime{} = at})
       when is_binary(by) do
    if default == "enforce",
      do:
        rich_gettext("Its own, set by %{by} %{when}; %{workspace} enforces.",
          by: {:b, by},
          when: when_words(at),
          workspace: workspace
        ),
      else:
        rich_gettext("Its own, set by %{by} %{when}; %{workspace} observes.",
          by: {:b, by},
          when: when_words(at),
          workspace: workspace
        )
  end

  defp whose_sentence(_own, "enforce", workspace, _set),
    do: [gettext("Its own; %{workspace} enforces.", workspace: workspace)]

  defp whose_sentence(_own, _observe, workspace, _set),
    do: [gettext("Its own; %{workspace} observes.", workspace: workspace)]

  defp when_words(at) do
    case Format.days_back(at, DateTime.utc_now()) do
      0 -> gettext("today")
      1 -> gettext("yesterday")
      _ -> gettext("on %{date}", date: Format.day(at))
    end
  end

  defp effect_sentence("observe", workspace),
    do:
      gettext(
        "What no rule names is let through and recorded; a deny rule holds, and so do %{workspace}'s locked rules.",
        workspace: workspace
      )

  defp effect_sentence(_enforce, _workspace),
    do: gettext("A connection no rule allows is denied.")

  ## Rule composer

  @doc """
  The composer of a host rule: a line over the list of rules, opened by Add rule, never a
  modal. The reading line under the fields reads the rule back; the button is off until
  the reading is `:ok` or `:note`. Cancel sends `composer_close`.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true, doc: "action, host, paths, every"
  attr :scope, :atom, required: true, values: [:workspace, :target]
  attr :reading, :map, default: nil
  attr :queued, :integer, default: 0, doc: "pasted hosts still to add"
  attr :class, :any, default: nil

  attr :host_placeholder, :string,
    default: nil,
    doc: "nil says \"api.example or *.internal.example\""

  def rule_composer(assigns) do
    reading =
      assigns.reading || %{kind: :hint, text: [], fix: nil, acts: [], invalid: [], button: nil}

    deny? = assigns.form[:action].value == "deny"

    assigns =
      assigns
      |> assign(:reading, reading)
      |> assign(:deny?, deny?)
      |> assign(:every?, assigns.form[:every].value == "true")
      |> assign(:ready?, reading.kind in [:ok, :note])

    ~H"""
    <.form
      for={@form}
      id={@id}
      class={["q-composer", @class]}
      aria-label={
        if @scope == :workspace,
          do: gettext("Add a host rule"),
          else: gettext("Add a rule for this target")
      }
      phx-change="composer_change"
      phx-submit="composer_save"
      phx-hook="RuleComposer"
      autocomplete="off"
    >
      <input type="hidden" name={@form[:action].name} value={@form[:action].value} />
      <input type="hidden" name={@form[:every].name} value={@form[:every].value} />
      <div class="q-seg q-composer-seg" role="group" aria-label={gettext("Action")}>
        <button
          type="button"
          aria-pressed={to_string(!@deny?)}
          phx-click={JS.push("composer_action", value: %{action: "allow"})}
        >
          {gettext("Allow")}
        </button>
        <button
          type="button"
          class="q-seg-deny"
          aria-pressed={to_string(@deny?)}
          phx-click={JS.push("composer_action", value: %{action: "deny"})}
        >
          {gettext("Deny")}
        </button>
      </div>
      <label>
        <span class="sr-only">{gettext("Host")}</span>
        <input
          type="text"
          id={"#{@id}-host"}
          name={@form[:host].name}
          value={@form[:host].value}
          class="q-input q-input-m"
          placeholder={@host_placeholder || gettext("api.example or *.internal.example")}
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          autocorrect="off"
          maxlength="300"
          phx-debounce="150"
          aria-invalid={:host in @reading.invalid && "true"}
          aria-describedby={"#{@id}-reads"}
        />
      </label>
      <label>
        <span class="sr-only">{gettext("Paths, optional")}</span>
        <input
          type="text"
          id={"#{@id}-paths"}
          name={@form[:paths].name}
          value={if @deny?, do: "", else: @form[:paths].value}
          class="q-input q-input-m"
          placeholder={
            cond do
              @deny? -> gettext("A deny is of the whole host")
              @every? -> gettext("Every path")
              true -> gettext("Every path, or /v1/* /health")
            end
          }
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          autocorrect="off"
          maxlength="4000"
          phx-debounce="150"
          disabled={@deny?}
          aria-invalid={:paths in @reading.invalid && "true"}
          aria-describedby={"#{@id}-reads"}
        />
      </label>
      <span class="q-composer-go">
        <.button id={"#{@id}-cancel"} type="button" phx-click="composer_close">
          {gettext("Cancel")}
        </.button>
        <.button type="submit" variant="primary" id={"#{@id}-add"} disabled={!@ready?}>
          {@reading.button ||
            if(@scope == :workspace, do: gettext("Add rule"), else: gettext("Add for this target"))}
        </.button>
      </span>
      <.reading_line id={"#{@id}-reads"} reading={@reading} queued={@queued} />
    </.form>
    """
  end

  @doc "The composer of a credential: a name and an optional argument, a default button."
  attr :id, :string, required: true
  attr :form, :any, required: true, doc: "name, argument"
  attr :reading, :map, default: nil
  attr :class, :any, default: nil

  def credential_composer(assigns) do
    reading =
      assigns.reading || %{kind: :hint, text: [], fix: nil, acts: [], invalid: [], button: nil}

    assigns = assign(assigns, reading: reading, ready?: reading.kind in [:ok, :note])

    ~H"""
    <.form
      for={@form}
      id={@id}
      class={["q-composer q-composer-cred", @class]}
      aria-label={gettext("Add a credential")}
      phx-change="credential_change"
      phx-submit="credential_save"
      autocomplete="off"
    >
      <label>
        <span class="sr-only">{gettext("Name")}</span>
        <input
          type="text"
          id={"#{@id}-name"}
          name={@form[:name].name}
          value={@form[:name].value}
          class="q-input q-input-m"
          placeholder={gettext("Name, such as system-token")}
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          maxlength="80"
          phx-debounce="150"
          aria-invalid={:name in @reading.invalid && "true"}
          aria-describedby={"#{@id}-reads"}
        />
      </label>
      <label>
        <span class="sr-only">{gettext("Argument, optional")}</span>
        <input
          type="text"
          id={"#{@id}-argument"}
          name={@form[:argument].name}
          value={@form[:argument].value}
          class="q-input q-input-m"
          placeholder={gettext("Argument (optional), such as acme/shop")}
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          maxlength="300"
          phx-debounce="150"
          aria-invalid={:argument in @reading.invalid && "true"}
          aria-describedby={"#{@id}-reads"}
        />
      </label>
      <.button type="submit" id={"#{@id}-add"} disabled={!@ready?}>
        {@reading.button || gettext("Add credential")}
      </.button>
      <.reading_line
        :if={@reading.kind in [:error, :note, :refusal]}
        id={"#{@id}-reads"}
        reading={@reading}
      />
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :reading, :map, required: true
  attr :queued, :integer, default: 0

  defp reading_line(%{reading: %{kind: :refusal}} = assigns) do
    ~H"""
    <div id={@id} class="q-refusal" role="alert">
      <.notice kind={:error}>
        <.rich text={@reading.text} />
        <span :if={@reading.acts != []} class="q-notice-acts">
          <.reading_act :for={act <- @reading.acts} act={act} />
        </span>
      </.notice>
    </div>
    """
  end

  defp reading_line(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "q-reads",
        @reading.kind == :ok && "q-reads-ok",
        @reading.kind == :error && "q-reads-bad"
      ]}
      role={if @reading.kind == :error, do: "alert", else: "status"}
    >
      <.icon name={reading_icon(@reading.kind)} class="size-3.5" />
      <span>
        <.rich text={@reading.text} />
        <.reading_act :if={@reading.fix} act={@reading.fix} />
        <span :if={@queued > 0} id={"#{@id}-queued"} class="q-reads-queued">
          {ngettext("%{number} more to add", "%{number} more to add", @queued,
            number: Format.number(@queued)
          )}
        </span>
      </span>
    </div>
    """
  end

  attr :act, :any, required: true

  defp reading_act(%{act: {label, event, values}} = assigns) do
    assigns = assign(assigns, label: label, event: event, values: values)

    ~H"""
    <button type="button" class="q-link q-reads-fix" phx-click={JS.push(@event, value: @values)}>
      {@label}
    </button>
    """
  end

  defp reading_icon(:ok), do: "hero-check-micro"
  defp reading_icon(:error), do: "hero-exclamation-triangle-micro"
  defp reading_icon(_hint_or_note), do: "hero-information-circle-micro"

  ## The list of rules

  @doc """
  A list of host rules on the list pattern (docs/ui.md, Lists), the Network access section
  of the workspace's policy page and of a target's Policy tab: the views with their counts,
  the search with the Filter menu, Sort and Add rule, the filters in force as tokens and how
  many rules match, the composer when it is open (the slot), one line a rule
  (`rule_line/1`) and the pages. The query is `ApiaryWeb.PolicyLive.RuleList`'s, and every
  control is a patch of the URL `path` gives a query; the search sends `rules_search`.

  `listing` is what `ApiaryWeb.PolicyLive.RuleList.list/3` answered; `activity` is
  `:loading`, `:unavailable` (the use is not shown, never faked) or the map of
  `Apiary.Policy.rule_activity/3`.
  """
  attr :id, :string, required: true, doc: "the table's region; the controls' ids start with it"
  attr :label, :string, required: true, doc: "the table's accessible name"
  attr :listing, :map, required: true
  attr :query, :any, required: true
  attr :path, :any, required: true, doc: "the URL of a query"
  attr :sections, :list, required: true, doc: "the Filter menu's, `RuleList.sections/2`"
  attr :default_sort, :string, required: true, doc: "the list's own order, in words"
  attr :activity, :any, default: :unavailable
  attr :source, :boolean, default: false, doc: "show where each rule is written"
  attr :can_add, :boolean, default: false, doc: "the reader may add a rule: Add rule shows"
  attr :adding, :boolean, default: false, doc: "the composer is open"
  attr :can_lock, :boolean, default: false
  attr :fresh, :any, default: %{}, doc: "%{rule id => version}: new in the version in force"
  attr :ruled_host, :string, default: nil, doc: "the host `?rule=` points at"
  attr :empty, :string, default: nil, doc: "the line of a list with no rule at all"

  attr :views, :list,
    default: [:all, :allow, :deny, :locked],
    doc: "the views shown, of `:all`, `:allow`, `:deny` and `:locked`"

  attr :use_label, :string, default: nil, doc: "the use column's heading; the last 14 days"
  slot :composer

  def rule_list(assigns) do
    listing = assigns.listing

    assigns =
      assign(assigns,
        seen?: is_map(assigns.activity),
        off?: Enum.any?(listing.rows, & &1.off),
        used?: assigns.activity != :unavailable,
        use_label: assigns.use_label || gettext("Last 14 days")
      )

    ~H"""
    <.views id={"#{@id}-views"} label={gettext("Views")}>
      <:view
        :for={{view, word, label, count} <- rule_views(@listing.counts, @views)}
        id={"#{@id}-view-#{word}"}
        patch={@path.(%{@query | view: view, page: 1})}
        current={@query.view == view}
        count={Format.number(count)}
      >
        {label}
      </:view>
    </.views>

    <div id={"#{@id}-bar"} class="q-bar q-pr-bar">
      <.list_search
        id={"#{@id}-query"}
        class="q-find-query"
        label={gettext("Find a host")}
        placeholder={gettext("Find a host, e.g. *.github.example seen:no")}
        value={@query.text}
        change="rules_search"
      />
      <.filter_menu id={"#{@id}-filter"} count={length(@query.tokens)}>
        <%= for section <- @sections do %>
          <.menu_heading title={section.title} />
          <.menu_item
            :for={{item, n} <- Enum.with_index(section.items)}
            id={"#{@id}-filter-#{section.key}-#{n}"}
            patch={@path.(RuleList.toggle(@query, item.token))}
            checked={item.token in @query.tokens}
            hint={
              ngettext("%{number} rule", "%{number} rules", item.count,
                number: Format.number(item.count)
              )
            }
          >
            <span class={section.key == "by" && "font-mono"}>{item.label}</span>
          </.menu_item>
        <% end %>
      </.filter_menu>
      <.sort_menu id={"#{@id}-sort"} current={sort_words(@query.sort, @default_sort)}>
        <.menu_item
          :for={sort <- RuleList.sorts()}
          :if={sort != :used or @used?}
          id={"#{@id}-sort-#{sort}"}
          patch={@path.(%{@query | sort: sort, page: 1})}
          checked={@query.sort == sort}
        >
          {sort_words(sort, @default_sort)}
        </.menu_item>
      </.sort_menu>
      <.button
        :if={@can_add}
        id={"#{@id}-add"}
        phx-click="composer_open"
        aria-expanded={to_string(@adding)}
      >
        <.icon name="hero-plus-micro" class="size-4 text-faint" />{gettext("Add rule")}
      </.button>
    </div>

    <.filter_tokens
      id={"#{@id}-tokens"}
      clear={RuleList.narrowed?(@query) && @path.(RuleList.clear(@query))}
    >
      <:token
        :for={token <- @query.tokens}
        id={"#{@id}-token-#{elem(token, 0)}"}
        class="q-tok-q"
        patch={@path.(RuleList.toggle(@query, token))}
        label={gettext("Remove %{token}", token: RuleList.token_text(token))}
      >
        <span class="q-tok-k">{token_key(token)}:</span>{token_value(token)}
      </:token>
    </.filter_tokens>

    {render_slot(@composer)}

    <%!-- Always there, so a screen reader hears what a view or the search left. --%>
    <div id={"#{@id}-status"} role="status" class="q-status">
      <p :if={@listing.match && !@listing.loading} id={"#{@id}-summary"} class="q-matchline">
        <.rich text={
          rich_ngettext("%{number} rule matches", "%{number} rules match", @listing.match,
            number: {:b, Format.number(@listing.match)}
          )
        } />
        <.link
          :if={@query.tokens == []}
          id={"#{@id}-clear"}
          patch={@path.(RuleList.clear(@query))}
          class="q-tok-clear"
        >
          {gettext("Clear")}
        </.link>
        <span :if={@listing.unseen} id={"#{@id}-unseen"}>
          {gettext("The use of the last 14 days could not be counted, so seen: narrows nothing.")}
        </span>
      </p>
      <p
        :if={
          !@listing.loading && @listing.rows == [] &&
            (RuleList.narrowed?(@query) or @query.view != :all)
        }
        class="sr-only"
      >
        {gettext("No rule matches.")}
      </p>
      <p
        :if={!@listing.loading && !@listing.match && @listing.rows != [] && @query.view != :all}
        class="sr-only"
      >
        {ngettext("%{number} rule matches", "%{number} rules match", @listing.total,
          number: Format.number(@listing.total)
        )}
      </p>
    </div>

    <div
      id={@id}
      class="q-tbl q-pr-wrap overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
      tabindex="0"
      role="region"
      aria-label={@label}
      aria-busy={@listing.loading && "true"}
    >
      <table class="table q-pr">
        <thead>
          <tr>
            <th scope="col" class="q-pr-mk">
              <span class="sr-only">{gettext("Allow or deny")}</span>
            </th>
            <th scope="col">{gettext("Host")}</th>
            <th scope="col">{gettext("Paths")}</th>
            <th :if={@source} scope="col">{gettext("Source")}</th>
            <th :if={@seen? or @off?} scope="col" class="q-from-sm">{@use_label}</th>
            <th scope="col" class="q-from-md">{gettext("Added")}</th>
            <th scope="col" class="q-pr-acts"><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={n <- if(@listing.loading, do: 1..6, else: [])}>
            <td class="q-pr-mk"></td>
            <td>
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-44", else: "w-36")]}></span>
            </td>
            <td><span class="skeleton q-skel w-16"></span></td>
            <td :if={@source}><span class="skeleton q-skel w-20"></span></td>
            <td :if={@seen? or @off?} class="q-from-sm">
              <span class="skeleton q-skel w-16"></span>
            </td>
            <td class="q-from-md"><span class="skeleton q-skel w-24"></span></td>
            <td class="q-pr-acts"></td>
          </tr>
          <tr :if={!@listing.loading && @listing.rows == []}>
            <td colspan="7" class="q-pr-none">
              {if RuleList.narrowed?(@query) or @query.view != :all or !@empty,
                do: gettext("No rule matches."),
                else: @empty}
            </td>
          </tr>
          <.rule_line
            :for={row <- @listing.rows}
            id={"rule-#{row.id}"}
            rule={row}
            source={@source}
            use?={@seen? or @off?}
            seen={@seen? && seen_of(@activity, row)}
            can_lock={@can_lock}
            fresh={Map.get(@fresh, row.id)}
            ruled={@ruled_host != nil && @ruled_host == row.host}
          />
        </tbody>
      </table>
    </div>

    <RunComponents.pager
      :if={!@listing.loading && @listing.total > 0}
      id={"#{@id}-pages"}
      prefix={"#{@id}-pages"}
      first={@listing.first}
      last={@listing.last}
      total={@listing.total}
      previous={@listing.page > 1 && @path.(%{@query | page: @listing.page - 1})}
      next={@listing.page < @listing.pages && @path.(%{@query | page: @listing.page + 1})}
      previous_label={gettext("Previous")}
      next_label={gettext("Next")}
    />
    """
  end

  # The views, each with the word the URL writes it with, those the list shows.
  defp rule_views(counts, views) do
    Enum.filter(
      [
        {:all, "all", gettext("All"), counts.all},
        {:allow, "allowed", gettext("Allowed"), counts.allow},
        {:deny, "denied", gettext("Denied"), counts.deny},
        {:locked, "locked", gettext("Locked"), counts.locked}
      ],
      fn {view, _word, _label, _count} -> view in views end
    )
  end

  defp sort_words(:default, default), do: default
  defp sort_words(:host, _default), do: gettext("Host")
  defp sort_words(:used, _default), do: gettext("Most used")
  defp sort_words(:recent, _default), do: gettext("Recently added")

  defp token_key(token), do: token |> RuleList.token_text() |> String.split(":", parts: 2) |> hd()

  defp token_value(token),
    do: token |> RuleList.token_text() |> String.split(":", parts: 2) |> List.last()

  defp seen_of(activity, row), do: Map.get(activity, row.id, %{allowed: 0, denied: 0})

  @doc """
  One rule, one line (docs/ui.md, Lists): its mark, the host in mono (the title), its paths,
  where it is written (`source`), its use in the last 14 days, who added it and when, a
  faint lock when it is locked, and its ⋯ menu. A rule not in force is struck, and says why
  where its use would be.

  `rule` is a map (`ApiaryWeb.PolicyLive.Common`): `id`, `action`, `host`, `paths`,
  `locked`, `source` (`%{key:, label:, rank:}`, with `tile`, a letter drawn before the
  label, for the level above the workspace), `own` (written where the page is: it is
  changed here), `above` (a rule of the level above the workspace: the lock glyph with
  `locked_tip`'s words), `in_force`, `off` (why it is not in force, or nil), `by`, `at`,
  `locked_tip` (what the lock says), `can_change` (the reader may change it here), `act`
  (what Remove does: `:remove`, or `:restore` where a target's own rule gives the
  workspace's back) and `view` (`{label, path}`: where a rule written elsewhere is changed,
  or nil). The menu of the page's own rule: Edit paths, the other action, Lock or Unlock
  for an owner on the workspace's page, Remove; of a rule written elsewhere, the way to it.
  """
  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :source, :boolean, default: false
  attr :use?, :boolean, default: false, doc: "the use column is shown"
  attr :seen, :any, default: nil, doc: "`%{allowed:, denied:}`, or nil when not counted"
  attr :can_lock, :boolean, default: false
  attr :fresh, :any, default: nil
  attr :ruled, :boolean, default: false

  def rule_line(assigns) do
    rule = assigns.rule

    assigns =
      assign(assigns,
        menu?: (rule.own and rule.can_change) or (not rule.own and rule.view != nil),
        lockable?: assigns.can_lock and rule.own and rule.in_force,
        glyph?: rule.locked or rule[:above] == true,
        tile: rule.source[:tile]
      )

    ~H"""
    <tr
      id={@id}
      class={[
        "q-pr-row",
        @fresh && "q-fresh",
        @ruled && "q-ruled",
        !@rule.in_force && "q-pr-off"
      ]}
    >
      <td class="q-pr-mk"><.rule_mark action={@rule.action} /></td>
      <td class="q-pr-host" title={@rule.off}>
        <.host host={@rule.host} class="q-pr-h" />
        <span :if={@rule.off} class="sr-only">. {@rule.off}</span>
        <span :if={@fresh} class="q-newdot">{gettext("New in v%{version}", version: @fresh)}</span>
      </td>
      <td class="q-pr-paths"><.paths paths={@rule.paths} action={@rule.action} /></td>
      <td :if={@source} class="q-pr-src">
        <span :if={@tile} class="q-tile" aria-hidden="true">{@tile}</span>{@rule.source.label}
      </td>
      <td :if={@use?} class="q-pr-use q-from-sm">
        <span :if={@rule.off} class="q-pr-offw q-pr-offw-full" title={@rule.off} aria-hidden="true">
          {@rule.off}
        </span>
        <span :if={@rule.off} class="q-pr-offw q-pr-offw-short" title={@rule.off} aria-hidden="true">
          {gettext("Not in force")}
        </span>
        <.seen :if={!@rule.off && @seen} seen={@seen} />
      </td>
      <td class="q-pr-by q-from-md">
        {@rule.by}<span :if={@rule.by && @rule.at}> · </span>{@rule.at && Format.day(@rule.at)}
      </td>
      <td class="q-pr-acts">
        <span
          :if={@glyph?}
          id={"#{@id}-lock"}
          class="q-pr-lock tooltip tooltip-left q-tip-wide"
          tabindex="0"
          aria-description={@rule.locked_tip}
          data-tip={@rule.locked_tip}
        ><.icon name="hero-lock-closed-micro" class="size-3" /><span class="sr-only">{gettext(
          "Locked"
        )}</span></span>
        <.row_menu
          :if={@menu?}
          id={"#{@id}-menu"}
          class="q-hov"
          label={gettext("Actions for %{host}", host: @rule.host)}
        >
          <%= if @rule.own do %>
            <.menu_item
              :if={@rule.action == "allow" && @rule.in_force}
              id={"#{@id}-paths"}
              phx-click={JS.push("edit_paths", value: %{id: @rule.id})}
            >
              {gettext("Edit paths")}
            </.menu_item>
            <.menu_item
              :if={@rule.in_force}
              id={"#{@id}-change"}
              phx-click={JS.push("change_action", value: %{id: @rule.id})}
            >
              {if @rule.action == "allow",
                do: gettext("Change to deny"),
                else: gettext("Change to allow")}
            </.menu_item>
            <.menu_item
              :if={@lockable?}
              id={"#{@id}-lock-toggle"}
              phx-click={JS.push("lock_toggle", value: %{id: @rule.id})}
            >
              {if @rule.locked, do: gettext("Unlock"), else: gettext("Lock")}
            </.menu_item>
            <.menu_divider :if={@rule.in_force} />
            <.menu_item
              id={"#{@id}-remove"}
              phx-click={JS.push("remove", value: %{id: @rule.id})}
            >
              {gettext("Remove")}
            </.menu_item>
          <% else %>
            <.menu_item id={"#{@id}-view"} navigate={elem(@rule.view, 1)}>
              {elem(@rule.view, 0)}
            </.menu_item>
          <% end %>
        </.row_menu>
      </td>
    </tr>
    """
  end

  @doc "A host in mono; the leading `*.` of a suffix in accent, with what it means on hover."
  attr :host, :string, required: true
  attr :class, :any, default: nil

  def host(%{host: "*." <> suffix} = assigns) do
    assigns = assign(assigns, :suffix, suffix)

    ~H"""
    <span
      class={["q-host tooltip q-tip-wide", @class]}
      tabindex="0"
      aria-description={
        gettext("Every host below %{suffix}, and not %{suffix} itself.", suffix: @suffix)
      }
      data-tip={gettext("Every host below %{suffix}, and not %{suffix} itself.", suffix: @suffix)}
    ><span class="q-host-w">*.</span>{@suffix}</span>
    """
  end

  def host(assigns) do
    ~H|<span class={["q-host", @class]}>{@host}</span>|
  end

  attr :paths, :any, required: true
  attr :action, :string, default: "allow"

  defp paths(%{action: "deny"} = assigns),
    do: ~H|<span class="q-every">{gettext("every path")}</span>|

  defp paths(%{paths: nil} = assigns),
    do: ~H|<span class="q-every">{gettext("every path")}</span>|

  defp paths(%{paths: []} = assigns) do
    ~H"""
    <span
      class="q-every tooltip q-tip-wide"
      tabindex="0"
      aria-description={
        gettext("The host is listed with no path: every request to it is denied under enforce.")
      }
      data-tip={
        gettext("The host is listed with no path: every request to it is denied under enforce.")
      }
    >
      {gettext("no path")}
    </span>
    """
  end

  defp paths(assigns) do
    ~H"""
    <span class="q-pr-pth"><code :for={path <- @paths} class="q-rule">{path}</code></span>
    """
  end

  attr :seen, :any, required: true
  attr :noun, :atom, default: nil, values: [nil, :request]

  defp seen(%{seen: %{allowed: 0, denied: 0}} = assigns) do
    ~H|<span class="q-zero">{if @noun == :request, do: gettext("not used"), else: gettext("not seen")}</span>|
  end

  defp seen(%{noun: :request} = assigns) do
    ~H"""
    <span>{requests(@seen.allowed + @seen.denied)}</span>
    """
  end

  defp seen(assigns) do
    ~H"""
    <span :if={@seen.allowed > 0}>
      {gettext("%{number} allowed", number: Format.number(@seen.allowed))}
    </span>
    <span :if={@seen.allowed > 0 && @seen.denied > 0}> · </span>
    <span :if={@seen.denied > 0}>
      {gettext("%{number} denied", number: Format.number(@seen.denied))}
    </span>
    <span class="sr-only">{gettext("in the last 14 days")}</span>
    """
  end

  defp requests(n),
    do: ngettext("%{number} request", "%{number} requests", n, number: Format.number(n))

  @doc """
  The credentials of a scope, one line each on the list's look: the name (the title), its
  argument, where it is written (`source`), its use in the last 14 days, who added it and
  when, and its ⋯ menu: Remove for the page's own, the way to it for one written elsewhere.
  Rows: `id`, `name`, `argument`, `action`, `source` (`%{label:}`), `own`, `view`, `by`,
  `at`, `can_change`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :source, :boolean, default: false
  attr :activity, :any, default: :unavailable

  def credentials_table(assigns) do
    assigns = assign(assigns, :seen?, is_map(assigns.activity))

    ~H"""
    <div
      id={@id}
      class="q-tbl q-pr-wrap overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
      tabindex="0"
      role="region"
      aria-label={@label}
    >
      <table class="table q-pr">
        <thead>
          <tr>
            <th scope="col" class="q-pr-mk"><span class="sr-only">{gettext("Kind")}</span></th>
            <th scope="col">{gettext("Name")}</th>
            <th scope="col">{gettext("Argument")}</th>
            <th :if={@source} scope="col">{gettext("Source")}</th>
            <th :if={@seen?} scope="col" class="q-from-sm">{gettext("Last 14 days")}</th>
            <th scope="col" class="q-from-md">{gettext("Added")}</th>
            <th scope="col" class="q-pr-acts"><span class="sr-only">{gettext("Actions")}</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan="7" class="q-pr-none">
              {gettext("No credentials. A run that needs none runs without.")}
            </td>
          </tr>
          <tr :for={row <- @rows} id={"rule-#{row.id}"} class="q-pr-row">
            <td class="q-pr-mk">
              <span class="q-pr-key"><.icon name="hero-key-micro" class="size-3.5" /></span>
            </td>
            <td class="q-pr-host">
              <span class="q-host q-pr-h">{row.name}</span>
              <span :if={row.action == "deny"} class="q-pr-word">{gettext("Denied")}</span>
            </td>
            <td class="q-pr-paths">
              <code :if={row.argument} class="q-rule">{row.argument}</code>
              <span :if={!row.argument} class="q-every">{gettext("no argument")}</span>
            </td>
            <td :if={@source} class="q-pr-src">{row.source.label}</td>
            <td :if={@seen?} class="q-pr-use q-from-sm">
              <.seen seen={seen_of(@activity, row)} noun={:request} />
            </td>
            <td class="q-pr-by q-from-md">
              {row.by}<span :if={row.by && row.at}> · </span>{row.at && Format.day(row.at)}
            </td>
            <td class="q-pr-acts">
              <.row_menu
                :if={(row.own and row.can_change) or (not row.own and row.view != nil)}
                id={"rule-#{row.id}-menu"}
                class="q-hov"
                label={gettext("Actions for %{name}", name: row.name)}
              >
                <.menu_item
                  :if={row.own}
                  id={"rule-#{row.id}-remove"}
                  phx-click={JS.push("remove", value: %{id: row.id})}
                  aria-label={gettext("Remove the credential %{name}", name: row.name)}
                >
                  {gettext("Remove")}
                </.menu_item>
                <.menu_item :if={!row.own} id={"rule-#{row.id}-view"} navigate={elem(row.view, 1)}>
                  {elem(row.view, 0)}
                </.menu_item>
              </.row_menu>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  ## Suggestions

  @doc """
  The hosts the harness declared and the policy does not cover: shown only when there is
  something to review. One click allows for the target; the caret offers the workspace and
  the composer with paths. A suggestion: `%{host:, runs:, last_seen_at:}`; `allowed` holds
  the hosts allowed from this card since the page opened, which stay until navigation.
  """
  attr :id, :string, required: true
  attr :suggestions, :list, required: true
  attr :covered, :list, default: [], doc: "[%{host:, by:, source:}]: declared and already allowed"
  attr :allowed, :any, default: %{}, doc: "%{host => rule id}"

  attr :observing, :boolean,
    default: false,
    doc: "the target observes: a host no rule names is let through"

  attr :above, :string, default: nil, doc: "the name of the level above the workspace, or nil"

  def suggestions(assigns) do
    open = Enum.reject(assigns.suggestions, &Map.has_key?(assigns.allowed, &1.host))
    assigns = assign(assigns, :open, open)

    ~H"""
    <.sect
      :if={@suggestions != []}
      id={@id}
      title={gettext("Declared by the harness")}
      count={
        if @open == [],
          do: gettext("all allowed"),
          else:
            ngettext("%{number} to review", "%{number} to review", length(@open),
              number: Format.number(length(@open))
            )
      }
    >
      <:trailing>
        <button
          :if={length(@open) > 1}
          id={"#{@id}-all"}
          type="button"
          class="btn btn-xs"
          phx-click="suggest_allow_all"
        >
          {if length(@open) == 2,
            do: gettext("Allow both here"),
            else:
              ngettext("Allow all %{number} here", "Allow all %{number} here", length(@open),
                number: Format.number(length(@open))
              )}
        </button>
      </:trailing>
      <:description>
        {gettext(
          "Hosts the runtime says it needs, from the policy applied events of this target's latest runs."
        )}
        {gettext("A declaration allows nothing by itself.")}
      </:description>
      <div :for={suggestion <- @suggestions} id={suggestion_id(suggestion.host)} class="q-sugg-row">
        <span class="q-rcell">
          <.rule_mark action={
            if Map.has_key?(@allowed, suggestion.host), do: "allow", else: "pending"
          } />
          <span class="q-host truncate" title={suggestion.host}>{middle(suggestion.host)}</span>
        </span>
        <span class="q-sugg-what">
          <.rich text={declared_sentence(suggestion.runs)} />
          <.suggestion_record suggestion={suggestion} observing={@observing} />
        </span>
        <span :if={!Map.has_key?(@allowed, suggestion.host)} class="q-sugg-acts">
          <span
            id={"#{suggestion_id(suggestion.host)}-menu"}
            class="q-btn-split dropdown dropdown-end"
            phx-hook="Menu"
            phx-mounted={JS.ignore_attributes(["class"])}
          >
            <button
              id={"#{suggestion_id(suggestion.host)}-allow"}
              type="button"
              class="btn btn-xs"
              phx-click={JS.push("suggest_allow", value: %{host: suggestion.host, level: "target"})}
            >
              {gettext("Allow here")}
            </button>
            <button
              type="button"
              class="btn btn-xs"
              aria-haspopup="menu"
              aria-expanded="false"
              aria-label={gettext("More ways to allow %{host}", host: suggestion.host)}
              phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            >
              <.icon name="hero-chevron-down-micro" class="size-3" />
            </button>
            <ul class="menu menu-sm dropdown-content right-0 z-20 mt-1 w-48" role="menu">
              <li role="none">
                <button
                  type="button"
                  role="menuitem"
                  tabindex="-1"
                  data-menu-close
                  phx-click={
                    JS.push("suggest_allow", value: %{host: suggestion.host, level: "workspace"})
                  }
                >
                  {gettext("Allow for the workspace")}
                </button>
              </li>
              <li role="none">
                <button
                  type="button"
                  role="menuitem"
                  tabindex="-1"
                  data-menu-close
                  phx-click={JS.push("composer_use", value: %{host: suggestion.host, focus: "paths"})}
                >
                  {gettext("Allow with paths…")}
                </button>
              </li>
            </ul>
          </span>
        </span>
        <span :if={Map.has_key?(@allowed, suggestion.host)} class="q-sugg-acts">
          <span class="q-done" id={"#{suggestion_id(suggestion.host)}-done"} tabindex="-1">
            <.icon name="hero-check-micro" class="size-3" />{allowed_where(@allowed[suggestion.host])}
          </span>
        </span>
      </div>
      <:footer :if={@covered != []}>
        <span id={"#{@id}-covered"}><.rich text={covered_sentence(@covered, @above)} /></span>
      </:footer>
    </.sect>
    """
  end

  attr :suggestion, :map, required: true
  attr :observing, :boolean, required: true

  # What the record says of a declared host, when it could be counted; nothing when not.
  defp suggestion_record(%{suggestion: %{allowed: allowed, denied: denied}} = assigns)
       when is_integer(allowed) and is_integer(denied) do
    ~H"""
    <span :if={@suggestion.denied > 0} class="q-bad">
      {gettext("Denied %{times}.", times: times(@suggestion.denied))}
    </span>
    <span :if={@suggestion.allowed > 0}>
      {gettext("Let through %{times} with no rule.", times: times(@suggestion.allowed))}
    </span>
    <span :if={@suggestion.allowed == 0 && @suggestion.denied == 0}>
      {gettext("No run has tried to reach it in the last 7 days.")}
    </span>
    """
  end

  defp suggestion_record(assigns), do: ~H""

  defp declared_sentence(runs) do
    rich_gettext("Declared by the %{harness} in %{runs}.",
      harness: {:term, gettext("harness"), harness_tip()},
      runs: {:b, ngettext("%{number} run", "%{number} runs", runs, number: Format.number(runs))}
    )
  end

  defp times(1), do: gettext("once")

  defp times(n),
    do: ngettext("%{number} time", "%{number} times", n, number: Format.number(n))

  # The declared hosts already allowed, each with what allows it, in one sentence.
  defp covered_sentence(covered, above) do
    rich_ngettext(
      "%{number} more declared host is already allowed: %{hosts}.",
      "%{number} more declared hosts are already allowed: %{hosts}.",
      length(covered),
      hosts: covered |> Enum.map(&covered_by(&1, above)) |> Enum.intersperse(", "),
      number: Format.number(length(covered))
    )
  end

  defp covered_by(%{host: host, by: host, source: :organisation}, above),
    do: rich_gettext("%{host} by %{name}", host: {:code, host}, name: above || "?")

  defp covered_by(%{host: host, by: by, source: :organisation}, above),
    do:
      rich_gettext("%{host} by %{name}'s %{rule}",
        host: {:code, host},
        rule: by,
        name: above || "?"
      )

  defp covered_by(covered, _above), do: covered_by(covered)

  defp covered_by(%{host: host, by: host, source: :workspace}),
    do: rich_gettext("%{host} by the workspace", host: {:code, host})

  defp covered_by(%{host: host, by: host}),
    do: rich_gettext("%{host} by this target", host: {:code, host})

  defp covered_by(%{host: host, by: by, source: :workspace}),
    do: rich_gettext("%{host} by the workspace's %{rule}", host: {:code, host}, rule: by)

  defp covered_by(%{host: host, by: by}),
    do: rich_gettext("%{host} by this target's %{rule}", host: {:code, host}, rule: by)

  defp allowed_where(%{level: "workspace"}), do: gettext("Allowed for the workspace")
  defp allowed_where(_allowed), do: gettext("Allowed here")

  @doc "The DOM id of a suggestion's row."
  def suggestion_id(host), do: "sg-#{:erlang.phash2(host, 4_294_967_296)}"

  defp harness_tip,
    do:
      pgettext(
        "plain",
        "The runtime's own needs: hosts it declares in the policy applied event. Declared hosts are reported, never allowed by that."
      )

  defp middle(host) when byte_size(host) > 48,
    do: String.slice(host, 0, 22) <> "…" <> String.slice(host, -22, 22)

  defp middle(host), do: host

  ## History

  @doc """
  The changes of a page of history, grouped by day, newest first. A change row is a
  native `<details>`; opening one patches `?change=`, and the page computes its diff.
  `changes` are maps: `id`, `sentence` (rich), `origin` (a faint second line or nil),
  `who`, `at`, `version`, `digest`, `navigate` (the version page), `workspace` (a change
  of the workspace shown in a target's history), `patch`, `close`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :changes, :list, required: true
  attr :open, :any, default: nil, doc: "the id of the open change"
  attr :diff, :any, default: nil
  attr :now, :any, required: true

  def change_list(assigns) do
    assigns =
      assign(
        assigns,
        :days,
        Enum.chunk_by(assigns.changes, &DateTime.to_date(Format.local(&1.at)))
      )

    ~H"""
    <section id={@id} class="q-sect" aria-label={@label}>
      <div :for={day <- @days} class="contents">
        <div class="q-day">{Format.day_heading(hd(day).at, @now)}</div>
        <.change_row
          :for={change <- day}
          id={"chg-#{change.id}"}
          change={change}
          open={@open == change.id}
          diff={@open == change.id && @diff}
        />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :change, :map, required: true
  attr :open, :boolean, default: false
  attr :diff, :any, default: nil

  def change_row(assigns) do
    ~H"""
    <details id={@id} class="q-chg" open={@open} phx-hook="ChangeRow" data-open={to_string(@open)}>
      <summary
        id={"#{@id}-summary"}
        phx-click={JS.patch(if @open, do: @change.close, else: @change.patch)}
      >
        <.icon name="hero-chevron-right-micro" class="q-chg-chev size-3" />
        <.avatar name={@change.who} />
        <span class="q-chg-say">
          <.rich text={@change.sentence} />
          <small :if={@change.origin}>{@change.origin}</small>
        </span>
        <span class="q-chg-when">
          <RunComponents.relative_time at={@change.at} />
          <.source_chip
            :if={@change.workspace}
            source={:workspace}
            label={gettext("workspace")}
            class="q-src-xs"
          />
        </span>
        <span class="q-chg-v">
          <.version_pill
            :if={@change.version}
            size="sm"
            version={@change.version}
            digest={@change.digest}
          />
          <span :if={!@change.version} class="q-nov">{gettext("no new version")}</span>
        </span>
      </summary>
      <.policy_diff :if={@open && @diff} id={"#{@id}-diff"} diff={@diff} />
    </details>
    """
  end

  @doc """
  The diff of a change, or between two versions: the change in the page's own words, and
  a line diff of the rendered document. `diff`: `%{rules: [{:add | :del | :ctx, rich}],
  document: [{:add | :del | :ctx, text}], from:, to:, summary:, navigate:, bytes:}`.
  """
  attr :id, :string, required: true
  attr :diff, :map, required: true

  def policy_diff(assigns) do
    ~H"""
    <div id={@id} class="q-diffbox">
      <div class="q-diffbar">
        <.version_pill
          :if={@diff.from}
          size="sm"
          version={@diff.from.version}
          digest={@diff.from.digest}
        />
        <.icon :if={@diff.from && @diff.to} name="hero-arrow-right-micro" class="size-3 text-faint" />
        <.version_pill :if={@diff.to} size="sm" version={@diff.to.version} digest={@diff.to.digest} />
        <span>{@diff.summary}</span>
        <span class="grow"></span>
        <.link :if={@diff.navigate} navigate={@diff.navigate} class="q-link">
          {gettext("Open v%{version}", version: @diff.to.version)}
        </.link>
      </div>
      <div class="q-dpanel">
        <div>
          <span>{gettext("rules")}</span><span>{changes(
            Enum.count(@diff.rules, &(elem(&1, 0) != :ctx))
          )}</span>
        </div>
        <div class="q-dlines q-dlines-sem">
          <.diff_line :for={{kind, text} <- @diff.rules} kind={kind}>
            <.rich text={text} />
          </.diff_line>
        </div>
      </div>
      <div :if={@diff.document} class="q-dpanel">
        <div>
          <span>{gettext("document")}</span><span>{ngettext(
            "application/json · %{number} byte",
            "application/json · %{number} bytes",
            @diff.bytes,
            number: Format.number(@diff.bytes)
          )}</span>
        </div>
        <.diff_lines lines={@diff.document} label={gettext("Difference of the rendered document")} />
      </div>
      <div :if={!@diff.document} class="q-dpanel">
        <div><span>{gettext("document")}</span><span>{gettext("unchanged")}</span></div>
        <div class="q-dlines q-dlines-sem">
          <.diff_line kind={:ctx}>
            {gettext("The rendered bytes stayed the same, so no version was made.")}
          </.diff_line>
        </div>
      </div>
    </div>
    """
  end

  @doc "The lines of a document diff: a gutter character, an `sr-only` word, JSON keys in accent."
  attr :lines, :list, required: true
  attr :label, :string, required: true
  attr :id, :string, default: nil

  def diff_lines(assigns) do
    ~H"""
    <div id={@id} class="q-dlines" role="region" aria-label={@label} tabindex="0">
      <.diff_line :for={{kind, text} <- @lines} kind={kind}><.json_line text={text} /></.diff_line>
    </div>
    """
  end

  @doc """
  diff_line/1 is one line of a diff: its gutter character, `+`, `−` or none for `:add`,
  `:del` and `:ctx`, the word a screen reader says for the first two, and the line.
  """
  attr :kind, :atom, required: true, values: [:add, :del, :ctx]
  slot :inner_block, required: true

  def diff_line(assigns) do
    ~H"""
    <div class={[@kind == :add && "q-add", @kind == :del && "q-del", @kind == :ctx && "q-ctx"]}>
      <i aria-hidden="true">{gutter(@kind)}</i>
      <span><span :if={@kind == :add} class="sr-only">{gettext("Added:")}</span><span
        :if={@kind == :del}
        class="sr-only"
      >{gettext("Removed:")} </span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  defp changes(n),
    do: ngettext("%{number} change", "%{number} changes", n, number: Format.number(n))

  defp gutter(:add), do: "+"
  defp gutter(:del), do: "−"
  defp gutter(_ctx), do: ""

  attr :text, :string, required: true

  @doc "One line of indented JSON or YAML, its leading key in accent."
  def json_line(assigns) do
    {indent, key, rest} =
      case Regex.run(~r/\A(\s*(?:- )?)("[^"]*"|[A-Za-z_][\w.-]*)(:.*)\z/s, assigns.text) do
        [_, indent, key, rest] -> {indent, key, rest}
        _ -> {assigns.text, nil, ""}
      end

    assigns = assign(assigns, indent: indent, key: key, rest: rest)

    ~H|{@indent}<span :if={@key} class="q-k">{@key}</span>{@rest}|
  end

  @doc "A text of JSON or YAML, a block per line: keys in accent, comment lines faint."
  attr :id, :string, required: true
  attr :text, :string, required: true

  def code_lines(assigns) do
    assigns =
      assign(assigns, :lines, assigns.text |> String.trim_trailing("\n") |> String.split("\n"))

    ~H"""
    <pre id={@id} class="q-code-lines" tabindex="0"><span
        :for={line <- @lines}
        class={["q-line", String.starts_with?(String.trim_leading(line), "#") && "q-c"]}
      ><.json_line text={line} /></span></pre>
    """
  end

  @doc "A code well with a caption bar: the document, the served bytes, an export."
  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :caption, required: true
  slot :actions
  slot :inner_block, required: true

  def doc_well(assigns) do
    ~H"""
    <div id={@id} class={["q-docwell", @class]}>
      <div class="q-docwell-bar">
        <span class="min-w-0 truncate">{render_slot(@caption)}</span>
        <span class="flex flex-none gap-0.5">{render_slot(@actions)}</span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
