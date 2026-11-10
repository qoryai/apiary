defmodule ApiaryWeb.StagesLive.Inspector do
  # The inspector of the Stages canvas: the selected stage's form, its name and description,
  # then a box each for its inputs, sequence, outputs and gate, or the same read-only (`may`
  # false), with the description above the boxes. A workflow's settings fold under its row,
  # closed until a person opens them; a closed fold's fields still go with the form. The
  # Workflows page and Instance settings › Workspace types show it beside the canvas; each sends
  # its form's events to `ApiaryWeb.StagesLive.Editor`.
  @moduledoc false

  use ApiaryWeb, :html

  import ApiaryWeb.PolicyComponents, only: [sect: 1]

  alias ApiaryWeb.MachineTypeWords
  alias ApiaryWeb.StagesLive.Words

  # A stage's alert lines: each workflow it runs that the harness does not list, in the
  # words for `harness` (`ApiaryWeb.StagesLive.Words.undeclared/3`).
  @doc false
  def stage_alerts(problems, stage, harness \\ :workspace) do
    for {:missing_workflow, id, name} <- problems,
        id == stage["id"],
        do: Words.undeclared(stage["name"], name, harness)
  end

  # Shown under a workspace's "Default machine type", which organisation people see: no
  # word "instance", and no link to Instance settings.
  @doc false
  def machine_hint,
    do:
      gettext(
        "Workflows that pick no machine type run on this one. The people who run this Qory Apiary add machine types."
      )

  attr :stage, :map, required: true
  attr :may, :boolean, required: true
  attr :last, :boolean, default: false, doc: "whether the stage is the only one"
  attr :declared, :list, required: true
  attr :types, :list, required: true
  attr :members, :list, required: true
  attr :people, :map, required: true, doc: "each member's name by user id"
  attr :stage_errors, :map, default: %{}, doc: "refusals of a save, by stage id"
  attr :rounds_errors, :map, default: %{}, doc: "refused rounds, by the loop's place"

  attr :workflow_errors, :map,
    default: %{},
    doc: "refused workflow names, by the entry's place: \"0\", or \"1-0\" in a loop"

  attr :refused_machines, :list,
    default: [],
    doc: "the machine types the last save refused, each shown as an error on rows with it"

  attr :problems, :list, required: true
  attr :machine, :string, required: true
  attr :machine_types, :list, default: [], doc: "the instance's machine types, for the picker"

  attr :marks, :list,
    default: nil,
    doc:
      "the workflows the harness lists, each marked with a check, any other with a cross; nil for no marks"

  attr :harness, :atom,
    default: :workspace,
    values: [:workspace, :qory_workspace, :qory],
    doc:
      "the harness the alerts name: the workspace's harness repository, the workspace's Qory harness, or the Qory harness of a workspace type"

  attr :from_update, :boolean,
    default: false,
    doc:
      "whether the workspace's process came from an update from its harness, for the words of a missing machine type key"

  attr :named, :boolean,
    default: true,
    doc: "whether a gate may name its approvers; false offers any member alone"

  def stage_panel(%{may: false} = assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-4"
    >
      <h2 id="stage-panel-title" class="text-[15px]/6 font-semibold">{@stage["name"]}</h2>
      <.alerts stage={@stage} problems={@problems} harness={@harness} />
      <%= if description = Words.description(@stage) do %>
        <dl class="grid gap-2 text-[13.5px]/5">
          <dt class="font-medium">{gettext("Description")}</dt>
          <dd id="stage-panel-description" class="whitespace-pre-line break-words" phx-no-format>{description}</dd>
        </dl>
      <% end %>
      <.sect id="stage-inputs" title={gettext("Inputs")} heading="h3" class="q-sect-side">
        <ul class={read_lines()}>
          <li :for={item <- @stage["inputs"]}>{artifact_line(item)}</li>
          <li :if={@stage["inputs"] == []}>{gettext("None")}</li>
        </ul>
      </.sect>
      <.sect id="stage-sequence" title={gettext("Sequence")} heading="h3" class="q-sect-side">
        <ul class={read_lines()}>
          <li :for={{line, workflow} <- sequence_lines(@stage, @machine, @machine_types)}>
            {line}<.workflow_mark :if={workflow} workflow={workflow} marks={@marks} class="ml-2" />
          </li>
          <li :if={@stage["sequence"] == []}>{gettext("No workflow")}</li>
        </ul>
      </.sect>
      <.sect id="stage-outputs" title={gettext("Outputs")} heading="h3" class="q-sect-side">
        <ul class={read_lines()}>
          <li :for={item <- @stage["outputs"]}>{artifact_line(item)}</li>
          <li :if={@stage["outputs"] == []}>{gettext("None")}</li>
        </ul>
      </.sect>
      <.sect id="stage-gate" title={gettext("Gate")} heading="h3" class="q-sect-side">
        <p class={read_lines()}>{Words.gate_value(@stage, @people)}</p>
      </.sect>
    </section>
    """
  end

  def stage_panel(assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-4"
    >
      <div class="flex items-start justify-between gap-3">
        <h2 id="stage-panel-title" class="min-w-0 break-words text-[15px]/6 font-semibold">
          {gettext("Edit %{stage}", stage: @stage["name"])}
        </h2>
        <.button
          id="stage-remove"
          size="xs"
          variant="danger-ghost"
          phx-click="remove_stage"
          phx-value-id={@stage["id"]}
          disabled={@last}
          aria-label={gettext("Remove %{stage}", stage: @stage["name"])}
        >
          {gettext("Remove")}
        </.button>
      </div>
      <.alerts stage={@stage} problems={@problems} harness={@harness} />
      <.form
        for={%{}}
        as={:stage}
        id="stage-form"
        phx-change="edit_stage"
        novalidate
        class="grid gap-4"
      >
        <input type="hidden" id="stage-form-id" name="stage[id]" value={@stage["id"]} />
        <.input
          id="stage-name"
          name="stage[name]"
          value={@stage["name"]}
          errors={Map.get(@stage_errors, @stage["id"], [])}
          label={gettext("Name")}
          maxlength="60"
          autocomplete="off"
        />
        <.input
          id="stage-description"
          type="textarea"
          name="stage[description]"
          value={@stage["description"]}
          label={gettext("Description")}
          maxlength={Apiary.Processes.description_limit()}
          rows="3"
        />

        <.artifacts key="inputs" stage={@stage} types={@types} />

        <.sect id="stage-sequence" title={gettext("Sequence")} heading="h3" class="q-sect-side">
          <:trailing>
            <.button id="stage-add-entry" type="button" size="xs" phx-click="add_entry">
              {gettext("Add workflow")}
            </.button>
            <.button id="stage-add-loop" type="button" size="xs" phx-click="add_loop">
              {gettext("Add loop")}
            </.button>
          </:trailing>
          <div class="grid gap-3 px-4 py-3">
            <p :if={@stage["sequence"] == []} class="text-[13px]/5 text-muted">
              {gettext("No workflow")}
            </p>
            <%= for {entry, i} <- Enum.with_index(@stage["sequence"]) do %>
              <%= if loop = entry["loop"] do %>
                <div
                  id={"stage-loop-#{i}"}
                  class="overflow-hidden rounded-box border border-dashed border-base-content/35"
                >
                  <div class="flex flex-wrap items-center justify-between gap-2 border-b border-line bg-base-200 px-3 py-1.5">
                    <div class="q-stage-rounds">
                      <.input
                        id={"stage-loop-#{i}-rounds"}
                        name={"stage[sequence][#{i}][rounds]"}
                        type="number"
                        min="1"
                        max="10"
                        value={loop["rounds"]}
                        errors={List.wrap(@rounds_errors[to_string(i)])}
                        label={gettext("Loop: rounds at most")}
                        class="w-14"
                      />
                    </div>
                    <.button
                      type="button"
                      size="xs"
                      variant="danger-ghost"
                      class="ml-auto"
                      phx-click="remove_loop"
                      phx-value-at={i}
                    >
                      {gettext("Remove loop")}
                    </.button>
                  </div>
                  <div class="px-3">
                    <.entry
                      :for={{inner, j} <- Enum.with_index(loop["body"])}
                      entry={inner}
                      name={"stage[sequence][#{i}][body][#{j}]"}
                      id={"stage-entry-#{i}-#{j}"}
                      stage_id={@stage["id"]}
                      declared={@declared}
                      machine={@machine}
                      machine_types={@machine_types}
                      marks={@marks}
                      errors={List.wrap(@workflow_errors["#{i}-#{j}"])}
                      refused={@refused_machines}
                      harness={@harness}
                      from_update={@from_update}
                      remove={length(loop["body"]) > 1 && %{"at" => j, "loop" => i}}
                      rule={j > 0}
                    />
                  </div>
                  <div class="border-t border-line px-3 py-1.5">
                    <.button type="button" size="xs" phx-click="add_entry" phx-value-loop={i}>
                      {gettext("Add workflow to the loop")}
                    </.button>
                  </div>
                </div>
              <% else %>
                <.entry
                  entry={entry}
                  name={"stage[sequence][#{i}]"}
                  id={"stage-entry-#{i}"}
                  stage_id={@stage["id"]}
                  declared={@declared}
                  machine={@machine}
                  machine_types={@machine_types}
                  marks={@marks}
                  errors={List.wrap(@workflow_errors[to_string(i)])}
                  refused={@refused_machines}
                  harness={@harness}
                  from_update={@from_update}
                  remove={%{"at" => i}}
                  rule={i > 0 and not Map.has_key?(Enum.at(@stage["sequence"], i - 1), "loop")}
                />
              <% end %>
            <% end %>
          </div>
        </.sect>

        <.artifacts key="outputs" stage={@stage} types={@types} />

        <.sect id="stage-gate" title={gettext("Gate")} heading="h3" class="q-sect-side">
          <fieldset class="grid gap-2 px-4 py-3">
            <legend class="sr-only">{gettext("Gate")}</legend>
            <label
              for="stage-gate-kind-0"
              class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
            >
              <input
                type="radio"
                id="stage-gate-kind-0"
                name="stage[gate][kind]"
                value="person"
                checked={@stage["gate"]["kind"] == "person"}
                class="radio radio-sm radio-primary"
              />
              <span>{gettext("A person approves before the work item moves on")}</span>
            </label>
            <div :if={@named and @stage["gate"]["kind"] == "person"} class="grid gap-2 pl-6">
              <.input
                id="stage-gate-approvers"
                name="stage[gate][approvers]"
                type="radio"
                value={if is_map(@stage["gate"]["approvers"]), do: "named", else: "members"}
                options={[
                  {gettext("Any member"), "members"},
                  {gettext("Named members"), "named"}
                ]}
              />
              <div
                :if={is_map(@stage["gate"]["approvers"])}
                id="stage-gate-named"
                class="grid gap-1 pl-6"
              >
                <input type="hidden" name="stage[gate][named][]" value="" />
                <label :for={m <- @members} class="inline-flex items-center gap-2 text-[13.5px]/5">
                  <input
                    type="checkbox"
                    name="stage[gate][named][]"
                    value={m.user.id}
                    checked={m.user.id in @stage["gate"]["approvers"]["members"]}
                    class="checkbox checkbox-sm checkbox-primary"
                  />
                  {m.user.email}
                </label>
                <%!-- A named approver who is no longer a member stays chosen until unticked. --%>
                <label
                  :for={id <- @stage["gate"]["approvers"]["members"]}
                  :if={not Map.has_key?(@people, id)}
                  class="inline-flex items-center gap-2 text-[13.5px]/5"
                >
                  <input
                    type="checkbox"
                    name="stage[gate][named][]"
                    value={id}
                    checked
                    class="checkbox checkbox-sm checkbox-primary"
                  />
                  {Words.person_first(@people, id)}
                </label>
              </div>
            </div>
            <label
              for="stage-gate-kind-1"
              class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
            >
              <input
                type="radio"
                id="stage-gate-kind-1"
                name="stage[gate][kind]"
                value="none"
                checked={@stage["gate"]["kind"] == "none"}
                class="radio radio-sm radio-primary"
              />
              <span>{gettext("No gate: the work item moves on when the sequence ends")}</span>
            </label>
          </fieldset>
        </.sect>
      </.form>
    </section>
    """
  end

  attr :stage, :map, required: true
  attr :problems, :list, required: true
  attr :harness, :atom, required: true

  defp alerts(assigns) do
    ~H"""
    <.notice :for={line <- stage_alerts(@problems, @stage, @harness)} kind={:warning}>
      <span data-stage-alert>{line}</span>
    </.notice>
    """
  end

  attr :entry, :map, required: true
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :stage_id, :string, required: true
  attr :declared, :list, required: true
  attr :machine, :string, required: true
  attr :machine_types, :list, required: true
  attr :marks, :list, required: true
  attr :errors, :list, required: true
  attr :refused, :list, required: true
  attr :harness, :atom, required: true
  attr :from_update, :boolean, required: true
  attr :remove, :any, required: true
  attr :rule, :boolean, required: true, doc: "whether a line separates the row from the one above"

  # A workflow's row: its name, its check or cross and Remove, and under them one line with
  # its settings, which opens them in place. The whole line is the `summary`, so a key or a
  # tap opens and closes the fold, and it ends in the word for what that does. The fold's id
  # includes the stage's, so an open fold stays with its stage; a patch leaves `open` as the
  # browser has it. A refused machine type shows on the line while the fold is closed, and at
  # the field while it is open. So does a key no machine type has, which a save keeps: a
  # warning to pick a type, while the entry's runs start on the workspace's default type.
  defp entry(assigns) do
    refused? = assigns.entry["machine"] in assigns.refused

    assigns =
      assign(assigns,
        machine_errors: if(refused?, do: [Words.machine_refused()], else: []),
        missing:
          if(
            not refused? and
              MachineTypeWords.missing?(assigns.machine_types, assigns.entry["machine"]),
            do: assigns.entry["machine"]
          )
      )

    ~H"""
    <div id={@id} class={["grid gap-0.5 py-1.5", @rule && "border-t border-line"]}>
      <div class="flex flex-wrap items-center gap-2">
        <div class="min-w-48 flex-1">
          <.input
            id={"#{@id}-workflow"}
            name={"#{@name}[workflow]"}
            value={@entry["workflow"]}
            aria-label={gettext("Workflow")}
            errors={@errors}
            list={"#{@id}-workflow-names"}
            maxlength="64"
            autocomplete="off"
            spellcheck="false"
            class="w-full font-mono"
          />
          <datalist id={"#{@id}-workflow-names"}>
            <option :for={name <- @declared} value={name}></option>
          </datalist>
        </div>
        <.workflow_mark
          :if={listed?(@entry, @marks)}
          workflow={@entry["workflow"]}
          marks={@marks}
          id={"#{@id}-workflow-mark"}
          icon_only
        />
        <.button
          :if={@remove}
          type="button"
          size="xs"
          variant="danger-ghost"
          class="ml-auto"
          phx-click="remove_entry"
          phx-value-at={@remove["at"]}
          phx-value-loop={@remove["loop"]}
          aria-label={gettext("Remove %{workflow}", workflow: @entry["workflow"])}
        >
          {gettext("Remove")}
        </.button>
        <.workflow_mark
          :if={not listed?(@entry, @marks)}
          workflow={@entry["workflow"]}
          marks={@marks}
          id={"#{@id}-workflow-mark"}
          class="w-full"
        />
      </div>
      <details
        id={"#{@id}-settings-#{@stage_id}"}
        class="q-tool group"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <%!-- `nokey`: the canvas's pan key is Space, which otherwise stops Space opening the fold. --%>
        <summary class="nokey">
          <span class="flex items-center gap-1.5 text-[12.5px]/[18px] text-muted max-md:min-h-10 pointer-coarse:min-h-10">
            <.icon name="hero-chevron-right-micro" class="q-chev size-3.5" />
            <span class="min-w-0 flex-1 [overflow-wrap:anywhere]">
              {gettext("Machine type: %{machine}",
                machine: MachineTypeWords.entry_words(@machine_types, @machine, @entry["machine"])
              )}
            </span>
            <span class="shrink-0 font-medium text-accent underline underline-offset-[3px] group-open:hidden">
              {gettext("Change")}
            </span>
            <span class="hidden shrink-0 font-medium text-accent underline underline-offset-[3px] group-open:inline">
              {gettext("Close")}
            </span>
          </span>
          <span
            :for={error <- @machine_errors}
            class="flex items-center gap-1.5 pl-5 text-[12.5px]/[18px] text-error group-open:hidden"
            data-machine-error
          >
            <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
            {error}
          </span>
          <span
            :if={@missing}
            id={"#{@id}-missing-line"}
            class="flex items-center gap-1.5 pl-5 text-[12.5px]/[18px] text-warning group-open:hidden"
          >
            <.icon name="hero-exclamation-triangle-micro" class="size-4 flex-none" />
            {Words.machine_missing_line(@missing)}
          </span>
        </summary>
        <div class="grid gap-3 pt-2 pb-2 pl-5">
          <.workflow_mark
            :if={listed?(@entry, @marks)}
            workflow={@entry["workflow"]}
            marks={@marks}
          />
          <.missing_machine
            :if={@missing}
            id={"#{@id}-missing"}
            key={@missing}
            workflow={@entry["workflow"]}
            fallback={MachineTypeWords.fallback_name(@machine_types, @machine)}
            harness={@harness}
            from_update={@from_update}
          />
          <.input
            id={"#{@id}-machine"}
            name={"#{@name}[machine]"}
            type="select"
            value={@entry["machine"] || ""}
            errors={@machine_errors}
            label={gettext("Machine type")}
            options={MachineTypeWords.entry_options(@machine_types, @machine, @entry["machine"])}
            class="w-64"
          />
        </div>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :workflow, :string, required: true
  attr :fallback, :string, required: true, doc: "the name of the type the runs start on"
  attr :harness, :atom, required: true
  attr :from_update, :boolean, required: true

  # The notice of a workflow entry whose key no machine type has. On a workspace type's
  # process, which no `process.yaml` of a workspace made, the line of the closed row.
  defp missing_machine(%{harness: :qory} = assigns) do
    ~H"""
    <div
      id={@id}
      role="note"
      class="alert alert-soft items-start bg-primary-soft text-primary-soft-content"
    >
      <.icon name="hero-exclamation-triangle-micro" class="mt-px size-4" />
      <p class="min-w-0">{Words.machine_missing_line(@key)}</p>
    </div>
    """
  end

  defp missing_machine(assigns) do
    ~H"""
    <div
      id={@id}
      role="note"
      class="alert alert-soft items-start bg-primary-soft text-primary-soft-content"
    >
      <.icon name="hero-exclamation-triangle-micro" class="mt-px size-4" />
      <p class="min-w-0 [overflow-wrap:anywhere]">
        <strong class="font-semibold">
          {gettext("Pick a machine type for %{workflow}.", workflow: @workflow)}
        </strong>
        <.rich text={Words.machine_missing(@key, @workflow, @fallback, @from_update)} />
      </p>
    </div>
    """
  end

  defp listed?(_entry, nil), do: false
  defp listed?(entry, marks), do: entry["workflow"] in marks

  attr :key, :string, required: true
  attr :stage, :map, required: true
  attr :types, :list, required: true

  defp artifacts(assigns) do
    ~H"""
    <.sect
      id={"stage-#{@key}"}
      title={if @key == "inputs", do: gettext("Inputs"), else: gettext("Outputs")}
      heading="h3"
      class="q-sect-side"
    >
      <:trailing>
        <.button
          id={"stage-add-#{@key}"}
          type="button"
          size="xs"
          phx-click="add_artifact"
          phx-value-key={@key}
        >
          {if @key == "inputs", do: gettext("Add input"), else: gettext("Add output")}
        </.button>
      </:trailing>
      <div class="px-4 py-1">
        <p :if={@stage[@key] == []} class="py-2 text-[13px]/5 text-muted">{gettext("None")}</p>
        <div
          :for={{item, i} <- Enum.with_index(@stage[@key])}
          id={"stage-#{@key}-#{i}"}
          class={[
            "flex flex-wrap items-center gap-x-3 gap-y-1 py-2",
            i > 0 && "border-t border-line"
          ]}
        >
          <div class="min-w-48 flex-1">
            <.input
              id={"stage-#{@key}-#{i}-type"}
              name={"stage[#{@key}][#{i}][type]"}
              type="select"
              value={item["type"]}
              aria-label={gettext("Type")}
              options={Enum.uniq(Enum.map(@types, & &1.name) ++ [item["type"]])}
              class="w-full"
            />
          </div>
          <.input
            id={"stage-#{@key}-#{i}-required"}
            name={"stage[#{@key}][#{i}][required]"}
            type="checkbox"
            value={item["required"] == true}
            label={gettext("Required")}
          />
          <.button
            type="button"
            size="xs"
            variant="danger-ghost"
            class="ml-auto"
            phx-click="remove_artifact"
            phx-value-key={@key}
            phx-value-at={i}
            aria-label={gettext("Remove %{type}", type: item["type"])}
          >
            {gettext("Remove")}
          </.button>
        </div>
      </div>
    </.sect>
    """
  end

  attr :workflow, :string, required: true
  attr :marks, :list, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :icon_only, :boolean, default: false, doc: "the words for a screen reader and as a title"

  # A check when the harness lists the workflow, else a cross, each with its words; nothing
  # with no list.
  defp workflow_mark(%{marks: nil} = assigns), do: ~H""

  defp workflow_mark(assigns) do
    assigns = assign(assigns, :listed, assigns.workflow in assigns.marks)

    ~H"""
    <span
      id={@id}
      data-mark={if @listed, do: "listed", else: "missing"}
      title={@icon_only && Words.mark_text(@listed)}
      class={[
        "inline-flex items-center gap-1 text-[13px]/5",
        if(@listed, do: "text-success", else: "text-error"),
        @class
      ]}
    >
      <.icon
        name={if @listed, do: "hero-check-circle-micro", else: "hero-x-circle-micro"}
        class="size-4"
      />
      <span class={@icon_only && "sr-only"}>{Words.mark_text(@listed)}</span>
    </span>
    """
  end

  defp read_lines, do: "grid gap-1 px-4 py-3 text-[13.5px]/5 [overflow-wrap:anywhere]"

  # Each line of a member's Sequence, with the workflow a line runs, nil for a loop's
  # label. A machine type is the default's words of the picker or a type's name
  # (`MachineTypeWords.entry_words/3`).
  defp sequence_lines(stage, machine, types) do
    Enum.flat_map(stage["sequence"], fn
      %{"loop" => %{"rounds" => rounds, "body" => body}} ->
        [
          {ngettext("Loop: at most %{number} round", "Loop: at most %{number} rounds", rounds,
             number: rounds
           ), nil}
          | Enum.map(body, &entry_line(&1, machine, types))
        ]

      entry ->
        [entry_line(entry, machine, types)]
    end)
  end

  defp entry_line(entry, machine, types),
    do:
      {gettext("%{workflow}, machine type %{machine}",
         workflow: entry["workflow"],
         machine: MachineTypeWords.entry_words(types, machine, entry["machine"])
       ), entry["workflow"]}

  defp artifact_line(%{"type" => type, "required" => true}),
    do: gettext("%{type}, required", type: type)

  defp artifact_line(%{"type" => type}), do: gettext("%{type}, optional", type: type)
end
