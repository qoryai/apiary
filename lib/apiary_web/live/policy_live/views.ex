defmodule ApiaryWeb.PolicyLive.Views do
  @moduledoc """
  The views the workspace's policy and a target's policy share: the history with its
  diffs, one version with its document, the export page, a confirm in place with a list
  (`confirm_panel/1`, an edition's pages use it) and the list of keys. Function
  components; the two
  LiveViews load what they show through `ApiaryWeb.PolicyLive.Common`.
  """
  use ApiaryWeb, :html

  import ApiaryWeb.PolicyComponents

  alias ApiaryWeb.PolicyLive.Common

  @doc "The first render of a policy page, before the socket connects: its shape, and nothing read."
  attr :title, :string, required: true

  def page_skeleton(assigns) do
    ~H"""
    <div id="policy-loading" class="grid grid-cols-[minmax(0,1fr)] gap-6" aria-busy="true">
      <.page_header title={@title} />
      <div class="q-sect">
        <div
          :for={_row <- 1..5}
          class="flex items-center gap-4 border-b border-line px-4 py-3 last:border-0"
        >
          <span class="skeleton q-skel w-40"></span>
          <span class="skeleton q-skel w-24"></span>
          <span class="grow"></span>
          <span class="skeleton q-skel w-16"></span>
        </div>
      </div>
    </div>
    """
  end

  ## History

  attr :history, :map, required: true
  attr :open, :any, default: nil
  attr :diff, :any, default: nil
  attr :base, :string, required: true
  attr :scope, :atom, required: true
  attr :summary, :map, required: true, doc: "%{versions:, since:}"
  attr :now, :any, required: true

  def history_view(assigns) do
    ~H"""
    <div id="policy-history" class="grid grid-cols-[minmax(0,1fr)] gap-6">
      <div class="q-filters">
        <span class="q-filters-grow"></span>
        <span id="history-summary" class="q-summary">
          <span>
            <.rich text={
              rich_ngettext("%{number} change", "%{number} changes", @history.total,
                number: {:b, Format.number(@history.total), "font-medium text-base-content"}
              )
            } />
          </span>
          <span>
            <.rich text={
              rich_ngettext("%{number} version", "%{number} versions", @summary.versions,
                number: {:b, Format.number(@summary.versions), "font-medium text-base-content"}
              )
            } />
          </span>
          <span :if={@summary.since}>
            <.rich text={
              rich_gettext("since %{date}",
                date: {:b, Format.date(@summary.since), "font-medium text-base-content"}
              )
            } />
          </span>
        </span>
      </div>

      <.sect :if={@history.rows == []} id="history-empty" title={gettext("No changes yet")}>
        <p class="px-4 py-3 text-[13px] text-muted">
          <%= if @summary.since do %>
            {gettext("No changes yet. Version 1 was rendered on %{date}.",
              date: Format.date(@summary.since)
            )}
          <% else %>
            {gettext("No changes yet.")}
            <span :if={@scope == :workspace}>
              {gettext("Qory Apiary serves no policy for this workspace until the first one.")}
            </span>
            <span :if={@scope == :target}>
              {gettext("The first rule here, or a mode of its own, starts this target's history.")}
            </span>
          <% end %>
        </p>
      </.sect>

      <.change_list
        :if={@history.rows != []}
        id="history-list"
        label={
          if @scope == :workspace,
            do: gettext("Changes to the workspace's policy, newest first"),
            else: gettext("Changes to this target's rules, newest first")
        }
        changes={@history.rows}
        open={@open}
        diff={@diff}
        now={@now}
      />

      <div class="flex flex-wrap items-center justify-between gap-3">
        <p id="history-foot" class="max-w-[70ch] text-[12.5px]/[18px] text-faint">
          {gettext("Showing %{shown} of %{total}.",
            shown: Format.number(length(@history.rows)),
            total: Format.number(@history.total)
          )}
          <span :if={@scope == :workspace}>
            {gettext("A change to the default mode re-renders every target that follows it.")}
          </span>
          {gettext(
            "A change that leaves the document's bytes the same is kept here and makes no new version."
          )}
          <span :if={@scope == :workspace}>
            {gettext("Changes to a target's own rules are in that target's history.")}
          </span>
          <span :if={@scope == :target}>
            {gettext(
              "Changes to the workspace's rules, which re-render this target too, are in the workspace's history."
            )}
          </span>
        </p>
        <span :if={@history.pages > 1} class="flex gap-2">
          <.button
            id="history-newer"
            patch={page_path(@base, @history.page - 1)}
            disabled={@history.page <= 1}
          >
            {gettext("Newer")}
          </.button>
          <.button
            id="history-older"
            patch={page_path(@base, @history.page + 1)}
            disabled={@history.page >= @history.pages}
          >
            {gettext("Older")}
          </.button>
        </span>
      </div>
    </div>
    """
  end

  # The sentence under the document, split around the word that carries a tip.
  defp served_sentence(bytes) do
    rich_ngettext(
      "\"As served\" is the exact byte, %{number} of it, that the %{digest} is taken over.",
      "\"As served\" is the exact bytes, %{number} of them, that the %{digest} is taken over.",
      bytes,
      digest: :digest,
      number: Format.number(bytes)
    )
  end

  defp digest_tip,
    do:
      gettext(
        "The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy."
      )

  defp page_path(base, page) when page <= 1, do: base <> "/history"
  defp page_path(base, page), do: base <> "/history?page=#{page}"

  ## Version

  attr :v, :map, required: true
  attr :base, :string, required: true
  attr :now, :any, required: true

  def version_view(assigns) do
    ~H"""
    <div id="policy-version" class="grid grid-cols-[minmax(0,1fr)] gap-6">
      <.kvs id="version-strip">
        <.kv
          label={gettext("Rendered")}
          title={Format.datetime(@v.configuration.rendered_at, seconds: true, zone: true)}
        >
          <.relative_time at={@v.configuration.rendered_at} />
        </.kv>
        <.kv label={gettext("Changed by")}>{@v.changed_by || gettext("n/a")}</.kv>
        <.kv label={gettext("Change")}>{@v.change_words || gettext("First render")}</.kv>
        <.kv :if={@v.mode} label={gettext("Mode")}>
          {@v.mode}
          <:sub :if={@v.mode_source}>
            <span class="font-sans">
              {case @v.mode_source do
                :organisation -> gettext("required by %{name}", name: @v.mode_required_by || "?")
                :target -> gettext("this target's own")
                _workspace -> gettext("the workspace's default")
              end}
            </span>
          </:sub>
        </.kv>
        <.kv
          label={gettext("Digest")}
          tip={digest_tip()}
          mono
          title={@v.configuration.digest}
        >
          sha256={short_digest(@v.configuration.digest)}…
        </.kv>
        <.kv label={gettext("Size")}>
          {ngettext("%{number} byte", "%{number} bytes", byte_size(@v.configuration.document),
            number: Format.number(byte_size(@v.configuration.document))
          )}
        </.kv>
      </.kvs>

      <div class="q-twocol">
        <div class="grid min-w-0 gap-3">
          <div class="q-filters">
            <.segments id="version-view" label={gettext("View")}>
              <:segment
                :for={
                  {label, view} <- [
                    {if(@v.compare,
                       do: gettext("Changes from v%{version}", version: @v.compare.version),
                       else: gettext("Changes")
                     ), "changes"},
                    {gettext("Document"), "document"},
                    {gettext("As served"), "served"}
                  ]
                }
                patch={version_path(@base, @v, view: view)}
                pressed={@v.view == view}
              >
                {label}
              </:segment>
            </.segments>
            <span class="q-filters-grow"></span>
            <form
              :if={@v.compare_options != []}
              id="version-compare"
              phx-change="compare"
              class="flex items-center gap-2 text-[13px] text-muted"
              novalidate
            >
              <label for="version-compare-select">{gettext("Compare with")}</label>
              <select id="version-compare-select" name="compare" class="q-input q-input-m q-select">
                <option
                  :for={option <- @v.compare_options}
                  value={option.version}
                  selected={@v.compare && option.version == @v.compare.version}
                >
                  v{option.version} · {short_digest(option.digest)}
                </option>
              </select>
            </form>
          </div>

          <.doc_well id="version-doc">
            <:caption>
              run-configuration.json <span class="text-faint">· {@v.caption}</span>
            </:caption>
            <:actions>
              <.copy_button
                id="version-copy"
                text={@v.configuration.document}
                label={gettext("Copy document")}
              />
            </:actions>
            <.diff_lines
              :if={@v.view == "changes"}
              id="version-lines"
              lines={@v.lines}
              label={
                if @v.compare,
                  do:
                    gettext("Difference between version %{from} and version %{to}",
                      from: @v.compare.version,
                      to: @v.configuration.version
                    ),
                  else: gettext("Version %{version}", version: @v.configuration.version)
              }
            />
            <.code_lines :if={@v.view == "document"} id="version-pretty" text={@v.pretty} />
            <pre
              :if={@v.view == "served"}
              id="version-served"
              class="q-served"
              tabindex="0"
              phx-no-format
            >{@v.configuration.document}</pre>
          </.doc_well>
          <p class="max-w-[78ch] text-[12.5px]/[18px] text-faint">
            <span :if={@v.view != "served"}>{gettext("Shown indented for reading.")}</span>
            <%= for part <- served_sentence(byte_size(@v.configuration.document)) do %>
              <.term
                :if={part == :digest}
                word={gettext("digest")}
                standard={digest_tip()}
                class="q-tip-wide"
              /><span :if={part != :digest}>{part}</span>
            <% end %>
            {gettext("Deny rules and locks are not in the document: they decide what it lists.")}
          </p>
        </div>

        <.sect
          id="version-list"
          title={gettext("Versions")}
          count={Format.number(@v.total)}
          class="q-sect-side"
        >
          <nav class="q-vlist" aria-label={gettext("Versions")}>
            <.link
              :for={item <- @v.versions}
              id={"ver-#{item.version}"}
              navigate={"#{@base}/versions/#{item.version}"}
              aria-current={item.version == @v.configuration.version && "page"}
            >
              <span class="q-vlist-v">v{item.version}</span>
              <span class="min-w-0 truncate">
                {item.words}
                <small class="block">
                  {Enum.join(
                    Enum.reject(
                      [Common.local(item.who), Format.relative(item.at, @now)],
                      &is_nil/1
                    ),
                    " · "
                  )}
                  <.source_chip
                    :if={item.workspace}
                    source={:workspace}
                    label={gettext("workspace")}
                    class="q-src-xs"
                  />
                </small>
              </span>
              <span class="font-mono text-[11.5px] text-faint">
                {String.slice(short_digest(item.digest) || "", 0, 8)}
              </span>
            </.link>
            <.link :if={@v.earlier > 0} navigate={"#{@base}/history"} class="!text-muted">
              <span></span>
              <span>
                {ngettext("%{number} earlier version", "%{number} earlier versions", @v.earlier,
                  number: Format.number(@v.earlier)
                )}
              </span>
              <.icon name="hero-chevron-right-micro" class="size-3" />
            </.link>
          </nav>
        </.sect>
      </div>
    </div>
    """
  end

  @doc "The path of a version page with its `view` and `compare`, defaults left out."
  def version_path(base, v, opts) do
    view = Keyword.get(opts, :view, v.view)
    compare = Keyword.get(opts, :compare, v.compare && v.compare.version)
    default = v.configuration.version - 1

    query =
      [{"view", view != "changes" && view}, {"compare", compare && compare != default && compare}]
      |> Enum.filter(&elem(&1, 1))

    "#{base}/versions/#{v.configuration.version}" <>
      if(query == [], do: "", else: "?" <> URI.encode_query(query))
  end

  ## Export

  @doc """
  The export of the version in force as a page of its own, at `…/versions/:n/export`: the
  title and what is exported, the texts to copy, and Done back to the version. The way
  back to the policy and the version is the frame's breadcrumb, never a trail of its own. Nothing here is a form. `heading` is h2 under a
  page's own title, as a target's Policy tab has. The heading takes the focus a page sends
  it (`policy-export-h`) when the page is reached by a patch, as Export is.
  """
  attr :export, :map, required: true
  attr :done, :string, required: true, doc: "the version's path, where Done goes back"
  attr :heading, :string, default: "h1", values: ~w(h1 h2)

  def export_page(assigns) do
    ~H"""
    <section id="policy-export" class="grid max-w-[100ch] gap-4" aria-labelledby="policy-export-h">
      <div class="grid gap-3">
        <header>
          <.dynamic_tag
            tag_name={@heading}
            id="policy-export-h"
            class="text-xl/7 font-semibold tracking-[-0.017em] outline-none"
            tabindex="-1"
          >
            {gettext("Export for a node without a server")}
          </.dynamic_tag>
          <p id="export-lead" class="mt-0.5 max-w-[80ch] text-sm/5 text-muted">
            <.rich text={export_lead(@export)} />
            {gettext("It is a copy: it does not follow later changes.")}
          </p>
        </header>
      </div>

      <.doc_well :if={@export.policy_file} id="export-policy">
        <:caption>{@export.file_name}</:caption>
        <:actions>
          <a
            id="export-download"
            class="btn btn-ghost btn-xs btn-keep font-sans"
            href={"data:text/yaml;charset=utf-8," <> URI.encode(@export.policy_file, &URI.char_unreserved?/1)}
            download={@export.file_name}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />{gettext("Download")}
          </a>
          <.copy_button id="export-policy-copy" text={@export.policy_file} label={gettext("Copy")} />
        </:actions>
        <.code_lines id="export-policy-text" text={@export.policy_file} />
      </.doc_well>

      <.doc_well :if={@export.policy_file} id="export-command">
        <:caption>{gettext("on the node")}</:caption>
        <:actions>
          <.copy_button id="export-command-copy" text={@export.command} label={gettext("Copy")} />
        </:actions>
        <pre tabindex="0" phx-no-format>{@export.command}</pre>
      </.doc_well>

      <.doc_well id="export-runner">
        <:caption>{gettext("runner.yaml · the egress section")}</:caption>
        <:actions>
          <.copy_button id="export-runner-copy" text={@export.runner_file} label={gettext("Copy")} />
        </:actions>
        <.code_lines id="export-runner-text" text={@export.runner_file} />
      </.doc_well>

      <p class="max-w-[80ch] text-[12.5px]/[18px] text-muted">
        <span :for={note <- @export.notes}>{note}</span>
        {gettext("Keep a policy file outside the checkout.")}
        {pgettext(
          "plain",
          "Deny rules and locks are already applied: the text lists what remains allowed."
        )}
      </p>

      <div class="q-save">
        <.button id="export-done" variant="primary" patch={@done}>{gettext("Done")}</.button>
      </div>
    </section>
    """
  end

  ## Inline confirmation

  @doc """
  A confirmation in place under the control whose act it confirms, in the look of
  `inline_confirm/1`, for a confirm that also shows a list (what enforce would deny): the
  question, what happens (`effect`, a paragraph of its own, `<id>-effect`), the
  rest (`inner_block`), then the act's button and Cancel. Never an overlay. Cancel takes
  the focus as it shows; where there is an effect, the section and Cancel are described by
  it, so it is read with them. Cancel and Escape send `dialog_cancel` with `return`, the
  control the focus goes back to.
  """
  attr :id, :string, required: true
  attr :question, :string, required: true
  attr :return, :string, required: true, doc: "the id of the control the focus goes back to"
  slot :effect, doc: "what the act does, the sentence the confirm is read with"
  slot :inner_block, doc: "what follows the effect: the list, the notes"
  slot :action, required: true, doc: "the act's button"

  def confirm_panel(assigns) do
    assigns = assign(assigns, :cancel, confirm_cancel(assigns.return))

    ~H"""
    <section
      id={@id}
      class="grid max-w-[80ch] gap-3 rounded-box border border-line bg-base-100 p-4"
      aria-labelledby={"#{@id}-question"}
      aria-describedby={@effect != [] && "#{@id}-effect"}
      phx-window-keydown={@cancel}
      phx-key="Escape"
    >
      <h3 id={"#{@id}-question"} class="q-confirm-q">{@question}</h3>
      <div class="q-confirm-sub grid gap-3">
        <p :if={@effect != []} id={"#{@id}-effect"} class="text-muted">{render_slot(@effect)}</p>
        {render_slot(@inner_block)}
      </div>
      <div class="q-confirm-act">
        {render_slot(@action)}
        <button
          id={"#{@id}-cancel"}
          type="button"
          class="btn btn-xs"
          aria-describedby={@effect != [] && "#{@id}-effect"}
          phx-click={@cancel}
          phx-mounted={JS.focus()}
        >
          {gettext("Cancel")}
        </button>
      </div>
    </section>
    """
  end

  @doc "What Cancel and Escape of a confirm in place send: `dialog_cancel`, and the focus's way back."
  def confirm_cancel(return), do: JS.push("dialog_cancel", value: %{focus: return})

  ## The keys of the page (ph)

  @doc """
  The list `?` shows and hides: the shortcuts of the policy pages, a small panel in the
  page's flow, never an overlay. The `PolicyPage` hook toggles it (`hidden`, which the
  server leaves to the browser) and closes it on Escape or Close.
  """
  def keys_panel(assigns) do
    ~H"""
    <section
      id="policy-keys"
      class="max-w-[60ch] rounded-box border border-line bg-base-100 p-4"
      aria-labelledby="policy-keys-h"
      tabindex="-1"
      hidden
      phx-mounted={JS.ignore_attributes(["hidden"])}
    >
      <div class="flex items-start justify-between gap-3">
        <h2 id="policy-keys-h" class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
          {gettext("Keys")}
        </h2>
        <button id="policy-keys-close" type="button" class="btn btn-xs" data-keys-close>
          {gettext("Close")}
        </button>
      </div>
      <dl class="q-keys mt-2 text-[13.5px]/5">
        <dt><kbd class="kbd kbd-sm">a</kbd></dt>
        <dd>{gettext("Add a rule: the composer's host field")}</dd>
        <dt><kbd class="kbd kbd-sm">{pgettext("key", "Enter")}</kbd></dt>
        <dd>{gettext("In the composer, save the rule once it reads back")}</dd>
        <dt><kbd class="kbd kbd-sm">?</kbd></dt>
        <dd>{gettext("This list")}</dd>
      </dl>
    </section>
    """
  end

  # The lead of the export: what is exported, as of which version, and in which files. A
  # target is named as it is addressed; the file's own head keeps its system and path.
  defp export_lead(export) do
    subject =
      if export.workspace,
        do:
          {:b, gettext("the workspace %{name}", name: export.workspace),
           "font-medium text-base-content"},
        else:
          {:b, export[:name] || export.subject,
           "font-mono text-[12.5px] font-medium text-base-content"}

    version =
      {:b, gettext("version %{version}", version: export.version),
       "font-medium text-base-content"}

    if export.policy_file,
      do:
        rich_gettext(
          "The effective policy of %{subject} as of %{version}, as the text a machine without a server takes: the file a runner takes with %{flag}, and the egress section of its runner file.",
          subject: subject,
          version: version,
          flag: {:m, "--policy", "font-mono text-[12.5px]"}
        ),
      else:
        rich_gettext(
          "The effective policy of %{subject} as of %{version}, as the text a machine without a server takes: the egress section of its runner file.",
          subject: subject,
          version: version
        )
  end
end
