defmodule ApiaryWeb.PolicyComponents do
  @moduledoc """
  The components of the security policy (`docs/design/brief-policy.md`, pd1 to pd7): the
  version pill and the version link, the mark of a rule, the source chip, the mode switch,
  the rule composer with its reading line, the rules table with provenance, the
  suggestions of the harness, the history of changes with its diff, and the document well.

  The pages under `/hive/policy` use all of them; the run page and the connections pages
  use the first four, so a version, a rule and where it came from look the same wherever
  a policy is named.

  Everything rendered here comes from `Apiary.Policy` or from a form: hosts, paths and
  names are only ever interpolated, never `raw/1`.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.CoreComponents,
    only: [avatar: 1, badge: 1, button: 1, icon: 1, notice: 1, term: 1]

  # `RunComponents` uses the shared components of this module, so nothing of it is imported
  # here: its functions are called by their full name, which is no compile-time dependency.
  alias ApiaryWeb.RunComponents

  alias Phoenix.LiveView.JS

  ## pd1. Version pill and version link

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
      "whose version, when shown away from its own page: \"hive baseline\" or a forge/path; a quiet suffix"

  attr :class, :any, default: nil

  def version_pill(%{version: nil} = assigns) do
    ~H"""
    <span id={@id} class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]}>
      <span class="q-vpill-dg">No version yet</span>
    </span>
    """
  end

  def version_pill(assigns) do
    ~H"""
    <span id={@id} class={["q-vpill", @size == "sm" && "q-vpill-sm", @class]} title={@digest}>
      <.link :if={@navigate} navigate={@navigate} class="q-vpill-v">
        <span class="sr-only">Version </span>v{@version}
      </.link>
      <span :if={!@navigate} class="q-vpill-v"><span class="sr-only">Version </span>v{@version}</span>
      <span :if={@digest} class="q-vpill-dg">
        <i :if={@size == "md"}>sha256</i>{short_digest(@digest)}
      </span>
      <span :if={@scope} class="q-vpill-scope"><span class="sr-only">of </span>{@scope}</span>
      <button
        :if={@copy && @size == "md" && @digest && @id}
        id={"#{@id}-copy"}
        type="button"
        phx-hook="CopyToClipboard"
        data-copy={@digest}
        class="copy-btn q-vpill-copy tooltip tooltip-left"
        data-tip="Copy the digest"
        aria-label="Copy the digest"
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

  ## pd4. The mark of a rule

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

  defp rule_mark_word("allow"), do: "Allow"
  defp rule_mark_word("deny"), do: "Deny"
  defp rule_mark_word("pending"), do: "Not allowed"

  ## pd5. Source chip

  @doc """
  Where a rule comes from: three shapes, three wordings, no status hue. `label` replaces
  the words where the same chip names a repository's policy ("Own rules", "Hive baseline")
  or marks a change the hive made ("hive").
  """
  attr :source, :atom, required: true, values: [:hive, :repository, :hive_locked]
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def source_chip(assigns) do
    ~H"""
    <span class={["q-src", source_class(@source), @class]}>
      <.icon :if={@source == :repository} name="hero-book-open-micro" class="size-3" />
      <.icon :if={@source == :hive_locked} name="hero-lock-closed-micro" class="size-3" />
      <svg
        :if={@source == :hive}
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

  defp source_class(:hive), do: nil
  defp source_class(:repository), do: "q-src-repo"
  defp source_class(:hive_locked), do: "q-src-lock"

  defp source_words(:hive), do: "Hive"
  defp source_words(:repository), do: "This repository"
  defp source_words(:hive_locked), do: "Hive, locked"

  ## Rich text

  @doc """
  The rich text of a reading or of a sentence built from data: binaries, `{:b, rich}`,
  `{:m, mono}` and `{:code, chip}`. Everything is interpolated, so everything is escaped.
  """
  attr :text, :any, required: true

  def rich(%{text: text} = assigns) when is_binary(text), do: ~H"{@text}"

  def rich(%{text: {:b, inner}} = assigns) do
    assigns = assign(assigns, :inner, inner)
    ~H"<b><.rich text={@inner} /></b>"
  end

  def rich(%{text: {:m, mono}} = assigns) do
    assigns = assign(assigns, :mono, mono)
    ~H|<span class="font-mono text-[12px]">{@mono}</span>|
  end

  def rich(%{text: {:code, code}} = assigns) do
    assigns = assign(assigns, :code, code)
    ~H|<code class="q-rule">{@code}</code>|
  end

  def rich(%{text: parts} = assigns) when is_list(parts) do
    ~H"<.rich :for={part <- @text} text={part} />"
  end

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
        <span :if={@count} id={"#{@id}-n"} class="q-sect-n">{@count}</span>
        <span class="grow"></span>
        {render_slot(@trailing)}
        <p :if={@description != []}>{render_slot(@description)}</p>
      </header>
      {render_slot(@inner_block)}
      <footer :if={@footer != []}>{render_slot(@footer)}</footer>
    </section>
    """
  end

  ## pd2. Mode switch

  @doc """
  The hive's default mode as two radio cards. Choosing the other card never switches at
  once: it sends `mode_ask`, and the page opens the confirm. Arrow keys move between the
  cards (the `PolicyPage` hook); Space or Enter asks. A mode is an owner's to set: for a
  member the group is `aria-disabled`, keeps its look and its words, and does nothing.
  """
  attr :id, :string, default: "policy-mode"
  attr :mode, :string, required: true, values: ~w(observe enforce), doc: "the hive's default"
  attr :can_edit, :boolean, default: false, doc: "owners only"
  attr :served, :boolean, default: true, doc: "false on a new hive: nothing is served yet"
  attr :following, :integer, default: 0, doc: "repositories that follow the default"
  attr :own, :list, default: [], doc: "the modes of the repositories that set their own"

  attr :fact, :any,
    default: nil,
    doc: ":loading, nil, %{denied:, destinations:} or %{uncovered:, destinations:} or :none"

  def mode_switch(assigns) do
    ~H"""
    <section class="grid gap-2.5" aria-labelledby={"#{@id}-h"}>
      <h2 id={"#{@id}-h"} class="sr-only">Mode</h2>
      <div
        id={@id}
        class="q-mode"
        role="radiogroup"
        aria-labelledby={"#{@id}-h"}
        aria-disabled={!@can_edit && "true"}
        data-roving
      >
        <button
          :for={
            {mode, name, icon, sentence} <- [
              {"observe", "Observe", "hero-eye-micro",
               "Records every connection and denies only what a deny rule names. A host no rule names is let through, and the record says so."},
              {"enforce", "Enforce", "hero-shield-exclamation-micro",
               "Denies a connection no rule allows, and records the denial. With no allow rule, a run reaches nothing."}
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
            <.badge :if={@mode == mode}>Hive default</.badge>
          </span>
          <span id={"#{@id}-#{mode}-p"} class="q-mode-p">{sentence}</span>
          <span :if={@mode == mode && (@fact || !@served)} id={"#{@id}-fact"} class="q-mode-fact">
            <.mode_fact
              fact={if @served, do: @fact, else: :unserved}
              tail={
                if @own != [], do: ", in the #{repositories(@following)} that follow it", else: ""
              }
            />
          </span>
        </button>
      </div>
      <p id={"#{@id}-under"} class="text-[12.5px]/[18px] text-faint">
        This is the hive's default. A repository follows it unless an owner sets a mode of its own:
        <span :if={@own == []}>none does.</span>
        <span :if={@own != []}>
          <.link navigate="/hive/policy/repositories?mode=own" class="q-link">{own_count(@own, @following)}</.link>{own_modes(
            @own
          )}
        </span>
        A wall's own refusals (the machine's address, a path that reads two ways) hold in either mode.
        <span :if={!@can_edit} id={"#{@id}-owners"}>Only an owner sets a mode.</span>
      </p>
    </section>
    """
  end

  defp repositories(1), do: "1 repository"
  defp repositories(n), do: "#{n} repositories"

  defp own_count([_one], following), do: "1 of #{repositories(following + 1)} does"

  defp own_count(own, following),
    do: "#{length(own)} of #{repositories(following + length(own))} do"

  defp own_modes([mode]), do: ", and #{mode}s."

  defp own_modes(own) do
    observe = Enum.count(own, &(&1 == "observe"))
    enforce = length(own) - observe

    cond do
      enforce == 0 -> ", and observe."
      observe == 0 -> ", and enforce."
      true -> ": #{observe} #{verb(observe, "observe")}, #{enforce} #{verb(enforce, "enforce")}."
    end
  end

  defp verb(1, word), do: word <> "s"
  defp verb(_n, word), do: word

  attr :fact, :any, required: true
  attr :tail, :string, default: ""

  defp mode_fact(%{fact: :loading} = assigns) do
    ~H|<span class="skeleton q-skel inline-block w-64 align-middle"></span>|
  end

  defp mode_fact(%{fact: :unserved} = assigns) do
    ~H"Not served yet: it applies from the first change here."
  end

  defp mode_fact(%{fact: :none} = assigns) do
    ~H"No run has reached out in the last 7 days."
  end

  defp mode_fact(%{fact: %{denied: _}} = assigns) do
    ~H"""
    In the last 7 days it denied <b>{RunComponents.delimited(@fact.denied)}</b>
    {if @fact.denied == 1, do: "attempt", else: "attempts"} to
    <b>{RunComponents.delimited(@fact.destinations)}</b>
    {if @fact.destinations == 1, do: "destination", else: "destinations"}.
    <.link navigate="/hive/connections?decision=denied&since=7d" class="q-link">See them</.link>
    """
  end

  defp mode_fact(%{fact: %{uncovered: _}} = assigns) do
    ~H"""
    In the last 7 days <b>{RunComponents.delimited(@fact.uncovered)}</b>
    {if @fact.uncovered == 1, do: "attempt", else: "attempts"} to
    <b>{RunComponents.delimited(@fact.destinations)}</b>
    {if @fact.destinations == 1, do: "destination", else: "destinations"} had no rule{@tail}. Enforce would deny them.
    <.link navigate="/hive/connections?since=7d" class="q-link">See them</.link>
    """
  end

  ## pd2a. Repository mode

  @doc """
  A repository's mode: follow the hive, observe or enforce, with what is in effect and
  where it comes from. Compact on purpose: the hive's page explains the two modes once;
  here the choice is whose mode. A radio sends `repository_mode_ask`. While the repository
  observes and its list holds locked denies of the hive, a notice says that they hold
  here all the same: a deny is denied in either mode.
  """
  attr :id, :string, required: true
  attr :setting, :string, required: true, values: ~w(follow observe enforce)
  attr :effective, :string, required: true, values: ~w(observe enforce)
  attr :hive_default, :string, required: true, values: ~w(observe enforce)
  attr :can_edit, :boolean, default: false, doc: "owners only"
  attr :locked_denies, :list, default: [], doc: "the hosts of locked hive denies in the list"

  def repository_mode(assigns) do
    ~H"""
    <section id={@id} class="q-sect q-rmode-sect" aria-labelledby={"#{@id}-h"}>
      <div class="q-rmode">
        <h2 id={"#{@id}-h"}>Mode</h2>
        <div
          id={"#{@id}-radios"}
          class="q-seg q-rmode-seg"
          role="radiogroup"
          aria-labelledby={"#{@id}-h"}
          aria-describedby={"#{@id}-effect"}
          data-roving
        >
          <button
            :for={
              {setting, label} <- [
                {"follow", "Follow the hive"},
                {"observe", "Observe"},
                {"enforce", "Enforce"}
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
                JS.push("repository_mode_ask", value: %{setting: setting})
            }
          >
            {label}
          </button>
        </div>
        <p id={"#{@id}-effect"} class="q-rmode-effect">
          In effect: <b>{@effective}</b>,
          <span :if={@setting == "follow"}>the hive's default. It changes when the hive's does.</span><span :if={
            @setting != "follow"
          }>this repository's own. The hive's default is {@hive_default}.</span>
          <span :if={!@can_edit} id={"#{@id}-owners"}>Only an owner sets a mode.</span>
        </p>
      </div>
      <div :if={@effective == "observe" && @locked_denies != []} class="px-4 pb-3">
        <.notice kind={:info}>
          <span id={"#{@id}-locked-note"}>
            <b>This repository observes: the locked deny still holds.</b>
            The locked deny <code :for={host <- @locked_denies} class="q-rule mr-1">{host}</code>
            is denied in either mode, and under observe it is the only thing denied here: every other host is let through and recorded. It holds whatever mode this repository is in.
          </span>
        </.notice>
      </div>
    </section>
    """
  end

  ## pd3. Rule composer

  @doc """
  The composer of a host rule: a row between the card's header and its table, never a
  modal. The reading line under the fields reads the rule back; the button is off until
  the reading is `:ok` or `:note`.
  """
  attr :id, :string, required: true
  attr :form, :any, required: true, doc: "action, host, paths, every"
  attr :scope, :atom, required: true, values: [:hive, :repository]
  attr :reading, :map, default: nil
  attr :queued, :integer, default: 0, doc: "pasted hosts still to add"
  attr :host_placeholder, :string, default: "api.example or *.internal.example"

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
      class="q-composer"
      aria-label={if @scope == :hive, do: "Add a host rule", else: "Add a rule for this repository"}
      phx-change="composer_change"
      phx-submit="composer_save"
      phx-hook="RuleComposer"
      autocomplete="off"
    >
      <input type="hidden" name={@form[:action].name} value={@form[:action].value} />
      <input type="hidden" name={@form[:every].name} value={@form[:every].value} />
      <div class="q-seg q-composer-seg" role="group" aria-label="Action">
        <button
          type="button"
          aria-pressed={to_string(!@deny?)}
          phx-click={JS.push("composer_action", value: %{action: "allow"})}
        >
          Allow
        </button>
        <button
          type="button"
          class="q-seg-deny"
          aria-pressed={to_string(@deny?)}
          phx-click={JS.push("composer_action", value: %{action: "deny"})}
        >
          Deny
        </button>
      </div>
      <label>
        <span class="sr-only">Host</span>
        <input
          type="text"
          id={"#{@id}-host"}
          name={@form[:host].name}
          value={@form[:host].value}
          class="q-input q-input-m"
          placeholder={@host_placeholder}
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
        <span class="sr-only">Paths, optional</span>
        <input
          type="text"
          id={"#{@id}-paths"}
          name={@form[:paths].name}
          value={if @deny?, do: "", else: @form[:paths].value}
          class="q-input q-input-m"
          placeholder={
            cond do
              @deny? -> "A deny is of the whole host"
              @every? -> "Every path"
              true -> "Every path, or /v1/* /health"
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
      <.button type="submit" variant="primary" id={"#{@id}-add"} disabled={!@ready?}>
        {@reading.button || if(@scope == :hive, do: "Add rule", else: "Add for this repository")}
      </.button>
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
      aria-label="Add a credential"
      phx-change="credential_change"
      phx-submit="credential_save"
      autocomplete="off"
    >
      <label>
        <span class="sr-only">Name</span>
        <input
          type="text"
          id={"#{@id}-name"}
          name={@form[:name].name}
          value={@form[:name].value}
          class="q-input q-input-m"
          placeholder="Name, such as forge-token"
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
        <span class="sr-only">Argument, optional</span>
        <input
          type="text"
          id={"#{@id}-argument"}
          name={@form[:argument].name}
          value={@form[:argument].value}
          class="q-input q-input-m"
          placeholder="Argument (optional), such as acme/shop"
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
        {@reading.button || "Add credential"}
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
          {@queued} more to add
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

  ## pd4. Rules table and rule row

  @doc """
  The rules of the hive, or the effective policy of a repository: one list, every entry
  saying where it came from. A row is a map the page builds (see `rule_row/1`).
  `activity` is `:loading`, `:unavailable` (the column is dropped, never faked) or the
  map of `Apiary.Policy.rule_activity/3`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :scope, :atom, required: true, values: [:hive, :repository]
  attr :can_lock, :boolean, default: false
  attr :activity, :any, default: :unavailable
  attr :fresh, :any, default: %{}, doc: "%{rule id => version}: new in the version in force"
  attr :target, :string, default: nil, doc: "the host `?rule=` points at"
  attr :empty, :string, default: nil, doc: "the one faint line of a filter that matches nothing"

  def rules_table(assigns) do
    assigns = assign(assigns, :seen?, assigns.activity != :unavailable)

    ~H"""
    <div id={@id} class="q-rules-wrap" role="region" aria-label={@label}>
      <table class="table q-rules" role="table">
        <thead>
          <tr role="row">
            <th role="columnheader">Rule</th>
            <th role="columnheader">Paths</th>
            <th :if={@scope == :repository} role="columnheader">Comes from</th>
            <th :if={@seen?} role="columnheader" class="q-num">Last 7 days</th>
            <th :if={@scope == :hive} role="columnheader">Added</th>
            <th role="columnheader">
              <span class="sr-only">{if @scope == :hive, do: "Lock and actions", else: "Actions"}</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == [] && @empty} role="row">
            <td role="cell" colspan="6" class="!whitespace-normal text-[13px] text-faint">
              {@empty}
            </td>
          </tr>
          <.rule_row
            :for={row <- @rows}
            id={"rule-#{row.id}"}
            rule={row}
            scope={@scope}
            can_lock={@can_lock}
            seen={@seen? && seen(@activity, row)}
            seen?={@seen?}
            fresh={Map.get(@fresh, row.id)}
            target={@target != nil && @target == row.host}
          />
        </tbody>
      </table>
    </div>
    """
  end

  defp seen(:loading, _row), do: :loading
  defp seen(%{} = activity, row), do: Map.get(activity, row.id, %{allowed: 0, denied: 0})

  @doc """
  One rule. `rule` is a map: `id`, `action` (`"allow"`, `"deny"`), `host`, `paths`,
  `locked`, `source` (`:hive`, `:repository`, `:hive_locked`), `by` (the local part of the
  author's email), `at`, `locked_tip` (what a member reads on the padlock), `act` (the one
  act of a repository row: `:disable`, `:allow_here`, `:remove`, `:restore`, `:open`),
  `beaten` (the rules it holds against: maps with `id`, `action`, `host`, `kind`
  (`:override`, `:lock`, `:cover`), `by`, `at`), `can_change` (false for a member on a
  locked rule).
  """
  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :scope, :atom, required: true
  attr :can_lock, :boolean, default: false
  attr :seen, :any, default: nil
  attr :seen?, :boolean, default: false
  attr :fresh, :any, default: nil
  attr :target, :boolean, default: false

  def rule_row(assigns) do
    ~H"""
    <tr
      id={@id}
      role="row"
      class={[
        "q-rule-row",
        @fresh && "q-fresh",
        @target && "q-rule-target",
        @rule.beaten != [] && "q-has-over"
      ]}
    >
      <td role="cell" class="q-c-rule">
        <div class="q-rcell">
          <.rule_mark action={@rule.action} />
          <.host host={@rule.host} />
          <span :if={@fresh} class="q-newdot">New in v{@fresh}</span>
        </div>
      </td>
      <td role="cell" class="q-c-paths"><.paths paths={@rule.paths} action={@rule.action} /></td>
      <td :if={@scope == :repository} role="cell" class="q-c-src">
        <.source_chip source={@rule.source} />
      </td>
      <td :if={@seen?} role="cell" class="q-c-seen q-num">
        <.seen seen={@seen} />
      </td>
      <td :if={@scope == :hive} role="cell" class="q-c-by">
        <.who_when by={@rule.by} at={@rule.at} />
      </td>
      <td role="cell" class="q-c-acts">
        <span :if={@scope == :hive} class="q-rowacts">
          <.lock rule={@rule} can_lock={@can_lock} id={@id} />
          <.rule_menu :if={@rule.can_change} id={"#{@id}-menu"} rule={@rule} can_lock={@can_lock} />
        </span>
        <.repository_act :if={@scope == :repository} rule={@rule} id={@id} />
      </td>
    </tr>
    <tr
      :for={beaten <- @rule.beaten}
      id={"#{@id}-over-#{beaten.id}"}
      role="row"
      class={["q-over", @fresh && "q-fresh"]}
    >
      <td role="cell" colspan="6">
        <div class="q-overline">
          <.icon :if={beaten.kind == :lock} name="hero-lock-closed-micro" class="size-3" />
          <b>{beaten_lead(beaten)}</b>
          <s>
            <span class="sr-only">not in force: </span>{beaten.action} {beaten.host}
          </s>
          <span>{beaten_tail(beaten)}</span>
          <button
            :if={beaten.kind == :lock}
            type="button"
            class="q-link"
            phx-click={JS.push("row_act", value: %{id: beaten.id, act: "remove"})}
            aria-label={"Remove this repository's rule for #{beaten.host}"}
          >
            Remove it
          </button>
        </div>
      </td>
    </tr>
    """
  end

  defp beaten_lead(%{kind: :lock}), do: "Holds against this repository's rule"
  defp beaten_lead(%{kind: :override}), do: "Overrides the hive's rule"
  defp beaten_lead(%{kind: :cover, source: :hive}), do: "Covers the hive's rule"
  defp beaten_lead(%{kind: :cover}), do: "Covers this repository's rule"

  defp beaten_tail(%{kind: :lock} = beaten),
    do: "#{who_when_words(beaten)} It is not in force."

  defp beaten_tail(%{kind: :override, action: "allow"} = beaten),
    do: "Disabled here#{by_words(beaten)}. Other repositories keep it."

  defp beaten_tail(%{kind: :override} = beaten), do: "Allowed here#{by_words(beaten)}."
  defp beaten_tail(%{kind: :cover}), do: "It changes nothing while this rule stands."

  defp who_when_words(%{by: by, at: %DateTime{} = at}) when is_binary(by),
    do: "#{by} · #{day(at)}."

  defp who_when_words(%{at: %DateTime{} = at}), do: "#{day(at)}."
  defp who_when_words(_beaten), do: ""

  defp by_words(%{winner_by: by, winner_at: %DateTime{} = at}) when is_binary(by),
    do: " by #{by} · #{day(at)}"

  defp by_words(%{winner_at: %DateTime{} = at}), do: " · #{day(at)}"
  defp by_words(_beaten), do: ""

  @doc "A host in mono; the leading `*.` of a suffix in accent, with what it means on hover."
  attr :host, :string, required: true
  attr :class, :any, default: nil

  def host(%{host: "*." <> suffix} = assigns) do
    assigns = assign(assigns, :suffix, suffix)

    ~H"""
    <span
      class={["q-host tooltip q-tip-wide", @class]}
      tabindex="0"
      aria-description={"Every host below #{@suffix}, and not #{@suffix} itself."}
      data-tip={"Every host below #{@suffix}, and not #{@suffix} itself."}
    ><span class="q-host-w">*.</span>{@suffix}</span>
    """
  end

  def host(assigns) do
    ~H|<span class={["q-host", @class]}>{@host}</span>|
  end

  attr :paths, :any, required: true
  attr :action, :string, default: "allow"

  defp paths(%{action: "deny"} = assigns), do: ~H|<span class="q-every">every path</span>|
  defp paths(%{paths: nil} = assigns), do: ~H|<span class="q-every">every path</span>|

  defp paths(%{paths: []} = assigns) do
    ~H"""
    <span
      class="q-every tooltip q-tip-wide"
      tabindex="0"
      aria-description="The host is listed with no path: every request to it is denied under enforce."
      data-tip="The host is listed with no path: every request to it is denied under enforce."
    >
      no path
    </span>
    """
  end

  defp paths(assigns) do
    ~H"""
    <span class="q-chips"><code :for={path <- @paths} class="q-rule">{path}</code></span>
    """
  end

  attr :seen, :any, required: true
  attr :noun, :string, default: nil

  defp seen(%{seen: :loading} = assigns) do
    ~H|<span class="skeleton q-skel inline-block w-16 align-middle" aria-hidden="true"></span>|
  end

  defp seen(%{seen: %{allowed: 0, denied: 0}} = assigns) do
    ~H|<span class="q-zero">not seen</span>|
  end

  defp seen(%{noun: noun} = assigns) when is_binary(noun) do
    ~H|<span class="text-muted">{RunComponents.count_noun(@seen.allowed + @seen.denied, @noun)}</span>|
  end

  defp seen(assigns) do
    ~H"""
    <span :if={@seen.allowed > 0} class="text-muted">{RunComponents.delimited(@seen.allowed)} allowed</span>
    <span :if={@seen.allowed > 0 && @seen.denied > 0} class="text-muted"> · </span>
    <span :if={@seen.denied > 0} class="q-bad">{RunComponents.delimited(@seen.denied)} denied</span>
    <span class="sr-only"> in the last 7 days</span>
    """
  end

  attr :by, :string, default: nil
  attr :at, :any, default: nil

  defp who_when(assigns) do
    ~H"""
    <span class="q-who-when">
      {@by}
      <small :if={@at}>{if @by, do: "· "}{day(@at)}</small>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :can_lock, :boolean, required: true

  defp lock(%{can_lock: true} = assigns) do
    ~H"""
    <button
      id={"#{@id}-lock"}
      type="button"
      class="q-lockbtn tooltip tooltip-left q-tip-wide"
      aria-pressed={to_string(@rule.locked)}
      aria-label={"Lock #{@rule.host}"}
      data-tip={
        if @rule.locked,
          do: "Locked: no repository can override it. Select to unlock.",
          else: "Lock: hold this rule against every repository"
      }
      phx-click={JS.push("lock_toggle", value: %{id: @rule.id})}
    >
      <.icon
        name={if @rule.locked, do: "hero-lock-closed-micro", else: "hero-lock-open-micro"}
        class="size-3"
      />
      <span :if={@rule.locked}>Locked</span>
    </button>
    """
  end

  defp lock(%{rule: %{locked: true}} = assigns) do
    ~H"""
    <span
      id={"#{@id}-lock"}
      class="q-locked tooltip tooltip-left q-tip-wide"
      tabindex="0"
      aria-description={@rule.locked_tip || "Locked. Only an owner can change or unlock it."}
      data-tip={@rule.locked_tip || "Locked. Only an owner can change or unlock it."}
    >
      <.icon name="hero-lock-closed-micro" class="size-3 text-muted" />Locked
    </span>
    """
  end

  defp lock(assigns), do: ~H""

  attr :id, :string, required: true
  attr :rule, :map, required: true
  attr :can_lock, :boolean, required: true

  defp rule_menu(assigns) do
    ~H"""
    <div
      id={@id}
      class="dropdown dropdown-end"
      phx-hook="Menu"
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-ghost btn-xs btn-square"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-label={"Actions for #{@rule.host}"}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        <.icon name="hero-ellipsis-horizontal-micro" class="size-4" />
      </button>
      <ul class="menu menu-sm dropdown-content right-0 z-20 mt-1 w-44" role="menu">
        <li :if={@rule.action == "allow"} role="none">
          <button
            type="button"
            role="menuitem"
            data-menu-close
            phx-click={JS.push("edit_paths", value: %{id: @rule.id})}
          >
            <.icon name="hero-pencil-square-micro" class="size-4" /> Edit paths
          </button>
        </li>
        <li :if={@can_lock} role="none">
          <button
            type="button"
            role="menuitem"
            data-menu-close
            phx-click={JS.push("lock_toggle", value: %{id: @rule.id})}
          >
            <.icon
              name={if @rule.locked, do: "hero-lock-open-micro", else: "hero-lock-closed-micro"}
              class="size-4"
            />
            {if @rule.locked, do: "Unlock", else: "Lock"}
          </button>
        </li>
        <li class="menu-divider" role="separator"></li>
        <li role="none">
          <button
            type="button"
            role="menuitem"
            class="text-error-soft-content"
            data-menu-close
            phx-click={JS.push("remove", value: %{id: @rule.id})}
          >
            <.icon name="hero-trash-micro" class="size-4" /> Remove
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rule, :map, required: true

  defp repository_act(%{rule: %{act: :open}} = assigns) do
    ~H"""
    <span
      class="tooltip tooltip-left q-tip-wide"
      data-tip="A locked hive rule. It is changed on the hive's policy page, by an owner."
    >
      <.link
        id={"#{@id}-act"}
        navigate={"/hive/policy?rule=#{URI.encode_www_form(@rule.host)}"}
        class="q-link q-link-xs pr-2"
        aria-label={"Open the hive's locked rule for #{@rule.host}"}
      >
        Open
      </.link>
    </span>
    """
  end

  defp repository_act(assigns) do
    ~H"""
    <button
      id={"#{@id}-act"}
      type="button"
      class="btn btn-ghost btn-xs"
      aria-label={act_label(@rule.act, @rule.host)}
      phx-click={JS.push("row_act", value: %{id: @rule.id, act: to_string(@rule.act)})}
    >
      {act_word(@rule.act)}
    </button>
    """
  end

  defp act_word(:disable), do: "Disable here"
  defp act_word(:allow_here), do: "Allow here"
  defp act_word(:remove), do: "Remove"
  defp act_word(:restore), do: "Restore"

  defp act_label(:disable, host), do: "Disable #{host} for this repository"
  defp act_label(:allow_here, host), do: "Allow #{host} for this repository"
  defp act_label(:remove, host), do: "Remove this repository's rule for #{host}"
  defp act_label(:restore, host), do: "Restore the hive's rule for #{host} in this repository"

  @doc "The credentials of a scope as a table. Rows: `id`, `name`, `argument`, `source`, `by`, `at`, `can_change`."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :scope, :atom, required: true
  attr :activity, :any, default: :unavailable

  def credentials_table(assigns) do
    assigns = assign(assigns, :seen?, assigns.activity != :unavailable)

    ~H"""
    <div id={@id} class="q-rules-wrap" role="region" aria-label={@label}>
      <table class="table q-rules" role="table">
        <thead>
          <tr role="row">
            <th role="columnheader">Name</th>
            <th role="columnheader">Argument</th>
            <th :if={@scope == :repository} role="columnheader">Comes from</th>
            <th :if={@seen?} role="columnheader" class="q-num">Last 7 days</th>
            <th role="columnheader">Added</th>
            <th role="columnheader"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []} role="row">
            <td role="cell" colspan="6" class="!whitespace-normal text-[13px] text-faint">
              No credentials. A run that needs none runs without.
            </td>
          </tr>
          <tr :for={row <- @rows} id={"rule-#{row.id}"} role="row" class="q-rule-row">
            <td role="cell" class="q-c-rule">
              <div class="q-rcell">
                <.icon name="hero-key-micro" class="size-4 text-faint" />
                <span class="q-host">{row.name}</span>
                <.badge :if={row.action == "deny"} color="error">Denied</.badge>
              </div>
            </td>
            <td role="cell" class="q-c-paths">
              <code :if={row.argument} class="q-rule">{row.argument}</code>
              <span :if={!row.argument} class="q-every">no argument</span>
            </td>
            <td :if={@scope == :repository} role="cell" class="q-c-src">
              <.source_chip source={row.source} />
            </td>
            <td :if={@seen?} role="cell" class="q-c-seen q-num">
              <.seen seen={seen(@activity, row)} noun="request" />
            </td>
            <td role="cell" class="q-c-by"><.who_when by={row.by} at={row.at} /></td>
            <td role="cell" class="q-c-acts">
              <button
                :if={row.can_change}
                id={"rule-#{row.id}-remove"}
                type="button"
                class="btn btn-ghost btn-xs"
                aria-label={"Remove the credential #{row.name}"}
                phx-click={JS.push("remove", value: %{id: row.id})}
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  ## pd6. Suggestions

  @doc """
  The hosts the harness declared and the policy does not cover: shown only when there is
  something to review. One click allows for the repository; the caret offers the hive and
  the composer with paths. A suggestion: `%{host:, runs:, last_seen_at:}`; `allowed` holds
  the hosts allowed from this card since the page opened, which stay until navigation.
  """
  attr :id, :string, required: true
  attr :suggestions, :list, required: true
  attr :covered, :list, default: [], doc: "[%{host:, by:, source:}]: declared and already allowed"
  attr :allowed, :any, default: %{}, doc: "%{host => rule id}"

  attr :observing, :boolean,
    default: false,
    doc: "the repository observes: a host no rule names is let through"

  def suggestions(assigns) do
    open = Enum.reject(assigns.suggestions, &Map.has_key?(assigns.allowed, &1.host))
    assigns = assign(assigns, :open, open)

    ~H"""
    <.sect
      :if={@suggestions != []}
      id={@id}
      title="Declared by the harness"
      count={if @open == [], do: "all allowed", else: "#{length(@open)} to review"}
    >
      <:trailing>
        <button
          :if={length(@open) > 1}
          id={"#{@id}-all"}
          type="button"
          class="btn btn-xs"
          phx-click="suggest_allow_all"
        >
          {if length(@open) == 2, do: "Allow both here", else: "Allow all #{length(@open)} here"}
        </button>
      </:trailing>
      <:description>
        Hosts the runtime says it needs, from the policy applied events of this repository's latest runs. A declaration allows nothing by itself.
      </:description>
      <div :for={suggestion <- @suggestions} id={suggestion_id(suggestion.host)} class="q-sugg-row">
        <span class="q-rcell">
          <.rule_mark action={
            if Map.has_key?(@allowed, suggestion.host), do: "allow", else: "pending"
          } />
          <span class="q-host truncate" title={suggestion.host}>{middle(suggestion.host)}</span>
        </span>
        <span class="q-sugg-what">
          Declared by the <.term word="harness" standard={harness_tip()} class="q-tip-wide" />
          in <b>{RunComponents.count_noun(suggestion.runs, "run")}</b>.
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
              phx-click={
                JS.push("suggest_allow", value: %{host: suggestion.host, level: "repository"})
              }
            >
              Allow here
            </button>
            <button
              type="button"
              class="btn btn-xs"
              aria-haspopup="menu"
              aria-expanded="false"
              aria-label={"More ways to allow #{suggestion.host}"}
              phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            >
              <.icon name="hero-chevron-down-micro" class="size-3" />
            </button>
            <ul class="menu menu-sm dropdown-content right-0 z-20 mt-1 w-48" role="menu">
              <li role="none">
                <button
                  type="button"
                  role="menuitem"
                  data-menu-close
                  phx-click={JS.push("suggest_allow", value: %{host: suggestion.host, level: "hive"})}
                >
                  Allow for the hive
                </button>
              </li>
              <li role="none">
                <button
                  type="button"
                  role="menuitem"
                  data-menu-close
                  phx-click={JS.push("composer_use", value: %{host: suggestion.host, focus: "paths"})}
                >
                  Allow with paths…
                </button>
              </li>
            </ul>
          </span>
        </span>
        <span :if={Map.has_key?(@allowed, suggestion.host)} class="q-sugg-acts">
          <span class="q-done" id={"#{suggestion_id(suggestion.host)}-done"} tabindex="-1">
            <.icon name="hero-check-micro" class="size-3" />Allowed {allowed_where(
              @allowed[suggestion.host]
            )}
          </span>
        </span>
      </div>
      <:footer :if={@covered != []}>
        <span id={"#{@id}-covered"}>
          {covered_lead(length(@covered))}
          <span :for={{covered, index} <- Enum.with_index(@covered, 1)}>
            <code class="q-rule">{covered.host}</code>
            {covered_by(covered)}{if index == length(@covered), do: ".", else: ","}
          </span>
        </span>
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
      Denied {times(@suggestion.denied)}<span :if={@suggestion.allowed == 0}>.</span>
    </span>
    <span :if={@suggestion.allowed > 0}>
      {if @suggestion.denied > 0, do: "and let", else: "Let"} through {times(@suggestion.allowed)} with no rule.
    </span>
    <span :if={@suggestion.allowed == 0 && @suggestion.denied == 0}>
      No run has tried to reach it in the last 7 days.
    </span>
    """
  end

  defp suggestion_record(assigns), do: ~H""

  defp times(1), do: "once"
  defp times(n), do: "#{RunComponents.delimited(n)} times"

  defp covered_lead(1), do: "1 more declared host is already allowed:"
  defp covered_lead(n), do: "#{n} more declared hosts are already allowed:"

  defp covered_by(%{host: host, by: host, source: :hive}), do: "by the hive"
  defp covered_by(%{host: host, by: host}), do: "by this repository"
  defp covered_by(%{by: by, source: :hive}), do: "by the hive's #{by}"
  defp covered_by(%{by: by}), do: "by this repository's #{by}"

  defp allowed_where(%{level: "hive"}), do: "for the hive"
  defp allowed_where(_allowed), do: "here"

  @doc "The DOM id of a suggestion's row."
  def suggestion_id(host), do: "sg-#{:erlang.phash2(host, 4_294_967_296)}"

  defp harness_tip,
    do:
      "The runtime's own needs: hosts it declares in the policy applied event. Declared hosts are reported, never allowed by that."

  defp middle(host) when byte_size(host) > 48,
    do: String.slice(host, 0, 22) <> "…" <> String.slice(host, -22, 22)

  defp middle(host), do: host

  ## pd7. History

  @doc """
  The changes of a page of history, grouped by day, newest first. A change row is a
  native `<details>`; opening one patches `?change=`, and the page computes its diff.
  `changes` are maps: `id`, `sentence` (rich), `origin` (a faint second line or nil),
  `who`, `at`, `version`, `digest`, `navigate` (the version page), `hive` (a change of the
  hive shown in a repository's history), `patch`, `close`.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :changes, :list, required: true
  attr :open, :any, default: nil, doc: "the id of the open change"
  attr :diff, :any, default: nil
  attr :now, :any, required: true

  def change_list(assigns) do
    assigns =
      assign(assigns, :days, Enum.chunk_by(assigns.changes, &DateTime.to_date(&1.at)))

    ~H"""
    <section id={@id} class="q-sect" aria-label={@label}>
      <div :for={day <- @days} class="contents">
        <div class="q-day">{day_bar(hd(day).at, @now)}</div>
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
          <b>{@change.who || "Someone who has left"}</b> <.rich text={@change.sentence} />
          <small :if={@change.origin}>{@change.origin}</small>
        </span>
        <span class="q-chg-when">
          <RunComponents.relative_time at={@change.at} />
          <.source_chip :if={@change.hive} source={:hive} label="hive" class="q-src-xs" />
        </span>
        <span class="q-chg-v">
          <.version_pill
            :if={@change.version}
            size="sm"
            version={@change.version}
            digest={@change.digest}
          />
          <span :if={!@change.version} class="q-nov">no new version</span>
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
          Open v{@diff.to.version}
        </.link>
      </div>
      <div class="q-dpanel">
        <div>
          <span>rules</span><span>{RunComponents.count_noun(
            length(Enum.reject(@diff.rules, &(elem(&1, 0) == :ctx))),
            "change"
          )}</span>
        </div>
        <div class="q-dlines q-dlines-sem">
          <.diff_line :for={{kind, text} <- @diff.rules} kind={kind}>
            <.rich text={text} />
          </.diff_line>
        </div>
      </div>
      <div :if={@diff.document} class="q-dpanel">
        <div><span>document</span><span>application/json · {@diff.bytes} bytes</span></div>
        <.diff_lines lines={@diff.document} label="Difference of the rendered document" />
      </div>
      <div :if={!@diff.document} class="q-dpanel">
        <div><span>document</span><span>unchanged</span></div>
        <div class="q-dlines q-dlines-sem">
          <.diff_line kind={:ctx}>
            The rendered bytes stayed the same, so no version was made.
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

  attr :kind, :atom, required: true
  slot :inner_block, required: true

  defp diff_line(assigns) do
    ~H"""
    <div class={[@kind == :add && "q-add", @kind == :del && "q-del", @kind == :ctx && "q-ctx"]}>
      <i aria-hidden="true">{gutter(@kind)}</i>
      <span><span :if={@kind == :add} class="sr-only">Added: </span><span
        :if={@kind == :del}
        class="sr-only"
      >Removed: </span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

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

  ## Words

  @doc "A day as a rule's author line says it: 16 Sep, with the year when it is not this one."
  def day(%DateTime{} = at) do
    if at.year == DateTime.utc_now().year,
      do: Calendar.strftime(at, "%-d %b"),
      else: Calendar.strftime(at, "%-d %b %Y")
  end

  def day(_at), do: nil

  defp day_bar(%DateTime{} = at, %DateTime{} = now) do
    case Date.diff(DateTime.to_date(now), DateTime.to_date(at)) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(at, "%-d %b %Y")
    end
  end
end
