defmodule ApiaryWeb.HarnessUpdateComponents do
  # The parts of Workspace settings › Harness (`ApiaryWeb.HarnessLive`) that show the
  # workspace's harness and its process (`Apiary.Processes.HarnessUpdate.status/1`):
  #
  # `rows/1` is Source, with the harness's title and its address as a link, Stack, and
  # Version, the branch it follows, or the tag or commit it is pinned to. With the
  # `workflow_model` feature, Version also has the commit the current process version
  # came from, and, for a harness repository that follows a branch with Keep the process
  # at the latest off, the commit the branch is at now, once a read of it returned one.
  #
  # `update/1` is the difference that Update from harness shows before a save
  # (`Apiary.Processes.HarnessUpdate.read/2`): the version and its commit against the
  # harness's version and commit, a summary, then a panel each for the stages, the
  # artifact types the workspace does not have, and a changed stack. Each stage's line is
  # the History's words (`ApiaryWeb.StagesLive.Words.change/4`), with the entries added
  # (+) or removed (−) under it: a description, a workflow of the sequence, or an input or
  # an output with whether it is required. Under the panels: the hint on the removed
  # lines, where the current version has edits saved since its harness commit; where work
  # items stay; and, with the switch off, that Save turns it on again.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Harnesses.Qory
  alias Apiary.Processes
  alias ApiaryWeb.HarnessComponents
  alias ApiaryWeb.StagesLive.Words

  @short 7

  attr :status, :map, required: true, doc: "`Apiary.Processes.HarnessUpdate.status/1`"
  attr :process, :boolean, default: false, doc: "whether the `workflow_model` feature is on"
  attr :branch_head, :string, default: nil, doc: "the commit a followed branch is at now"
  slot :change, doc: "the button that opens the harness choice"

  def rows(assigns) do
    assigns = assign(assigns, :address, address(assigns.status))

    ~H"""
    <div id="harness-rows" class="grid gap-3.5 text-[13.5px]/5">
      <div id="harness-row-source" class="flex flex-wrap items-start gap-x-6 gap-y-1">
        <p class="w-24 font-medium">{gettext("Source")}</p>
        <div class="grid min-w-0 flex-1 gap-0.5">
          <span id="harness-row-source-title">{title(@status)}</span>
          <span :if={@address} class="min-w-0 [overflow-wrap:anywhere]">
            <.external_link id="harness-row-source-link" href={@address}>{@address}</.external_link>
          </span>
        </div>
        {render_slot(@change)}
      </div>
      <div
        :if={@status.stack}
        id="harness-row-stack"
        class="flex flex-wrap items-start gap-x-6 gap-y-1"
      >
        <p class="w-24 font-medium">{gettext("Stack")}</p>
        <p class="min-w-0 flex-1">{@status.stack}</p>
      </div>
      <div id="harness-row-version" class="flex flex-wrap items-start gap-x-6 gap-y-1">
        <p class="w-24 font-medium">{gettext("Version")}</p>
        <div class="grid min-w-0 flex-1 gap-0.5">
          <span id="harness-row-version-line">{harness_version_words(@status.version)}</span>
          <span :if={@process && @status.in_use} id="harness-in-use" class="text-muted">
            <.rich text={
              rich_gettext("Version in use: %{commit}, process version %{number}",
                commit: {:code, short(@status.in_use)},
                number: @status.number
              )
            } />
          </span>
          <span
            :if={@process && now_at?(@status, @branch_head)}
            id="harness-now-at"
            class="text-muted"
          >
            <.rich text={
              rich_gettext("%{branch} is now at %{commit}",
                branch: @status.following,
                commit: {:code, short(@branch_head)}
              )
            } />
          </span>
        </div>
      </div>
    </div>
    """
  end

  @doc false
  # now_at?/2 is whether Version shows where the followed branch of a harness repository
  # is now: with Keep the process at the latest off and no edits saved since, at another
  # commit than the one in use. With edits saved, the notice of the stopped update shows
  # instead (`stopped?/2`).
  @spec now_at?(map, String.t() | nil) :: boolean
  def now_at?(%{source: :repository, following: branch, keep_latest: false} = status, head)
      when is_binary(branch) and is_binary(head),
      do: head != status.in_use and not status.edits

  def now_at?(_status, _head), do: false

  @doc false
  # stopped?/2 is the commit the notice of a stopped update shows, nil for no notice: for
  # a harness that follows a branch with Keep the process at the latest off, the commit
  # the branch is at now where it is another than the one in use; for a harness
  # repository, only after edits saved on the Workflows page (else `now_at?/2`).
  @spec stopped(map, String.t() | nil) :: String.t() | nil
  def stopped(%{following: branch, keep_latest: false} = status, head)
      when is_binary(branch) and is_binary(head) do
    if head != status.in_use and (status.source == :qory or status.edits), do: head
  end

  def stopped(_status, _head), do: nil

  # The harness's title: the Qory harness, or a harness repository.
  defp title(%{source: :qory}), do: gettext("Qory harness")
  defp title(_status), do: gettext("A harness source")

  # The address the Source row links to: the Qory harness's, or the repository's.
  defp address(%{source: :qory}), do: Qory.git()
  defp address(%{git: git}), do: git

  @doc false
  # harness_version_words/1 is a harness version as Version shows it: "Follows main", "Tag v2.4.0",
  # or a commit by its first 7 characters.
  @spec harness_version_words(Processes.HarnessUpdate.harness_version()) :: String.t()
  def harness_version_words({:branch, name}), do: gettext("Follows %{branch}", branch: name)
  def harness_version_words({:tag, name}), do: gettext("Tag %{tag}", tag: name)
  def harness_version_words({:commit, id}), do: gettext("Version %{commit}", commit: short(id))

  @doc false
  # compare_words/2 is the line above Update from harness, for the current version
  # `number` and the harness version.
  @spec compare_words(pos_integer, Processes.HarnessUpdate.harness_version()) :: String.t()
  def compare_words(number, {:branch, name}),
    do:
      gettext(
        "Compare version %{number} of the stages with the process at %{branch}, then save it as a new version.",
        number: number,
        branch: name
      )

  def compare_words(number, {:tag, name}),
    do:
      gettext(
        "Compare version %{number} of the stages with the process at tag %{tag}, then save it as a new version.",
        number: number,
        tag: name
      )

  def compare_words(number, {:commit, id}),
    do:
      gettext(
        "Compare version %{number} of the stages with the process at version %{commit}, then save it as a new version.",
        number: number,
        commit: short(id)
      )

  @doc false
  # stopped_words/2 is the notice of a stopped update: the commit the followed branch is
  # at now, which Update from harness brings in.
  @spec stopped_words(String.t(), String.t()) :: list
  def stopped_words(branch, commit),
    do:
      rich_gettext(
        "Press %{button} to bring in %{branch} at %{commit}. Edits saved on the Workflows page stop the automatic update.",
        button: {:b, gettext("Update from harness")},
        branch: branch,
        commit: {:code, short(commit)}
      )

  @doc false
  # latest_words/1 is the description of Keep the process at the latest, for the branch
  # the harness follows.
  @spec latest_words(String.t()) :: String.t()
  def latest_words(branch),
    do:
      gettext(
        "At each new version on %{branch}, Qory Apiary saves it as a new version of the stages. Edits saved on the Workflows page stop it.",
        branch: branch
      )

  attr :update, :map, required: true, doc: "`t:Apiary.Processes.HarnessUpdate.update/0`"
  attr :next, :integer, required: true, doc: "the number the saved version gets"
  attr :switch_off, :boolean, required: true, doc: "whether Save turns the switch on again"
  attr :saving, :boolean, default: false

  def update(assigns) do
    %{update: update} = assigns
    stages = stage_lines(update)

    assigns =
      assign(assigns,
        stages: stages,
        removed?: Enum.any?(stages, &match?({:del, _text}, &1)) and edits?(update.base)
      )

    ~H"""
    <section
      id="harness-update-diff"
      aria-labelledby="harness-update-title"
      class="grid gap-3 rounded-box border border-line bg-base-100 p-4"
    >
      <h2 id="harness-update-title" class="text-[15px]/6 font-semibold">
        <.rich text={heading(@update)} />
      </h2>
      <div class="q-diffbox q-diffbox-flat">
        <div class="q-diffbar">
          <.pill
            id="harness-update-from"
            label={"v#{@update.base.number}"}
            version={true}
            commit={@update.in_use}
          />
          <.icon name="hero-arrow-right-micro" class="size-3 text-faint" />
          <.pill id="harness-update-to" label={to_label(@update.version)} commit={@update.commit} />
          <span id="harness-update-summary">{summary(@update)}</span>
        </div>
        <div :if={@stages != []} id="harness-update-stages" class="q-dpanel">
          <div>
            <span>{gettext("stages")}</span><span>{ngettext(
              "%{number} change",
              "%{number} changes",
              length(@update.changes),
              number: Format.number(length(@update.changes))
            )}</span>
          </div>
          <div class="q-dlines q-dlines-sem">
            <.line :for={{kind, text} <- @stages} kind={kind} sub={kind != :ctx}>
              <.rich text={text} />
            </.line>
          </div>
        </div>
        <div :if={@update.added_types != []} id="harness-update-types" class="q-dpanel">
          <div>
            <span>{gettext("artifact types")}</span><span>{ngettext(
              "%{number} new",
              "%{number} new",
              length(@update.added_types),
              number: Format.number(length(@update.added_types))
            )}</span>
          </div>
          <div class="q-dlines q-dlines-sem">
            <.line :for={type <- @update.added_types} kind={:add}>
              <code class="q-rule">{type["name"]}</code>
            </.line>
          </div>
        </div>
        <div :if={@update.stack} id="harness-update-stack" class="q-dpanel">
          <div><span>{gettext("stack")}</span><span>{gettext("changed")}</span></div>
          <div class="q-dlines q-dlines-sem">
            <.line :if={@update.stack.from} kind={:del}>
              <code class="q-rule">{@update.stack.from}</code>
            </.line>
            <.line kind={:add}>
              <code class="q-rule">{@update.stack.to}</code>
            </.line>
          </div>
        </div>
      </div>
      <p :if={@removed?} id="harness-update-removed" class="text-[13.5px]/5">
        {gettext(
          "Check the removed lines before you save: they are edits saved on the Workflows page, and version %{number} does not keep them.",
          number: @next
        )}
      </p>
      <p id="harness-update-stay" class="text-[13.5px]/5 text-muted">
        {gettext(
          "Work items in progress stay on version %{number}. Work items taken in after the save follow version %{next}.",
          number: @update.base.number,
          next: @next
        )}
      </p>
      <p :if={@switch_off} id="harness-update-switch" class="text-[13.5px]/5 text-muted">
        {gettext("Save also turns Keep the process at the latest on again.")}
      </p>
      <div class="flex flex-wrap gap-2">
        <.button
          id="harness-update-save"
          variant="primary"
          size="sm"
          phx-click="update_save"
          phx-value-trial="false"
          disabled={@saving}
        >
          {gettext("Save")}
        </.button>
        <.button
          id="harness-update-try"
          size="sm"
          phx-click="update_save"
          phx-value-trial="true"
          disabled={@saving}
        >
          {gettext("Try first")}
        </.button>
        <.button id="harness-update-cancel" size="sm" phx-click="update_cancel" disabled={@saving}>
          {gettext("Cancel")}
        </.button>
      </div>
    </section>
    """
  end

  attr :kind, :atom, required: true, values: [:add, :del, :ctx]
  attr :sub, :boolean, default: false, doc: "whether the line is an entry under a change"
  slot :inner_block, required: true

  # One line of a panel, as the policy page's diff shows one
  # (`ApiaryWeb.PolicyComponents.diff_line/1`); an entry under a change is indented.
  defp line(assigns) do
    ~H"""
    <div class={[
      @kind == :add && "q-add",
      @kind == :del && "q-del",
      @kind == :ctx && "q-ctx",
      @sub && "q-dsub"
    ]}>
      <i aria-hidden="true">{gutter(@kind)}</i>
      <span><span :if={@kind == :add} class="sr-only">{gettext("Added:")}</span><span
        :if={@kind == :del}
        class="sr-only"
      >{gettext("Removed:")} </span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  defp gutter(:add), do: "+"
  defp gutter(:del), do: "−"
  defp gutter(_ctx), do: ""

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :version, :boolean, default: false, doc: "whether the label is a process version"
  attr :commit, :string, default: nil

  # A version as the policy page's pills show one: the label, then the commit, if any.
  defp pill(assigns) do
    ~H"""
    <span id={@id} class="q-vpill q-vpill-sm">
      <span class="q-vpill-v"><span :if={@version} class="sr-only">{gettext("Version")} </span>{@label}</span>
      <span :if={@commit} class="q-vpill-dg">{short(@commit)}</span>
    </span>
    """
  end

  defp to_label({_kind, name}) when is_binary(name),
    do: if(commit?(name), do: short(name), else: name)

  defp heading(%{version: {:branch, name}, commit: commit}),
    do:
      rich_gettext("Update from %{branch} at %{commit}",
        branch: name,
        commit: {:code, short(commit)}
      )

  defp heading(%{version: {:tag, name}}), do: rich_gettext("Update from tag %{tag}", tag: name)

  defp heading(%{commit: commit}),
    do: rich_gettext("Update from version %{commit}", commit: {:code, short(commit)})

  # "9 stage changes, 2 new artifact types, a changed stack", each part where it applies.
  defp summary(update) do
    stages = length(update.changes)
    types = length(update.added_types)

    parts =
      Enum.reject(
        [
          stages > 0 &&
            ngettext("%{number} stage change", "%{number} stage changes", stages,
              number: Format.number(stages)
            ),
          types > 0 &&
            ngettext("%{number} new artifact type", "%{number} new artifact types", types,
              number: Format.number(types)
            ),
          update.stack != nil && gettext("a changed stack")
        ],
        &(&1 == false)
      )

    case parts do
      [] ->
        gettext("No change.")

      [one] ->
        one

      [one, two] ->
        gettext("%{first}, %{second}", first: one, second: two)

      [one, two, three] ->
        gettext("%{first}, %{second}, %{third}", first: one, second: two, third: three)
    end
  end

  # Each change as a line, with the entries it added or removed under it.
  defp stage_lines(%{changes: changes, base: base, document: document}) do
    Enum.flat_map(changes, fn change ->
      [{:ctx, Words.change(change, base.document, document)} | entries(change)]
    end)
  end

  defp entries({:description_changed, _id, %{from: from, to: to}}),
    do: Enum.reject([from && {:del, from}, to && {:add, to}], &(&1 in [nil, false]))

  defp entries({:sequence_changed, _id, %{from: from, to: to}}) do
    {old, new} = {workflows(from), workflows(to)}

    for(name <- old -- new, do: {:del, rich_code(name)}) ++
      for(name <- new -- old, do: {:add, rich_code(name)})
  end

  defp entries({kind, _id, %{from: from, to: to}})
       when kind in [:inputs_changed, :outputs_changed] do
    {old, new} = {List.wrap(from), List.wrap(to)}

    for(entry <- old -- new, do: {:del, artifact(entry)}) ++
      for(entry <- new -- old, do: {:add, artifact(entry)})
  end

  defp entries(_change), do: []

  # Every workflow entry of a sequence, a loop's body included, once per entry.
  defp workflows(sequence) when is_list(sequence) do
    Enum.flat_map(sequence, fn
      %{"loop" => %{"body" => body}} -> Enum.map(body, & &1["workflow"])
      entry -> [entry["workflow"]]
    end)
  end

  defp workflows(_none), do: []

  defp rich_code(text), do: [{:code, text}]

  defp artifact(%{"type" => type, "required" => true}),
    do: rich_gettext("%{type}, required", type: {:code, type})

  defp artifact(%{"type" => type}), do: rich_gettext("%{type}, optional", type: {:code, type})

  @doc false
  # edits?/1 is whether `version` was saved with edits on the Workflows page: a version
  # after the first with no harness commit of its own.
  @spec edits?(Apiary.Processes.Version.t()) :: boolean
  def edits?(%{based_on_id: nil}), do: false
  def edits?(%{template: %{"commit" => commit}}) when is_binary(commit), do: false
  def edits?(_version), do: true

  @doc false
  # reason_words/3 is why Update from harness has nothing to show
  # (`t:Apiary.Processes.HarnessUpdate.reason/0`), the fix first.
  @spec reason_words(term, map, map) :: String.t() | list
  def reason_words({:read, reason}, source, scope),
    do:
      HarnessComponents.read_words(
        reason,
        source,
        scope.organisation.name,
        scope.workspace.name
      )

  def reason_words({:qory, {:ref_missing, _ref} = failure}, _source, _scope),
    do: HarnessComponents.qory_words(failure, :workspace)

  def reason_words({:qory, {:unreadable, cause, _hop}}, _source, _scope),
    do:
      gettext(
        "Press Update from harness again later. Reading the harness from %{url} failed: %{cause}.",
        url: Qory.git(),
        cause: Qory.cause_words(cause)
      )

  def reason_words(:no_template, _source, _scope),
    do:
      gettext(
        "Choose a harness with a process for this type of workspace. The harness has no template of this workspace's type at this version."
      )

  def reason_words({:types, refusals}, _source, _scope),
    do: invalid_words(Enum.map(refusals, &Apiary.Artifacts.TemplateTypes.message/1))

  def reason_words({:not_readable, {:types, refusals}}, source, scope),
    do: reason_words({:types, refusals}, source, scope)

  def reason_words({:not_readable, _reason}, _source, _scope),
    do: invalid_words([gettext("its process is not valid")])

  def reason_words(errors, _source, _scope) when is_list(errors),
    do: invalid_words(Enum.map(errors, &Words.refusal(&1, %{})))

  def reason_words(:forbidden, _source, _scope), do: Words.refusal(:forbidden, nil)

  def reason_words(_exited, source, scope),
    do: HarnessComponents.read_words(:exited, source, scope.organisation.name)

  defp invalid_words(reasons),
    do:
      gettext(
        "Correct the process.yaml of the harness, then press Update from harness again: %{reasons}",
        reasons: Enum.join(reasons, " ")
      )

  defp commit?(name), do: Qory.commit?(name)
  defp short(id) when is_binary(id), do: String.slice(id, 0, @short)
  defp short(_id), do: nil
end
