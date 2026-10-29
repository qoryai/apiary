defmodule ApiaryWeb.HarnessComponents do
  # The harness choice of a workspace (`Apiary.Stacks.Sources.choose/3`), as the set-up's
  # Harness step (`ApiaryWeb.WorkspaceSetupLive`) and Workspace settings › Workflow
  # (`ApiaryWeb.WorkflowLive`) show it, and the stacks chosen for the workspace's
  # destinations (`Apiary.Stacks.Sources.choose_target/3`), as both pages show them; both
  # handle the destinations' events with `ApiaryWeb.HarnessTargets`.
  #
  # `about/1` is the five paragraphs of the side note, About this step: what a harness
  # is; the order of a run's harness, the target's root harness file first, then the stack
  # set for the target, then the workspace's harness, then the Qory harness; the Qory
  # harness's versions; the stacks a harness source exports; and the two kinds of version.
  #
  # `choices/1` is the two choices, the fields of the form `harness`: `choice`, `qory`
  # or `repository`. The Qory harness shows no address and no commit. Chosen, it shows
  # Version: `qory_version` `latest`, or `named` with `qory_name`, a name the release
  # lists (`Apiary.Lingo.Domain.Definition.qory_harness/0`); with no name listed, A fixed
  # version is disabled, with the line about named versions under it. A harness repository
  # shows the connected repositories (`Apiary.Stacks.Sources.repositories/1`) under one
  # choice with a search box, `source`, with Reading… until they are listed; then the
  # stacks the chosen one exports (`exports`, read by the page with
  # `Apiary.Stacks.Sources.exports/2`), `stack`, a radio for each, or a line in place of
  # Stack where it exports none; then Version: `version` `branch`, with `branch`, the
  # branch whose newest commit each run reads, or `fixed`, with `fixed`, a tag or a full
  # commit id. With `shared`, as the Harness step passes it, `choices/1` lists a harness
  # repository the organisation shares first, as the `choice` `shared`, with its version as
  # one line under its title and no field. A shared Qory harness shows as the `qory`
  # choice, the same row as in a workspace with no shared harness. `line/1` is the choice
  # as Workflow shows it.
  # `form_params/2` is the form's values for a saved choice, `fill/3` the values sent with
  # the saved choice's where a field is absent, `choice/3` the choice the values come to,
  # and `refusal_words/4` why a save was refused.
  #
  # `targets/1` is the destinations under a heading, each with a Stack select: the
  # workspace's harness (no stack of the destination's, the default), each stack the
  # workspace's harness exports, the stack saved for it where that is a stack of another
  # repository, and A stack of another repository…. The select's options are read from
  # the saved choice of the workspace, not from the form above. A stack of another
  # repository opens the form `target_stack` of one destination, with the field
  # `source`, among the three groups of Workflow's Source (`source_options/2`). A
  # connected repository then shows its exported stacks, `stack`, and Version as
  # `choices/1` does; an assigned source or a public address, a stack of the read of
  # `Apiary.Stacks.Sources.read/2`, by its index, and for an address `ref`, its branch or
  # tag. `target_choice/1` is the choice that form comes to.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Lingo.Domain.Definition
  alias Apiary.Stacks.Document

  @short 7
  # The words `Apiary.Stacks.Document.unreadable/1` returns for the reader's
  # `:invalid_stack`, `:invalid_exports`, `:invalid_harness` and `:not_a_mapping`. On a
  # save, the walk reads a root harness file's `exports` and a `qory-stack.yaml`, so its
  # `yaml` rule has these words for `exports` or a stack section that is not valid, or
  # for a root file that is no mapping.
  @section_words elem(Document.unreadable(:invalid_stack), 0)

  @doc false
  # about/1 is the side note of the Harness step, the paragraphs under About this step.
  def about(assigns) do
    ~H"""
    <p id="harness-about-what">
      {gettext("A harness is the skills and workflows the agent runs with.")}
    </p>
    <p id="harness-about-order">
      {gettext(
        "A target whose harness.yaml or qory.yaml at its root sets a harness runs with that file. Every other target runs with the stack set for it under Targets, else with the harness you choose here, else with the Qory harness."
      )}
    </p>
    <p id="harness-about-qory">
      {gettext(
        "The Qory harness is the harness Qory publishes. Always the latest version uses the newest version this Qory Apiary ships, and moves on when Qory Apiary is upgraded."
      )}
    </p>
    <p id="harness-about-exports">
      {gettext(
        "A harness source exports stacks in the qory.yaml or harness.yaml at its root. Qory Apiary reads that file in the target you pick, and offers only the stacks it exports."
      )}
    </p>
    <p id="harness-about-versions">
      {gettext(
        "Always the latest: each run uses the newest version when it starts. A fixed version uses that version."
      )}
    </p>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  attr :linked, :list,
    default: nil,
    doc: "the connected repositories, nil while they are listed"

  attr :exports, :any,
    default: nil,
    doc:
      "the stacks the chosen repository exports: nil for none chosen, `:reading`, " <>
        "`{:ok, names}` or `{:error, reason}`"

  attr :organisation, :string, required: true
  attr :disabled, :boolean, default: false

  attr :shared, :map,
    default: nil,
    doc:
      "the harness the organisation shares; a harness repository is listed first as the " <>
        "choice `shared`; nil for none"

  # The two choices, and the fields of the one chosen. With `shared` a harness repository,
  # it comes first, under "Shared in <organisation>", marked "every workspace", with its
  # version as a line under its title (`chosen_line/1`) and no field. A shared Qory harness
  # adds no row: the Qory harness row is the same with it or without it.
  def choices(assigns) do
    shared = assigns.shared
    group = match?(%{choice: :repository}, shared)

    assigns =
      assign(assigns,
        choice: assigns.form[:choice].value,
        source: source(assigns.linked, assigns.form[:source].value),
        named: Definition.qory_harness().named,
        group: group,
        shared_title: group && choice_title(:repository),
        shared_line: group && chosen_line(shared),
        options: [{"qory", choice_title(:qory)}, {"repository", choice_title(:repository)}]
      )

    ~H"""
    <fieldset id="harness-choice" class="q-choices grid gap-2">
      <div
        :if={@group}
        id="harness-choice-shared-group"
        role="group"
        aria-labelledby="harness-choice-shared-h"
        class="grid gap-2"
      >
        <p id="harness-choice-shared-h" class="text-[12.5px]/[18px] font-medium text-muted">
          {gettext("Shared in %{organisation}", organisation: @organisation)}
        </p>
        <label id="harness-choice-shared" for="harness-choice-shared-radio" class="q-choice">
          <input
            type="radio"
            id="harness-choice-shared-radio"
            name={@form[:choice].name}
            value="shared"
            checked={@choice == "shared"}
            disabled={@disabled}
            class="radio radio-sm radio-primary"
          />
          <span class="q-choice-h">
            {@shared_title}<span class="font-normal text-muted"> · {gettext("every workspace")}</span>
          </span>
          <span id="harness-choice-shared-line" class="q-choice-p">{@shared_line}</span>
        </label>
      </div>
      <label
        :for={{value, title} <- @options}
        id={"harness-choice-#{value}"}
        for={"harness-choice-#{value}-radio"}
        class="q-choice"
      >
        <input
          type="radio"
          id={"harness-choice-#{value}-radio"}
          name={@form[:choice].name}
          value={value}
          checked={@choice == value}
          disabled={@disabled}
          class="radio radio-sm radio-primary"
        />
        <span class="q-choice-h">{title}</span>
      </label>
    </fieldset>

    <fieldset :if={@choice == "qory"} id="harness-qory-version" class="fieldset grid gap-2">
      <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Version")}</legend>
      <label for="harness-qory-version-latest" class="flex items-center gap-2 text-[13.5px]/5">
        <input
          type="radio"
          id="harness-qory-version-latest"
          name={@form[:qory_version].name}
          value="latest"
          checked={@form[:qory_version].value != "named"}
          disabled={@disabled}
          class="radio radio-sm radio-primary"
        />
        {gettext("Always the latest version")}
      </label>
      <label for="harness-qory-version-named" class="flex items-center gap-2 text-[13.5px]/5">
        <input
          type="radio"
          id="harness-qory-version-named"
          name={@form[:qory_version].name}
          value="named"
          checked={@named != [] and @form[:qory_version].value == "named"}
          disabled={@disabled or @named == []}
          aria-describedby={@named == [] && "harness-qory-version-none"}
          class="radio radio-sm radio-primary"
        />
        {gettext("A fixed version")}
      </label>
      <p :if={@named == []} id="harness-qory-version-none" class="pl-6 text-[13px]/5 text-muted">
        {gettext("Named versions come with the first release of the Qory harness.")}
      </p>
      <.input
        :if={@named != [] and @form[:qory_version].value == "named"}
        field={@form[:qory_name]}
        id="harness-qory-name"
        type="select"
        aria-label={gettext("A fixed version")}
        options={Enum.map(@named, & &1.name)}
        disabled={@disabled}
      />
    </fieldset>

    <div :if={@choice == "repository"} id="harness-repository" class="grid gap-4">
      <.input
        field={@form[:source]}
        id="harness-source"
        type="choice"
        label={gettext("Target")}
        prompt={if is_nil(@linked), do: gettext("Reading…"), else: gettext("Find a target")}
        search_label={gettext("Find a target")}
        options={Enum.map(@linked || [], &source_option/1)}
        search={@linked not in [nil, []] || nil}
        disabled={@disabled or @linked in [nil, []]}
      />
      <p :if={@linked == []} id="harness-source-none" class="text-[13px]/5 text-muted">
        {gettext("%{organisation} has no connected target. Connect a work source to pick one.",
          organisation: @organisation
        )}
      </p>
      <.exported
        id="harness-stack"
        field={@form[:stack]}
        source={@source}
        exports={@exports}
        organisation={@organisation}
        disabled={@disabled}
      />
      <.version id="harness" form={@form} disabled={@disabled} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :source, :map, default: nil
  attr :exports, :any, default: nil
  attr :organisation, :string, required: true
  attr :disabled, :boolean, default: false

  # The stacks the chosen repository exports: Reading… while they are read, why the read
  # failed, the line that it exports none in place of Stack, or a radio for each.
  defp exported(assigns) do
    ~H"""
    <p :if={@source && @exports == :reading} id={"#{@id}-reading"} class="text-[13px]/5 text-muted">
      {gettext("Reading the stack of %{source}…", source: @source.label)}
    </p>
    <.notice :if={@source && match?({:error, _reason}, @exports)} kind={:error}>
      <span id={"#{@id}-error"}>{read_words(elem(@exports, 1), @source, @organisation)}</span>
    </.notice>
    <p :if={@source && @exports == {:ok, []}} id={"#{@id}-none"} class="text-[13px]/5 text-muted">
      {no_stack_words(@source)}
    </p>
    <.input
      :if={@source && match?({:ok, [_ | _]}, @exports)}
      field={@field}
      id={@id}
      type="radio"
      label={gettext("Stack")}
      options={for name <- elem(@exports, 1), do: {name, name}}
      disabled={@disabled}
    />
    """
  end

  attr :id, :string, required: true, doc: "the prefix of the fields' ids"
  attr :form, Phoenix.HTML.Form, required: true
  attr :disabled, :boolean, default: false

  # A harness repository's version: Always the latest on a branch, or A fixed version, a
  # tag or a commit.
  defp version(assigns) do
    ~H"""
    <fieldset id={"#{@id}-version"} class="fieldset grid gap-2">
      <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Version")}</legend>
      <div class="flex flex-wrap items-center gap-2">
        <label for={"#{@id}-version-branch"} class="flex items-center gap-2 text-[13.5px]/5">
          <input
            type="radio"
            id={"#{@id}-version-branch"}
            name={@form[:version].name}
            value="branch"
            checked={@form[:version].value != "fixed"}
            disabled={@disabled}
            class="radio radio-sm radio-primary"
          />
          {gettext("Always the latest on")}
        </label>
        <input
          type="text"
          id={"#{@id}-branch"}
          name={@form[:branch].name}
          value={@form[:branch].value}
          aria-label={gettext("Always the latest on")}
          disabled={@disabled}
          autocomplete="off"
          spellcheck="false"
          class="input input-sm w-48 font-mono"
        />
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <label for={"#{@id}-version-fixed"} class="flex items-center gap-2 text-[13.5px]/5">
          <input
            type="radio"
            id={"#{@id}-version-fixed"}
            name={@form[:version].name}
            value="fixed"
            checked={@form[:version].value == "fixed"}
            disabled={@disabled}
            class="radio radio-sm radio-primary"
          />
          {gettext("A fixed version")}
        </label>
        <input
          type="text"
          id={"#{@id}-fixed"}
          name={@form[:fixed].name}
          value={@form[:fixed].value}
          placeholder={gettext("tag or version")}
          aria-label={gettext("A fixed version")}
          disabled={@disabled}
          autocomplete="off"
          spellcheck="false"
          class="input input-sm w-48 font-mono"
        />
      </div>
    </fieldset>
    """
  end

  attr :chosen, :map, required: true, doc: "the choice, `t:Apiary.Stacks.Sources.chosen/0`"

  # The choice and its version: "Qory harness", then "Always the latest version"; a
  # harness repository, then its stack, repository and version.
  def line(assigns) do
    ~H"""
    <span id="harness-line" class="grid gap-0.5">
      <span>{choice_title(@chosen.choice)}</span>
      <span id="harness-line-version" class="text-muted">
        {if @chosen.choice == :qory,
          do: version_line(@chosen),
          else: chosen_line(@chosen)}
      </span>
    </span>
    """
  end

  @doc false
  # chosen_line/1 is a stack as a page shows it, "%{stack} · %{harness} · %{version}":
  # its stack, else the folder it narrows to, else its root's `qory-stack.yaml`; the Qory
  # harness or its repository; and its version (`version_line/1`), the Qory harness's
  # newest as "latest".
  @spec chosen_line(map) :: String.t()
  def chosen_line(chosen) do
    narrowing = Map.get(chosen, :narrowing, %{})

    gettext("%{stack} · %{harness} · %{version}",
      stack: chosen[:stack] || narrowing["path"] || "qory-stack.yaml",
      harness: harness_words(chosen),
      version: if(chosen[:version] == :latest, do: gettext("latest"), else: version_line(chosen))
    )
  end

  defp harness_words(%{choice: :qory}), do: gettext("Qory harness")
  defp harness_words(%{git: git}), do: repository(git)

  # A version as a page shows it: a branch or a tag by its name, a commit by its first 7
  # characters, the Qory harness's newest as "Always the latest version", a named one by
  # its name; a row saved with no version, by its pin.
  defp version_line(%{version: :latest}), do: gettext("Always the latest version")
  defp version_line(%{version: {:commit, id}}), do: short(id)
  defp version_line(%{version: {_kind, name}}) when is_binary(name), do: name

  defp version_line(%{pin: pin}) when is_binary(pin),
    do: if(commit?(pin), do: short(pin), else: pin)

  defp version_line(_chosen), do: ""

  attr :targets, :list,
    required: true,
    doc:
      "the destinations: `id`, `title` and `chosen`, `t:Apiary.Stacks.Sources.target_chosen/0` or nil"

  attr :may, :boolean, required: true, doc: "whether the person may save"
  attr :edit, :map, default: nil, doc: "the destination being saved or chosen for, nil for none"

  attr :workspace, :map,
    required: true,
    doc: "the workspace's harness, `t:Apiary.Stacks.Sources.chosen/0`"

  attr :stacks, :list,
    default: nil,
    doc: "the stacks the workspace's harness exports, nil while they are read"

  attr :linked, :list,
    default: nil,
    doc: "the connected repositories, nil while they are listed"

  attr :assigned, :list, default: [], doc: "the sources an instance admin assigned"
  attr :organisation, :string, required: true

  # The destinations under a heading, each with its Stack select, and the form of the one
  # whose A stack of another repository… was chosen. No list shows for a workspace with no
  # destination.
  def targets(assigns) do
    assigns = assign(assigns, :saving, match?(%{saving: true}, assigns.edit))

    ~H"""
    <section
      :if={@targets != []}
      id="harness-targets"
      aria-labelledby="harness-targets-h"
      class="grid gap-2 pt-2"
    >
      <h2 id="harness-targets-h" class="text-[15px]/[22px] font-semibold tracking-[-0.006em]">
        {gettext("Targets")}
      </h2>
      <ul class="grid gap-3">
        <li :for={target <- @targets} id={"harness-target-#{target.id}"} class="grid gap-3">
          <form
            id={"harness-target-#{target.id}-form"}
            phx-change="choose_target_stack"
            class="flex flex-wrap items-center gap-x-6 gap-y-1 text-[13.5px]/5"
            novalidate
          >
            <span class="min-w-0 flex-1 truncate font-mono">{target.title}</span>
            <input type="hidden" name="row[id]" value={target.id} />
            <label for={"harness-target-#{target.id}-stack"} class="font-medium">
              {gettext("Stack")}
            </label>
            <select
              id={"harness-target-#{target.id}-stack"}
              name="row[stack]"
              class="select select-sm min-w-0 flex-1"
              disabled={!@may or @saving}
            >
              {Phoenix.HTML.Form.options_for_select(
                row_options(target, @workspace, @stacks),
                row_value(target, @edit)
              )}
            </select>
          </form>
          <.notice :if={@edit && @edit.id == target.id && @edit.refusal} kind={:error}>
            <span id="harness-target-refusal">{@edit.refusal}</span>
          </.notice>
          <.target_form
            :if={@may && @edit && @edit.id == target.id && @edit.open}
            edit={@edit}
            linked={@linked}
            assigned={@assigned}
            organisation={@organisation}
          />
        </li>
      </ul>
    </section>
    """
  end

  # The options of a destination's Stack select: the workspace's harness; each stack the
  # workspace's harness exports, `workspace:<stack>`; the destination's saved stack where
  # it is not one of those, `saved`; and A stack of another repository…, `other`.
  defp row_options(target, workspace, stacks) do
    followed =
      case target.chosen do
        %{version: :workspace, stack: stack} when is_binary(stack) -> [stack]
        _other -> []
      end

    names = Enum.uniq((stacks || []) ++ followed)

    workspace_options =
      for name <- names,
          do: {chosen_line(Map.put(workspace, :stack, name)), "workspace:" <> name}

    saved =
      case target.chosen do
        nil -> []
        %{version: :workspace} -> []
        chosen -> [{chosen_line(chosen), "saved"}]
      end

    [{gettext("Workspace's harness"), "default"}] ++
      workspace_options ++ saved ++ [{gettext("A stack of another target…"), "other"}]
  end

  # The option a destination's select shows: A stack of another repository… while its
  # form is open, else its saved stack.
  defp row_value(%{id: id}, %{id: id, open: true}), do: "other"
  defp row_value(%{chosen: nil}, _edit), do: "default"

  defp row_value(%{chosen: %{version: :workspace, stack: stack}}, _edit) when is_binary(stack),
    do: "workspace:" <> stack

  defp row_value(_target, _edit), do: "saved"

  attr :edit, :map, required: true
  attr :linked, :list, default: nil
  attr :assigned, :list, default: []
  attr :organisation, :string, required: true

  # The form of one destination's stack of another repository: Repository among the three
  # groups of Workflow's Source; for a connected repository, its exported stacks and
  # Version; for an assigned source or an address, the stacks read and, for an address,
  # the branch or tag.
  defp target_form(assigns) do
    edit = assigns.edit
    kind = edit.source && edit.source.kind

    assigns =
      assign(assigns,
        form:
          to_form(
            %{
              "source" => edit.source_id,
              "address" => edit.address,
              "stack" => edit.stack,
              "version" => edit.version,
              "branch" => edit.branch,
              "fixed" => edit.fixed,
              "ref" => edit.ref
            },
            as: :target_stack
          ),
        linked?: kind == :linked,
        ready: target_choice(edit) != nil
      )

    ~H"""
    <.form
      for={@form}
      id="harness-target-form"
      phx-change="pick_target"
      phx-submit="save_target"
      class="grid gap-4"
      novalidate
    >
      <.input
        field={@form[:source]}
        type="choice"
        label={gettext("Target")}
        prompt={gettext("Find a target")}
        search_label={gettext("Find a target")}
        options={source_options(@linked, @assigned)}
        search={@linked not in [nil, []] || nil}
        disabled={@edit.saving}
      />
      <.input
        :if={@edit.source_id == "address"}
        id="target_stack_address"
        name="target_stack[address]"
        value={@edit.address}
        type="text"
        label={gettext("Public address")}
        hint={pgettext("plain", "The repository's address, without a password or token in it.")}
        errors={List.wrap(@edit.address_error)}
        debounce="blur"
        disabled={@edit.saving}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
      />
      <%= if @linked? do %>
        <.exported
          id="target_stack_stack"
          field={@form[:stack]}
          source={@edit.source}
          exports={exports_state(@edit)}
          organisation={@organisation}
          disabled={@edit.saving}
        />
        <.version id="target_stack" form={@form} disabled={@edit.saving} />
      <% else %>
        <p :if={@edit.reading} id="harness-target-reading" class="text-[13px]/[20px] text-muted">
          {gettext("Reading the stack of %{source}…", source: @edit.source.label)}
        </p>
        <.notice :if={@edit.read_error} kind={:error}>
          <span id="harness-target-read-error">{read_words(
            @edit.read_error,
            @edit.source,
            @organisation
          )}</span>
        </.notice>
        <.input
          :if={@edit.stacks}
          field={@form[:stack]}
          type="select"
          label={gettext("Stack")}
          options={stack_options(@edit.stacks)}
          disabled={@edit.saving}
        />
        <.input
          :if={@edit.source && @edit.source.kind != :assigned}
          field={@form[:ref]}
          type="text"
          label={gettext("Harness version")}
          disabled={@edit.saving}
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
        />
      <% end %>

      <div class="flex gap-2">
        <.button
          id="harness-target-save"
          type="submit"
          variant="primary"
          disabled={!@ready or @edit.saving}
          loading_text={gettext("Saving")}
        >
          {if @edit.saving, do: gettext("Saving"), else: gettext("Save")}
        </.button>
        <.button
          id="harness-target-cancel"
          type="button"
          disabled={@edit.saving}
          phx-click="cancel_target"
        >
          {gettext("Cancel")}
        </.button>
      </div>
    </.form>
    """
  end

  # The read of a connected repository's exports in a destination's form, as `exported/1`
  # takes it.
  defp exports_state(%{reading: true}), do: :reading
  defp exports_state(%{read_error: reason}) when reason != nil, do: {:error, reason}
  defp exports_state(%{names: names}) when is_list(names), do: {:ok, names}
  defp exports_state(_edit), do: nil

  @doc false
  # source_options/2 is the groups of a Source choice, as Workflow and a destination's form
  # show it: the connected repositories, with Reading… until they are listed, which cannot
  # be chosen; the assigned sources; and the public address, which a search keeps in view.
  @spec source_options([map] | nil, [map]) :: [{String.t(), [map]}]
  def source_options(linked, assigned) do
    linked =
      case linked do
        nil -> [%{value: "", title: gettext("Reading…"), disabled: true}]
        linked -> Enum.map(linked, &source_option/1)
      end

    [
      {pgettext("plain", "Linked repositories"), linked},
      {gettext("Assigned by an instance admin"), Enum.map(assigned, &source_option/1)},
      {gettext("Public address"),
       [%{value: "address", title: gettext("Enter an address"), keep: true}]}
    ]
  end

  defp source_option(source), do: %{value: source.id, title: source.label, mono: :title}

  # Each stack read, by its index: its export name, else the folder it is in, else its
  # file at the root.
  defp stack_options(stacks) do
    for {stack, index} <- Enum.with_index(stacks),
        do: {stack.name || stack.base["path"] || "qory-stack.yaml", Integer.to_string(index)}
  end

  @doc false
  # read_words/3 is why the stacks of `source` were not read, as the Harness step,
  # Workflow and a destination's form show it: a reason of `Apiary.Stacks.Sources`, or
  # `:exited` for a read whose task exited.
  @spec read_words(term, map | nil, String.t()) :: String.t()
  def read_words(:not_covered, source, organisation),
    do:
      pgettext(
        "plain",
        "Link %{source} to %{organisation}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment.",
        source: label(source),
        organisation: organisation
      )

  def read_words(:no_stack, source, _organisation), do: no_stack_words(source)

  def read_words(:no_stack_file, source, _organisation), do: no_stack_file_words(source)

  def read_words({:limited, seconds}, source, _organisation),
    do:
      ngettext(
        "Wait %{count} second, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        "Wait %{count} seconds, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        seconds,
        source: label(source)
      )

  def read_words({:unreachable, adapter}, source, _organisation),
    do: unreachable_words(adapter, source)

  def read_words({:call_failed, adapter}, source, _organisation),
    do: call_failed_words(adapter, source)

  def read_words({:invalid_section, file}, source, _organisation),
    do: section_words(file, source)

  def read_words({:invalid, file, rule}, source, _organisation),
    do: invalid_words(file, rule, source)

  def read_words(:unreadable, source, _organisation), do: form_words(source)

  # `:exited`, or a reason no clause above matches.
  def read_words(_exited, source, _organisation), do: exited_words(source)

  # A read whose task exited, or a failure with no known cause.
  defp exited_words(source),
    do:
      gettext("Try again, or choose another source. Qory Apiary could not read %{source}.",
        source: label(source)
      )

  # An address, folder or version refused before any call.
  defp form_words(source),
    do:
      gettext(
        "Correct the address, folder or version of %{source}, or choose another source. Qory Apiary does not read it in that form.",
        source: label(source)
      )

  # A save refused for the content of the harness document, which breaks `rule`.
  defp harness_words(rule, source),
    do:
      gettext("Correct the harness in %{source}, or choose another source: %{rule}.",
        source: label(source),
        rule: ApiaryWeb.WorkItemComponents.harness_problem_words(rule)
      )

  # The words for a root that exports no stack: `{:ok, []}` of
  # `Apiary.Stacks.Sources.exports/2`, and `:no_stack` of `Apiary.Stacks.Sources.read/2`,
  # a root with no stack in `exports` and no `qory-stack.yaml`.
  defp no_stack_words(source),
    do:
      gettext(
        "%{source} exports no stack. Add a qory.yaml or harness.yaml at its root that lists the stack under exports.",
        source: label(source)
      )

  # The words for a stack whose `qory-stack.yaml` is missing: one a root harness file
  # lists, the folder a source is narrowed to, or the stack name it is narrowed to.
  defp no_stack_file_words(source),
    do:
      gettext(
        "Add a qory-stack.yaml file to %{source}, or choose another source: %{source} has no stack.",
        source: label(source)
      )

  # A call to the adapter shown as `adapter` that got no answer, or had no time left.
  defp unreachable_words(adapter, source),
    do:
      gettext(
        "Try again, or choose another source. Qory Apiary could not reach %{adapter} to read %{source}.",
        adapter: adapter,
        source: label(source)
      )

  # A call to the adapter shown as `adapter` that failed with an answer, such as a
  # refusal, or before it was sent.
  defp call_failed_words(adapter, source),
    do:
      gettext("Choose another source. The call to %{adapter} to read %{source} failed.",
        adapter: adapter,
        source: label(source)
      )

  # The file `file` of `source`, whose `exports` or stack section is not valid.
  defp section_words(file, source),
    do:
      gettext(
        "Correct %{file} in %{source}, or choose another source: its exports or stack section is not valid.",
        file: file,
        source: label(source)
      )

  # The file `file` of `source`, which breaks `rule`, a rule of the walk.
  defp invalid_words(file, rule, source),
    do:
      gettext("Correct %{file} in %{source}, or choose another source: %{rule}.",
        file: file,
        source: label(source),
        rule: ApiaryWeb.WorkItemComponents.harness_problem_words(rule)
      )

  @doc false
  # target_choice/1 is the choice the form of a destination comes to, for
  # `Apiary.Stacks.Sources.choose_target/3`: a connected repository's exported stack at
  # its version; an assigned source's or an address's stack of the index chosen, at the
  # branch or tag given, or at an assigned source's `ref`; nil for a form that has none.
  @spec target_choice(map) :: Apiary.Stacks.Sources.target_choice() | nil
  def target_choice(%{source: %{kind: :linked} = source, names: [_ | _] = names} = edit) do
    with true <- edit.stack in names,
         {_kind, _name} = version <- version(edit.version, edit.branch, edit.fixed) do
      {:repository, source, edit.stack, version}
    else
      _none -> nil
    end
  end

  def target_choice(%{source: %{kind: kind} = source, stacks: [_ | _] = stacks} = edit)
      when kind != :linked do
    ref = if kind == :assigned, do: source.ref, else: String.trim(edit.ref || "")

    with {index, ""} when index >= 0 <- Integer.parse(edit.stack || ""),
         %{} = stack <- Enum.at(stacks, index),
         true <- is_binary(ref) and ref != "" do
      {:stack, source, stack, ref}
    else
      _none -> nil
    end
  end

  def target_choice(_edit), do: nil

  # The version the fields come to: the branch, or a fixed version, a full commit id as a
  # commit and any other name as a tag; nil for a blank name.
  defp version(kind, branch, fixed) do
    name = String.trim(if(kind == "fixed", do: fixed, else: branch) || "")

    cond do
      name == "" -> nil
      kind != "fixed" -> {:branch, name}
      commit?(String.downcase(name)) -> {:commit, String.downcase(name)}
      true -> {:tag, name}
    end
  end

  @doc false
  # form_params/2 is the form's values for the saved choice `chosen`, among the connected
  # repositories `linked`, nil while they are listed: the Qory harness's version; a
  # harness repository's connected repository, its stack and its version, a row saved
  # with no version as a fixed version at its pin; else no repository and `main`.
  @spec form_params(map, [map] | nil) :: map
  def form_params(chosen, linked) do
    repository? = chosen.choice == :repository
    saved = repository? && Enum.find(linked || [], &(&1.git == chosen.git))

    {version, branch, fixed} =
      case repository? && chosen.version do
        {:branch, name} -> {"branch", name, ""}
        {kind, name} when kind in [:tag, :commit] -> {"fixed", "main", name}
        nil when is_binary(chosen.pin) -> {"fixed", "main", chosen.pin}
        _other -> {"branch", "main", ""}
      end

    %{
      "choice" => Atom.to_string(chosen.choice),
      "qory_version" => if(match?({:named, _}, chosen.version), do: "named", else: "latest"),
      "qory_name" =>
        case chosen.version do
          {:named, name} -> name
          _other -> ""
        end,
      "source" => (saved && saved.id) || "",
      "stack" => (repository? && chosen.stack) || "",
      "version" => version,
      "branch" => branch,
      "fixed" => fixed
    }
  end

  @fields ~w(qory_version qory_name source stack version branch fixed)

  @doc false
  # fill/3 is the form's `params` with the values of `form_params/2` where `params` has
  # none, as the fields of a choice not shown are not sent, and the saved repository where
  # `params` has an empty one: once the connected repositories are listed, a saved harness
  # repository shows chosen.
  @spec fill(map, map, [map] | nil) :: map
  def fill(params, chosen, linked) do
    defaults = chosen |> form_params(linked) |> Map.take(@fields)
    params = if params["source"] == "", do: Map.delete(params, "source"), else: params
    Map.merge(defaults, params)
  end

  @doc false
  # with_stack/2 is the form's `params` once the chosen repository's exports are read: a
  # stack it does not export is cleared, and with one export, that one is chosen.
  @spec with_stack(map, [String.t()]) :: map
  def with_stack(params, [name]), do: Map.put(params, "stack", name)

  def with_stack(params, names) do
    if params["stack"] in names, do: params, else: Map.put(params, "stack", "")
  end

  @doc false
  # choice/3 is the choice the form's `params` come to, among `linked` and the stacks
  # `exports` of the chosen repository, for `Apiary.Stacks.Sources.choose/3`: the Qory
  # harness at its newest version, or at a name the release lists; a stack of a harness
  # repository at its version; nil for a harness repository without a source, a stack
  # it exports or a version, and for any other value.
  @spec choice(map, [map] | nil, term) :: Apiary.Stacks.Sources.choice() | nil
  def choice(%{"choice" => "qory"} = params, _linked, _exports) do
    case params["qory_version"] do
      "named" ->
        name = params["qory_name"]
        if Definition.qory_commit(name || ""), do: {:qory, name}

      _latest ->
        {:qory, :latest}
    end
  end

  def choice(%{"choice" => "repository"} = params, linked, {:ok, names}) do
    with %{} = source <- source(linked, params["source"]),
         true <- params["stack"] in names,
         {_kind, _name} = version <- version(params["version"], params["branch"], params["fixed"]) do
      {:repository, source, params["stack"], version}
    else
      _none -> nil
    end
  end

  def choice(_params, _linked, _exports), do: nil

  @doc false
  # unchanged?/2 is whether `choice` is the saved choice `chosen`: the Qory harness at the
  # same version, or the same repository, stack and version.
  @spec unchanged?(Apiary.Stacks.Sources.choice() | nil, map) :: boolean
  def unchanged?({:qory, :latest}, %{saved: true, choice: :qory, version: :latest}), do: true

  def unchanged?({:qory, name}, %{saved: true, choice: :qory, version: {:named, name}}),
    do: true

  def unchanged?({:repository, source, stack, version}, %{saved: true} = chosen),
    do:
      chosen.choice == :repository and source.git == chosen.git and stack == chosen.stack and
        version == chosen.version

  def unchanged?(_choice, _chosen), do: false

  @doc false
  # refusal_words/4 is why the save of a harness repository, `source` at `ref`, was
  # refused, in the words of Workflow's reads of a source; nil for a refusal those words
  # do not cover. A ref the walk could not read (`unreadable_ref?/3`) gets the line
  # "Correct the harness version, …".
  @spec refusal_words(term, map | nil, String.t() | nil, String.t()) :: String.t() | nil
  def refusal_words({:limited, seconds}, source, _ref, _organisation),
    do:
      ngettext(
        "Wait %{count} second, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        "Wait %{count} seconds, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        seconds,
        source: label(source)
      )

  def refusal_words({:walk, %{failure: failure}}, source, _ref, organisation)
      when failure in [:not_covered, :not_allowed],
      do:
        pgettext(
          "plain",
          "Link %{source} to %{organisation}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment.",
          source: label(source),
          organisation: organisation
        )

  def refusal_words({:walk, failure}, source, ref, _organisation) do
    if unreadable_ref?(failure, source, ref),
      do:
        gettext(
          "Correct the harness version, or choose another harness source. Qory Apiary could not read %{ref} in %{source}: %{rule}.",
          ref: ref,
          source: label(source),
          rule: ApiaryWeb.WorkItemComponents.harness_rule_words(failure.rule)
        ),
      else: walk_words(failure, source)
  end

  def refusal_words(_reason, _source, _ref, _organisation), do: nil

  @doc false
  # refused/1 is the source and the version name of a refused save of `choice`, as
  # `refusal_words/4` takes them; nil and nil for a choice with no source.
  @spec refused(term) :: {map | nil, String.t() | nil}
  def refused({:repository, source, _stack, {_kind, name}}), do: {source, name}
  def refused({:stack, source, _stack, ref}), do: {source, ref}
  def refused(_choice), do: {nil, nil}

  # Why the walk of a save failed, from its detail: the adapter whose call got no answer
  # or failed; a stack the source does not export or has no stack file for; a file the
  # reader refuses, or both root harness files; an address, folder or version refused
  # before any call; or the content of the harness document. `:too_many` and
  # `:no_harness` keep the words of an unread source. Any other failure, `:walk_error`
  # among them, has the words of a read that exited.
  defp walk_words(%{failure: :adapter_unavailable, adapter: adapter}, source)
       when is_binary(adapter),
       do: unreachable_words(adapter, source)

  defp walk_words(%{failure: :adapter_failed, adapter: adapter}, source)
       when is_binary(adapter),
       do: call_failed_words(adapter, source)

  defp walk_words(%{failure: :invalid, rule: %{"rule" => rule}}, source)
       when rule in ["no_export", "no_stack_file"],
       do: no_stack_file_words(source)

  defp walk_words(
         %{
           failure: :invalid,
           rule: %{"rule" => "yaml", "values" => %{"file" => file}, "message" => @section_words}
         },
         source
       ),
       do: section_words(file, source)

  defp walk_words(
         %{failure: :invalid, rule: %{"rule" => "yaml", "values" => %{"file" => file}} = rule},
         source
       ),
       do: invalid_words(file, rule, source)

  defp walk_words(%{failure: :invalid, rule: %{"rule" => "both_files"} = rule}, source),
    do: invalid_words("harness.yaml", rule, source)

  defp walk_words(%{failure: failure}, source)
       when failure in [:scp_form, :credential_in_address],
       do: form_words(source)

  defp walk_words(%{failure: :invalid, rule: %{"rule" => rule}}, source)
       when rule in ["path", "path_form", "host", "host_encoded", "ref", "version"],
       do: form_words(source)

  defp walk_words(%{failure: :invalid, rule: %{"rule" => name} = rule}, source)
       when name in ["extends", "calls", "size", "not_text"],
       do: harness_words(rule, source)

  # A rule of the save check (`Apiary.Stacks.Document`): one with the value `source` or
  # `ref` is about an address or a ref; any other is about the document's content.
  defp walk_words(%{failure: :invalid, rule: %{"message" => _message} = rule}, source)
       when not is_map_key(rule, "rule") do
    if is_map_key(rule["values"] || %{}, "source") or is_map_key(rule["values"] || %{}, "ref"),
      do: form_words(source),
      else: harness_words(rule, source)
  end

  defp walk_words(%{failure: failure}, source) when failure in [:too_many, :no_harness],
    do: unread_words(source)

  defp walk_words(_failure, source), do: exited_words(source)

  defp unread_words(source),
    do:
      gettext(
        "Reload the page to read %{source} again, or choose another source. Qory Apiary could not read its stack: the call to its integration failed, or a file in it is not valid.",
        source: label(source)
      )

  # Whether the walk's `failure` is about `ref` of `source`, the version the person gave:
  # the read found no version for it, it is no version a read takes, or it breaks the
  # save rule of refs (`Apiary.Stacks.Document.ref_error/1`).
  defp unreadable_ref?(%{failure: :invalid, source: shown, rule: rule}, %{git: git}, ref)
       when is_binary(git) and is_binary(ref) do
    shown == Document.shown(git) and
      case rule do
        %{"rule" => "version", "values" => %{"ref" => ^ref}} ->
          true

        %{"rule" => "ref", "values" => %{"ref" => ^ref}} ->
          true

        %{"message" => message, "values" => %{"ref" => ^ref}} ->
          match?({^message, _values}, Document.ref_error(ref))

        _other ->
          false
      end
  end

  defp unreadable_ref?(_failure, _source, _ref), do: false

  defp label(%{label: label}), do: label
  defp label(_none), do: ""

  # The connected repository with the id `id`, else nil.
  defp source(linked, id) when is_list(linked) and is_binary(id),
    do: Enum.find(linked, &(&1.id == id))

  defp source(_linked, _id), do: nil

  @doc false
  # exports_source/1 is the source `Apiary.Stacks.Sources.exports/2` reads for the saved
  # harness repository `chosen`: its address, at the `ref` a run reads it at now.
  @spec exports_source(map) :: map
  def exports_source(%{git: git, pin: pin}),
    do: %{git: git, ref: pin || "HEAD", narrowing: %{}, label: repository(git)}

  # A harness's address without its scheme, as a credential-free address shows.
  defp address(git), do: git |> Document.shown() |> String.replace_prefix("https://", "")

  # The repository path of a harness's address, such as `acme/web-harness` for
  # `https://code.example.com/acme/web-harness.git`; else the address as shown.
  defp repository(git) when is_binary(git) do
    with %URI{host: host, path: "/" <> _ = path} when is_binary(host) and host != "" <-
           URI.parse(git),
         trimmed when trimmed != "" <-
           path |> String.trim("/") |> String.replace_suffix(".git", "") do
      trimmed
    else
      _other -> address(git)
    end
  end

  defp repository(_git), do: ""

  # Whether `ref` is a full commit id, 40 or 64 lower-case hex digits, as a pin is.
  defp commit?(ref) when is_binary(ref),
    do: String.match?(ref, ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)

  defp commit?(_ref), do: false

  # The title of a harness choice, as the choices show it.
  defp choice_title(:qory), do: gettext("Qory harness")
  defp choice_title(:repository), do: gettext("A harness source")

  defp short(pin) when is_binary(pin), do: String.slice(pin, 0, @short)
  defp short(_pin), do: ""
end
