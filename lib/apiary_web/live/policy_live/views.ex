defmodule ApiaryWeb.PolicyLive.Views do
  @moduledoc """
  The views the hive's policy and a target's policy share
  (`docs/design/brief-policy.md`, pe4 and pe5): the history with its diffs, one version with
  its document, and the export. Function components; the two LiveViews load what they show
  through `ApiaryWeb.PolicyLive.Common`.
  """
  use ApiaryWeb, :html

  import ApiaryWeb.PolicyComponents
  import ApiaryWeb.RichText

  alias ApiaryWeb.PolicyLive.Common

  @doc "The first render of a policy page, before the socket connects: its shape, and nothing read."
  attr :title, :string, required: true

  def page_skeleton(assigns) do
    ~H"""
    <div id="policy-loading" class="grid grid-cols-[minmax(0,1fr)] gap-6" aria-busy="true">
      <.header>{@title}</.header>
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

  ## pe4. History

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
            <.sentence parts={
              rich_ngettext("%{number} change", "%{number} changes", @history.total,
                number: {:strong, to_string(@history.total)}
              )
            } />
          </span>
          <span>
            <.sentence parts={
              rich_ngettext("%{number} version", "%{number} versions", @summary.versions,
                number: {:strong, to_string(@summary.versions)}
              )
            } />
          </span>
          <span :if={@summary.since}>
            <.sentence parts={
              rich_gettext("since %{date}", date: {:strong, short_date(@summary.since)})
            } />
          </span>
        </span>
      </div>

      <.sect :if={@history.rows == []} id="history-empty" title={gettext("No changes yet")}>
        <p class="px-4 py-3 text-[13px] text-muted">
          <%= if @summary.since do %>
            {gettext("No changes yet. Version 1 was rendered on %{date}.",
              date: short_date(@summary.since)
            )}
          <% else %>
            {gettext("No changes yet.")}
            <span :if={@scope == :hive}>
              {gettext("Qory serves no policy for this hive until the first one.")}
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
          if @scope == :hive,
            do: gettext("Changes to the hive baseline, newest first"),
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
            shown: length(@history.rows),
            total: @history.total
          )}
          <span :if={@scope == :hive}>
            {gettext("A change to the default mode re-renders every target that follows it.")}
          </span>
          {gettext(
            "A change that leaves the document's bytes the same is kept here and makes no new version."
          )}
          <span :if={@scope == :hive}>
            {gettext("Changes to a target's own rules are in that target's history.")}
          </span>
          <span :if={@scope == :target}>
            {gettext(
              "Changes to the hive's rules, which re-render this target too, are in the hive's history."
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
      "\"As served\" is the exact byte, %{count} of it, that the %{digest} is taken over.",
      "\"As served\" is the exact bytes, %{count} of them, that the %{digest} is taken over.",
      bytes,
      digest: :digest
    )
  end

  defp digest_tip,
    do:
      gettext(
        "The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy."
      )

  defp page_path(base, page) when page <= 1, do: base <> "/history"
  defp page_path(base, page), do: base <> "/history?page=#{page}"

  ## pe5. Version

  attr :v, :map, required: true
  attr :base, :string, required: true
  attr :now, :any, required: true

  def version_view(assigns) do
    ~H"""
    <div id="policy-version" class="grid grid-cols-[minmax(0,1fr)] gap-6">
      <.kvs id="version-strip">
        <.kv label={gettext("Rendered")} title={absolute(@v.configuration.rendered_at)}>
          <.relative_time at={@v.configuration.rendered_at} />
        </.kv>
        <.kv label={gettext("Changed by")}>{@v.changed_by || gettext("n/a")}</.kv>
        <.kv label={gettext("Change")}>{@v.change_words || gettext("First render")}</.kv>
        <.kv :if={@v.mode} label={gettext("Mode")}>
          {@v.mode}
          <:sub :if={@v.mode_source}>
            <span class="font-sans">
              {if @v.mode_source == :target,
                do: gettext("this target's own"),
                else: gettext("the hive's default")}
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
          {ngettext("%{count} byte", "%{count} bytes", byte_size(@v.configuration.document))}
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

        <.sect id="version-list" title={gettext("Versions")} count={@v.total} class="q-sect-side">
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
                      [Common.local(item.who), relative_label(item.at, @now)],
                      &is_nil/1
                    ),
                    " · "
                  )}
                  <.source_chip
                    :if={item.hive}
                    source={:hive}
                    label={gettext("hive")}
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
                {ngettext("%{count} earlier version", "%{count} earlier versions", @v.earlier)}
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

  ## Export (S7)

  attr :export, :map, required: true
  attr :close, :string, required: true

  def export_modal(assigns) do
    ~H"""
    <.modal
      id="policy-export"
      title={gettext("Export for a node without a server")}
      size="lg"
      on_cancel={JS.patch(@close)}
    >
      <p id="export-lead" class="text-muted">
        <.sentence parts={export_lead(@export)} />
        {gettext("It is a copy: it does not follow later changes.")}
      </p>

      <.doc_well :if={@export.policy_file} id="export-policy">
        <:caption>{@export.file_name}</:caption>
        <:actions>
          <a
            id="export-download"
            class="btn btn-ghost btn-xs btn-keep font-sans"
            href={"data:text/yaml;charset=utf-8," <> URI.encode(@export.policy_file, &URI.char_unreserved?/1)}
            download={@export.file_name}
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-4" />{gettext("Download")}
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

      <p class="text-[12.5px]/[18px] text-muted">
        <span :for={note <- @export.notes}>{note}</span>
        {gettext("Keep a policy file outside the checkout.")}
        {pgettext(
          "plain",
          "Deny rules and locks are already applied: the text lists what remains allowed."
        )}
      </p>
      <:footer>
        <.button variant="primary" patch={@close}>{gettext("Done")}</.button>
      </:footer>
    </.modal>
    """
  end

  ## The keys of the page (ph)

  @doc "The list `?` opens: the shortcuts of the policy pages. A native dialog the `PolicyPage` hook shows."
  def keys_dialog(assigns) do
    ~H"""
    <dialog
      id="policy-keys"
      class="modal modal-bottom sm:modal-middle"
      aria-labelledby="policy-keys-h"
    >
      <div class="modal-box sm:max-w-[400px]">
        <div class="flex items-start justify-between gap-3 px-5 pt-5">
          <h2 id="policy-keys-h" class="text-base/6 font-semibold tracking-[-0.01em]">
            {gettext("Keys")}
          </h2>
        </div>
        <dl class="q-keys modal-body px-5 pb-5 pt-2 text-[13.5px]/5">
          <dt><kbd class="kbd kbd-sm">a</kbd></dt>
          <dd>{gettext("Add a rule: the composer's host field")}</dd>
          <dt><kbd class="kbd kbd-sm">{pgettext("key", "Enter")}</kbd></dt>
          <dd>{gettext("In the composer, save the rule once it reads back")}</dd>
          <dt><kbd class="kbd kbd-sm">←</kbd> <kbd class="kbd kbd-sm">→</kbd></dt>
          <dd>{gettext("Between the two modes; Space asks to switch")}</dd>
          <dt><kbd class="kbd kbd-sm">?</kbd></dt>
          <dd>{gettext("This list")}</dd>
        </dl>
        <form method="dialog" class="modal-action flex-none">
          <button class="btn btn-sm" data-autofocus>{gettext("Close")}</button>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button tabindex="-1" aria-hidden="true">{gettext("Close")}</button>
      </form>
    </dialog>
    """
  end

  # The lead of the export: what is exported, as of which version, and in which files.
  defp export_lead(export) do
    subject =
      if export.hive,
        do: {:strong, gettext("the hive %{name}", name: export.hive)},
        else: {:strong_mono, export.subject}

    version = {:strong, gettext("version %{version}", version: export.version)}

    if export.policy_file,
      do:
        rich_gettext(
          "The effective policy of %{subject} as of %{version}, as the text a machine without a server takes: the file a runner takes with %{flag}, and the egress section of its runner file.",
          subject: subject,
          version: version,
          flag: {:mono, "--policy"}
        ),
      else:
        rich_gettext(
          "The effective policy of %{subject} as of %{version}, as the text a machine without a server takes: the egress section of its runner file.",
          subject: subject,
          version: version
        )
  end

  ## A sentence with emphasis

  @doc """
  A translated sentence (`ApiaryWeb.RichText`) in the page's own emphasis: binaries,
  `{:strong, text}`, `{:strong_mono, text}`, `{:mono, text}` and `{:code, text}`. Everything
  is interpolated, so everything is escaped.
  """
  attr :parts, :list, required: true

  def sentence(assigns) do
    ~H"<.sentence_part :for={part <- @parts} part={part} />"
  end

  defp sentence_part(%{part: {:strong, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<b class="font-medium text-base-content">{@text}</b>|
  end

  defp sentence_part(%{part: {:strong_mono, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<b class="font-mono text-[12.5px] font-medium text-base-content">{@text}</b>|
  end

  defp sentence_part(%{part: {:mono, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<span class="font-mono text-[12.5px]">{@text}</span>|
  end

  defp sentence_part(%{part: {:code, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H|<code class="q-rule">{@text}</code>|
  end

  defp sentence_part(%{part: parts} = assigns) when is_list(parts) do
    ~H"<.sentence_part :for={part <- @part} part={part} />"
  end

  defp sentence_part(assigns), do: ~H"{@part}"
end
