defmodule ApiaryWeb.PolicyLive.Views do
  @moduledoc """
  The views the hive's policy and a repository's policy share
  (`docs/design/brief-policy.md`, pe4 and pe5): the history with its diffs, one version with
  its document, and the export. Function components; the two LiveViews load what they show
  through `ApiaryWeb.PolicyLive.Common`.
  """
  use ApiaryWeb, :html

  import ApiaryWeb.PolicyComponents

  alias ApiaryWeb.PolicyLive.Common

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
          <span><b>{@history.total}</b> {if @history.total == 1, do: "change", else: "changes"}</span>
          <span>
            <b>{@summary.versions}</b> {if @summary.versions == 1, do: "version", else: "versions"}
          </span>
          <span :if={@summary.since}>since <b>{short_date(@summary.since)}</b></span>
        </span>
      </div>

      <.sect :if={@history.rows == []} id="history-empty" title="No changes yet">
        <p class="px-4 py-3 text-[13px] text-muted">
          <%= if @summary.since do %>
            No changes yet. Version 1 was rendered on {short_date(@summary.since)}.
          <% else %>
            No changes yet. The first rule, or the first change of mode, starts the history.
          <% end %>
        </p>
      </.sect>

      <.change_list
        :if={@history.rows != []}
        id="history-list"
        label={
          if @scope == :hive,
            do: "Changes to the hive baseline, newest first",
            else: "Changes to this repository's rules, newest first"
        }
        changes={@history.rows}
        open={@open}
        diff={@diff}
        now={@now}
      />

      <div class="flex flex-wrap items-center justify-between gap-3">
        <p id="history-foot" class="max-w-[70ch] text-[12.5px]/[18px] text-faint">
          Showing {length(@history.rows)} of {@history.total}. A change that leaves the document's bytes the same is kept here and makes no new version.
          <span :if={@scope == :hive}>
            Changes to a repository's own rules are in that repository's history.
          </span>
          <span :if={@scope == :repository}>
            Changes to the hive's rules, which re-render this repository too, are in the hive's history.
          </span>
        </p>
        <span :if={@history.pages > 1} class="flex gap-2">
          <.button
            id="history-newer"
            patch={page_path(@base, @history.page - 1)}
            disabled={@history.page <= 1}
          >
            Newer
          </.button>
          <.button
            id="history-older"
            patch={page_path(@base, @history.page + 1)}
            disabled={@history.page >= @history.pages}
          >
            Older
          </.button>
        </span>
      </div>
    </div>
    """
  end

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
        <.kv label="Rendered" title={absolute(@v.configuration.rendered_at)}>
          <.relative_time at={@v.configuration.rendered_at} />
        </.kv>
        <.kv label="Changed by">{@v.changed_by || "n/a"}</.kv>
        <.kv label="Change">{@v.change_words || "First render"}</.kv>
        <.kv
          label="Digest"
          tip="The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy."
          mono
          title={@v.configuration.digest}
        >
          sha256={short_digest(@v.configuration.digest)}…
        </.kv>
        <.kv label="Size">{byte_size(@v.configuration.document)} bytes</.kv>
      </.kvs>

      <div class="q-twocol">
        <div class="grid min-w-0 gap-3">
          <div class="q-filters">
            <.segments id="version-view" label="View">
              <:segment
                :for={
                  {label, view} <- [
                    {if(@v.compare,
                       do: "Changes from v#{@v.compare.version}",
                       else: "Changes"
                     ), "changes"},
                    {"Document", "document"},
                    {"As served", "served"}
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
              <label for="version-compare-select">Compare with</label>
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
                label="Copy document"
              />
            </:actions>
            <.diff_lines
              :if={@v.view == "changes"}
              id="version-lines"
              lines={@v.lines}
              label={
                if @v.compare,
                  do:
                    "Difference between version #{@v.compare.version} and version #{@v.configuration.version}",
                  else: "Version #{@v.configuration.version}"
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
            <span :if={@v.view != "served"}>Shown indented for reading.</span>
            "As served" is the exact bytes, {byte_size(@v.configuration.document)} of them, that the
            <.term
              word="digest"
              standard="The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy."
              class="q-tip-wide"
            /> is taken over. Deny rules and locks are not in the document: they decide what it lists.
          </p>
        </div>

        <.sect id="version-list" title="Versions" count={@v.total} class="q-sect-side">
          <nav class="q-vlist" aria-label="Versions">
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
                  <.source_chip :if={item.hive} source={:hive} label="hive" class="q-src-xs" />
                </small>
              </span>
              <span class="font-mono text-[11.5px] text-faint">
                {String.slice(short_digest(item.digest) || "", 0, 8)}
              </span>
            </.link>
            <.link :if={@v.earlier > 0} navigate={"#{@base}/history"} class="!text-muted">
              <span></span>
              <span>{@v.earlier} earlier {if @v.earlier == 1, do: "version", else: "versions"}</span>
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
      title="Export for a node without a server"
      size="lg"
      on_cancel={JS.patch(@close)}
    >
      <p id="export-lead" class="text-muted">
        The effective policy of
        <b :if={@export.hive} class="font-medium text-base-content">the hive {@export.hive}</b>
        <b :if={!@export.hive} class="font-mono text-[12.5px] font-medium text-base-content">
          {@export.subject}
        </b>
        as of <b class="font-medium text-base-content">version {@export.version}</b>, as the text a machine without a server takes:
        <span :if={@export.policy_file}>
          the file a runner takes with <span class="font-mono text-[12.5px]">--policy</span>, and
        </span>
        the egress section of its runner file. It is a copy: it does not follow later changes.
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
            <.icon name="hero-arrow-down-tray-micro" class="size-4" />Download
          </a>
          <.copy_button id="export-policy-copy" text={@export.policy_file} label="Copy" />
        </:actions>
        <.code_lines id="export-policy-text" text={@export.policy_file} />
      </.doc_well>

      <.doc_well :if={@export.policy_file} id="export-command">
        <:caption>on the node</:caption>
        <:actions>
          <.copy_button id="export-command-copy" text={@export.command} label="Copy" />
        </:actions>
        <pre tabindex="0" phx-no-format>{@export.command}</pre>
      </.doc_well>

      <.doc_well id="export-runner">
        <:caption>runner.yaml · the egress section</:caption>
        <:actions>
          <.copy_button id="export-runner-copy" text={@export.runner_file} label="Copy" />
        </:actions>
        <.code_lines id="export-runner-text" text={@export.runner_file} />
      </.doc_well>

      <p class="text-[12.5px]/[18px] text-muted">
        <span :for={note <- @export.notes}>{note}</span>
        Keep a policy file outside the checkout. Deny rules and locks are already applied: the text lists what remains allowed.
      </p>
      <:footer>
        <.button variant="primary" patch={@close}>Done</.button>
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
          <h2 id="policy-keys-h" class="text-base/6 font-semibold tracking-[-0.01em]">Keys</h2>
        </div>
        <dl class="q-keys modal-body px-5 pb-5 pt-2 text-[13.5px]/5">
          <dt><kbd class="kbd kbd-sm">a</kbd></dt>
          <dd>Add a rule: the composer's host field</dd>
          <dt><kbd class="kbd kbd-sm">Enter</kbd></dt>
          <dd>In the composer, save the rule once it reads back</dd>
          <dt><kbd class="kbd kbd-sm">←</kbd> <kbd class="kbd kbd-sm">→</kbd></dt>
          <dd>Between the two modes; Space asks to switch</dd>
          <dt><kbd class="kbd kbd-sm">?</kbd></dt>
          <dd>This list</dd>
        </dl>
        <form method="dialog" class="modal-action flex-none">
          <button class="btn btn-sm" data-autofocus>Close</button>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button tabindex="-1" aria-hidden="true">Close</button>
      </form>
    </dialog>
    """
  end
end
