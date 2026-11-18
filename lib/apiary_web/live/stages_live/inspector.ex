defmodule ApiaryWeb.StagesLive.Inspector do
  # The inspector of the Stages canvas: the selected stage's form, its name and description,
  # then a box each for its inputs, sequence, outputs and gate, or the same read-only (`may`
  # false), with the description above the boxes. A workflow's settings fold under its row,
  # closed until a person opens them; a closed fold's fields still go with the form. The
  # Workflows page and Instance settings › Workspace types show it beside the canvas; each sends
  # its form's events to `ApiaryWeb.StagesLive.Editor`.
  #
  # On the Workflows page (`time_limit` given), each workflow's fold also has its time
  # limit, the workspace's in `Apiary.TimeLimits`, which is not part of the process: the
  # field belongs to a separate form after the stage's form (the `form` attribute), so
  # Save time limit saves it at once and the draft stays as it is. The read-only panel's
  # row line ends with the limit.
  #
  # With `model` given, each workflow's fold has its model choice after the time limit
  # (`ApiaryWeb.StagesLive.ModelPart`), its fields in a separate form per row too: Provider,
  # "Use workspace default" or a provider, the line of what the workflow uses, and with a
  # provider the tiers (`ApiaryWeb.ModelTiers`) and Save model choice.
  @moduledoc false

  use ApiaryWeb, :html

  import ApiaryWeb.PolicyComponents, only: [sect: 1]

  alias Apiary.Stages.Runner
  alias Apiary.TimeLimits
  alias ApiaryWeb.{MachineTypeWords, ModelTiers}
  alias ApiaryWeb.StagesLive.{ModelPart, Words}

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

  attr :stages, :list,
    default: [],
    doc: "the document's stages, for the stages a workflow's return may go to"

  attr :declared, :list, required: true

  attr :declared_access, :map,
    default: %{},
    doc:
      "the access level each workflow the harness lists declares, by name; a workflow with none has no Access line"

  attr :types, :list, required: true
  attr :members, :list, required: true
  attr :people, :map, required: true, doc: "each member's name by user id"
  attr :stage_errors, :map, default: %{}, doc: "refusals of a save, by stage id"

  attr :rounds_errors, :map,
    default: %{},
    doc: "refused rounds and most returns, by the loop's or the workflow's place"

  attr :workflow_errors, :map,
    default: %{},
    doc: "refused workflow names, by the entry's place: \"0\", or \"1-0\" in a loop"

  attr :refused_machines, :list,
    default: [],
    doc: "the machine types the last save refused, each shown as an error on rows with it"

  attr :problems, :list, required: true
  attr :machine, :string, required: true
  attr :machine_types, :list, default: [], doc: "the instance's machine types, for the picker"

  attr :doc, :map,
    default: nil,
    doc: "the process document, for the names of its tracks; nil shows no track or condition"

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

  attr :read_failed, :any,
    default: nil,
    doc: "the line of a read of the harness that failed, shown above the workflows; nil for none"

  attr :time_limit, :map,
    default: nil,
    doc:
      "the workflows' time limits, nil for none: `saved`, the workspace's minutes by workflow; `rows`, each field's state by its row (`time_limit_key/2`); `editable`; and `note`, the sentence shown in place of a way to change them, or nil"

  attr :model, :map,
    default: nil,
    doc:
      "the workflows' model choices, nil for none: what `ApiaryWeb.StagesLive.ModelPart.load/1` reads, with `rows`, each row's state by its row (`time_limit_key/2`); `editable`; and `workflows`, those of the saved process"

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
      <.condition_field stage={@stage} doc={@doc} />
      <.sect id="stage-inputs" title={gettext("Inputs")} heading="h3" class="q-sect-side">
        <ul class={read_lines()}>
          <li :for={item <- @stage["inputs"]}>{artifact_line(item)}</li>
          <li :if={@stage["inputs"] == []}>{gettext("None")}</li>
        </ul>
      </.sect>
      <.sect id="stage-sequence" title={gettext("Sequence")} heading="h3" class="q-sect-side">
        <ul class={read_lines()}>
          <li :for={
            {line, workflow, notes} <-
              sequence_lines(@stage, @machine, @machine_types, @doc, @time_limit)
          }>
            {line}<.workflow_mark :if={workflow} workflow={workflow} marks={@marks} class="ml-2" />
            <span :for={note <- notes} class="block text-muted">{note}</span>
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
        <p
          :if={Words.offers(@stage, @doc)}
          id="stage-gate-tracks"
          class={["border-t border-line text-muted", read_lines()]}
        >
          {Words.offers(@stage, @doc)}
        </p>
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
        <.condition_field stage={@stage} doc={@doc} />

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
            <p :if={@read_failed} id="stage-sequence-read" class="text-[13px]/5 text-error">
              <.rich text={@read_failed} />
            </p>
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
                  <div
                    :if={Words.condition(entry, @doc, @stage["id"])}
                    id={"stage-loop-#{i}-condition"}
                    class="border-b border-line px-3 py-1.5 text-[12.5px]/[18px] text-muted"
                  >
                    {Words.condition(entry, @doc, @stage["id"])}
                  </div>
                  <div class="px-3">
                    <.entry
                      :for={{inner, j} <- Enum.with_index(loop["body"])}
                      notes={Words.entry_notes(inner, @doc, @stage["id"])}
                      entry={inner}
                      name={"stage[sequence][#{i}][body][#{j}]"}
                      id={"stage-entry-#{i}-#{j}"}
                      stage_id={@stage["id"]}
                      declared={@declared}
                      declared_access={@declared_access}
                      machine={@machine}
                      machine_types={@machine_types}
                      marks={@marks}
                      errors={List.wrap(@workflow_errors["#{i}-#{j}"])}
                      refused={@refused_machines}
                      harness={@harness}
                      from_update={@from_update}
                      remove={length(loop["body"]) > 1 && %{"at" => j, "loop" => i}}
                      rule={j > 0}
                      time_limit={
                        time_limit_field(@time_limit, @stage["id"], "stage-entry-#{i}-#{j}", inner)
                      }
                      model={model_field(@model, @stage["id"], "stage-entry-#{i}-#{j}", inner)}
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
                  notes={Words.entry_notes(entry, @doc, @stage["id"])}
                  entry={entry}
                  name={"stage[sequence][#{i}]"}
                  id={"stage-entry-#{i}"}
                  stage_id={@stage["id"]}
                  stages={@stages}
                  return_errors={List.wrap(@rounds_errors[to_string(i)])}
                  declared={@declared}
                  declared_access={@declared_access}
                  machine={@machine}
                  machine_types={@machine_types}
                  marks={@marks}
                  errors={List.wrap(@workflow_errors[to_string(i)])}
                  refused={@refused_machines}
                  harness={@harness}
                  from_update={@from_update}
                  remove={%{"at" => i}}
                  rule={i > 0 and not Map.has_key?(Enum.at(@stage["sequence"], i - 1), "loop")}
                  time_limit={time_limit_field(@time_limit, @stage["id"], "stage-entry-#{i}", entry)}
                  model={model_field(@model, @stage["id"], "stage-entry-#{i}", entry)}
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
            <p
              :if={@stage["gate"]["kind"] == "none"}
              id="stage-gate-none-line"
              class="pl-6 text-[13px]/5 text-muted"
            >
              {gettext(
                "Recorded as approved automatically, with the time. At the round limit, a member decides."
              )}
            </p>
          </fieldset>
          <p
            :if={Words.offers(@stage, @doc)}
            id="stage-gate-tracks"
            class="border-t border-line px-4 py-3 text-[13.5px]/5 text-muted"
          >
            {Words.offers(@stage, @doc)}
          </p>
        </.sect>
      </.form>
      <%!-- The time limits' forms: each field in a workflow's fold belongs to one of these by
      its `form` attribute, as a form may not be in the stage's form. --%>
      <form
        :for={{id, workflow} <- time_limit_rows(@time_limit, @stage)}
        id={"#{id}-time-limit-form"}
        novalidate
        phx-change="time_limit_change"
        phx-submit="time_limit_save"
        class="hidden"
      >
        <input type="hidden" name="time_limit[row]" value={time_limit_key(@stage["id"], id)} />
        <input type="hidden" name="time_limit[workflow]" value={workflow} />
      </form>
      <form
        :for={{id, workflow} <- model_rows(@model, @stage)}
        id={"#{id}-model-form"}
        novalidate
        phx-change="model_change"
        phx-submit="model_save"
        class="hidden"
      >
        <input type="hidden" name="model[row]" value={time_limit_key(@stage["id"], id)} />
        <input type="hidden" name="model[workflow]" value={workflow} />
      </form>
    </section>
    """
  end

  attr :stage, :map, required: true
  attr :doc, :map, default: nil

  # The stage's condition on a track as a read-only field, with the label Condition; nothing
  # for a stage with none.
  defp condition_field(assigns) do
    assigns =
      assign(
        assigns,
        :text,
        Words.condition(assigns.stage, assigns.doc, assigns.stage["id"], :stage)
      )

    ~H"""
    <dl :if={@text} id="stage-condition" class="grid gap-1">
      <dt class="text-[13px]/[18px] font-medium">{gettext("Condition")}</dt>
      <dd class="text-[13.5px]/5">{@text}</dd>
    </dl>
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
  attr :notes, :list, default: [], doc: "lines under the row: the entry's name and its condition"
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :stage_id, :string, required: true
  attr :declared, :list, required: true
  attr :declared_access, :map, required: true
  attr :machine, :string, required: true
  attr :machine_types, :list, required: true
  attr :marks, :list, required: true
  attr :errors, :list, required: true
  attr :refused, :list, required: true
  attr :harness, :atom, required: true
  attr :from_update, :boolean, required: true
  attr :remove, :any, required: true
  attr :rule, :boolean, required: true, doc: "whether a line separates the row from the one above"
  attr :time_limit, :map, default: nil, doc: "the row's time limit (`time_limit_field/4`), or nil"
  attr :model, :map, default: nil, doc: "the row's model choice (`model_field/4`), or nil"

  attr :stages, :list,
    default: [],
    doc: "the document's stages; only a workflow outside a loop has them, for its return"

  attr :return_errors, :list, default: [], doc: "what is wrong with its most returns"

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
            type="select"
            value={@entry["workflow"] || ""}
            aria-label={gettext("Workflow")}
            errors={@errors}
            options={workflow_options(@declared, @entry["workflow"])}
            class="w-full font-mono"
          />
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
      <p :for={note <- @notes} class="text-[12.5px]/[18px] text-muted">{note}</p>
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
              <span class={@time_limit && "block"}>
                {gettext("Machine type: %{machine}",
                  machine: MachineTypeWords.entry_words(@machine_types, @machine, @entry["machine"])
                )}
              </span>
              <span :if={@time_limit} id={"#{@id}-time-limit-line"} class="block">
                {time_limit_summary(@time_limit.saved)}
              </span>
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
          <.time_limit :if={@time_limit} id={"#{@id}-time-limit"} field={@time_limit} />
          <.model_part :if={@model} id={"#{@id}-model"} field={@model} />
        </div>
      </details>
      <p
        :if={access = access_line(@entry, @marks, @declared_access)}
        id={"#{@id}-access"}
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-muted max-md:min-h-10 pointer-coarse:min-h-10"
      >
        <span class="size-3.5 shrink-0" aria-hidden="true"></span>
        <span class="min-w-0 flex-1 [overflow-wrap:anywhere]">{access}</span>
      </p>
      <.return_fold
        :if={return_fold?(@entry, @stage_id, @stages)}
        id={@id}
        name={@name}
        stage_id={@stage_id}
        key={@entry["return"]}
        stages={@stages}
        errors={@return_errors}
      />
    </div>
    """
  end

  # The line under a workflow's machine type: the access level of the runs of the entry.
  # The harness sets the level (`Apiary.Processes.declared_access/1`); the entry in
  # `process.yaml` may lower it, never raise it (`Apiary.Stages.Runner.limits/4`). nil, so
  # no line, for a workflow the harness does not list.
  defp access_line(entry, marks, declared_access) do
    with true <- listed?(entry, marks),
         {:ok, harness} <- Map.fetch(declared_access, entry["workflow"]) do
      level = entry_level(entry["access"])

      if level != nil and rank(level) < rank(harness) do
        gettext("Access: %{level} (set for this stage; the harness allows %{harness})",
          level: level_words(level),
          harness: level_words(harness)
        )
      else
        gettext("Access: %{level} (set by the harness)", level: level_words(harness))
      end
    else
      _not_listed -> nil
    end
  end

  # The entry's level: nil for none. A value other than `write-no-push` counts as read, as
  # the runner counts it.
  defp entry_level(nil), do: nil
  defp entry_level("write-no-push"), do: :write_no_push
  defp entry_level(_read), do: :read

  # From the lowest level to the highest: read, write-no-push (a writable checkout that
  # has no push credential), write.
  defp rank(:read), do: 0
  defp rank(:write_no_push), do: 1
  defp rank(:write), do: 2

  defp level_words(:read), do: gettext("Read only")
  defp level_words(:write_no_push), do: gettext("Write, no push")
  defp level_words(:write), do: gettext("Write and push")

  attr :id, :string, required: true
  attr :field, :map, required: true, doc: "the row's time limit (`time_limit_field/4`)"

  # A workflow's time limit, in whole minutes, under its machine type: the field with Save
  # time limit beside it, which stays disabled while there is nothing to save or the
  # field has an error, and under them the error, else the hint, then Saved. after a
  # save. Where the person may not change it, the field is disabled with no button, and
  # the edition's sentence replaces the hint (`c:ApiaryWeb.Edition.operator_sentence/2`).
  # A workflow the saved process does not have yet has its field disabled, with no button
  # and a hint to save the stage first.
  defp time_limit(assigns) do
    field = assigns.field

    assigns =
      assign(assigns,
        error: field.editable and field.shown_error,
        hint: is_nil(field.note) and not (field.editable and field.shown_error),
        save_off: not field.editable or field.invalid or not field.changed
      )

    ~H"""
    <fieldset class="fieldset">
      <label for={@id} class="text-[13px]/[18px] font-medium">
        {gettext("Time limit, in minutes")}
      </label>
      <div class="flex flex-wrap items-center gap-2">
        <%!-- A text field with the numeric keyboard, not a number field: a browser sends
        a number field's text that is no number, such as 24x, as an empty value, which
        would read as no limit. --%>
        <input
          type="text"
          id={@id}
          name="time_limit[minutes]"
          form={@field.form}
          inputmode="numeric"
          autocomplete="off"
          value={@field.value}
          class={["input input-sm w-28", @error && "input-error"]}
          aria-invalid={@error && "true"}
          aria-describedby={
            cond do
              @error -> "#{@id}-error"
              @field.note -> "#{@id}-note"
              true -> "#{@id}-hint"
            end
          }
          disabled={not @field.editable}
          phx-debounce="300"
          phx-blur="time_limit_blur"
          phx-value-row={@field.key}
          phx-value-workflow={@field.workflow}
        />
        <.button
          :if={@field.editable}
          id={"#{@id}-save"}
          type="submit"
          form={@field.form}
          size="xs"
          disabled={@save_off}
        >
          {gettext("Save time limit")}
        </.button>
      </div>
      <p
        :if={@error}
        id={"#{@id}-error"}
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        {gettext("Enter 15 to 1440 minutes, or leave the field empty.")}
      </p>
      <p :if={@hint and @field.draft_only} id={"#{@id}-hint"} class="text-[12.5px]/[18px] text-muted">
        {gettext("Save the stage first to set this workflow's time limit.")}
      </p>
      <p
        :if={@hint and not @field.draft_only}
        id={"#{@id}-hint"}
        class="text-[12.5px]/[18px] text-muted"
      >
        {gettext(
          "15 to 1440 minutes. If you leave it empty, each session of this workflow stops after %{minutes} minutes.",
          minutes: TimeLimits.default_minutes()
        )}
      </p>
      <p :if={@field.note} id={"#{@id}-note"} class="text-[12.5px]/[18px] text-muted">
        {@field.note}
      </p>
      <p
        :if={@field.done}
        id={"#{@id}-saved"}
        role="status"
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-success"
      >
        <.icon name="hero-check-circle-micro" class="size-4 flex-none" />
        {gettext("Saved.")}
      </p>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :field, :map, required: true, doc: "the row's model choice (`model_field/4`)"

  # A workflow's model choice, under its time limit: Provider, "Use workspace default" or
  # a model provider, with a line under it of what the workflow uses. A provider that
  # serves no runtime has the line of `ApiaryWeb.StagesLive.ModelPart.no_runtime/2` under
  # it, and Save model choice stays disabled. With a provider, its tiers follow
  # (`ApiaryWeb.ModelTiers`), then Runtime, the runtimes the provider serves
  # (`ApiaryWeb.ModelTiers.runtime_part/1`), then Save model choice,
  # which stays disabled while there is nothing to save or a tier has no model. With the
  # default, Runtime is not shown: the default's runtime applies. With the default and
  # no override saved, there is no button. A refusal shows under its field, and Saved.
  # under the button after a save. Where the person may not change it, the fields are
  # disabled with no button. A workflow the saved process does not have yet has Provider
  # disabled, with no button and a line to save the stage first.
  defp model_part(assigns) do
    field = assigns.field

    assigns =
      assign(assigns,
        error: field.provider_errors != [],
        error_ids:
          for(
            {_message, i} <- Enum.with_index(field.provider_errors),
            do: error_id(assigns.id, i)
          )
      )

    ~H"""
    <fieldset class="fieldset">
      <label for={"#{@id}-provider"} class="text-[13px]/[18px] font-medium">
        {gettext("Provider")}
      </label>
      <select
        id={"#{@id}-provider"}
        name="model[provider]"
        form={@field.form}
        class={["select select-sm w-full", @error && "select-error"]}
        aria-invalid={@error && "true"}
        aria-describedby={Enum.join(@error_ids ++ ["#{@id}-line"], " ")}
        disabled={not @field.editable}
      >
        {Phoenix.HTML.Form.options_for_select(@field.options, @field.value)}
      </select>
      <p
        :for={{message, i} <- Enum.with_index(@field.provider_errors)}
        id={error_id(@id, i)}
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        {message}
      </p>
      <p id={"#{@id}-line"} class="text-[12.5px]/[18px] text-muted">{model_line(@field)}</p>
    </fieldset>
    <ModelTiers.tiers
      :if={@field.entry}
      id={"#{@id}-tiers"}
      name="model[tiers]"
      field_id={"#{@id}-tiers"}
      form={@field.form}
      entry={@field.entry}
      tiers={@field.tiers}
      stored={@field.stored}
      errors={@field.tier_errors}
      disabled={not @field.editable}
      stacked
    />
    <ModelTiers.runtime_part
      :if={@field.entry && @field.runtime}
      id={"#{@id}-runtime-part"}
      select_id={"#{@id}-runtime"}
      name="model[runtime]"
      form={@field.form}
      runtimes={@field.runtimes}
      runtime={@field.runtime}
      provider={@field.provider_title}
      errors={@field.runtime_errors}
      disabled={not @field.editable}
    />
    <div :if={@field.button or @field.done} class="grid justify-items-start gap-1.5">
      <.button
        :if={@field.button}
        id={"#{@id}-save"}
        type="submit"
        form={@field.form}
        size="xs"
        disabled={@field.save_off}
      >
        {gettext("Save model choice")}
      </.button>
      <p
        :if={@field.done}
        id={"#{@id}-saved"}
        role="status"
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-success"
      >
        <.icon name="hero-check-circle-micro" class="size-4 flex-none" />
        {gettext("Saved.")}
      </p>
    </div>
    """
  end

  # The line under Provider: what the workflow uses.
  defp model_line(%{draft_only: true}),
    do: gettext("Save the stage first to set this workflow's model choice.")

  defp model_line(%{entry: %{}}),
    do: gettext("This workflow uses this provider and these models in place of the workspace's.")

  defp model_line(%{default: {:workspace, provider}}),
    do: gettext("Uses the workspace default: %{provider}.", provider: provider)

  defp model_line(%{default: {:organisation, organisation, provider}}),
    do:
      gettext("Uses the default of %{organisation}: %{provider}.",
        organisation: organisation,
        provider: provider
      )

  defp model_line(%{default: :none}),
    do: gettext("No default is set. Set one in Workspace settings › Model.")

  # The ids of a field's refusals, as `ApiaryWeb.CoreComponents.input/1` gives them.
  defp error_id(id, 0), do: "#{id}-provider-error"
  defp error_id(id, i), do: "#{id}-provider-error-#{i + 1}"

  # The rows of the stage with a workflow whose model choices have a form; none without
  # model choices.
  defp model_rows(nil, _stage), do: []
  defp model_rows(_model, stage), do: stage_rows(stage)

  # The model choice of the row `id` of `entry`, nil without model choices or a workflow:
  # what `model_part/1` shows. The row's state is its own while it is of the same
  # workflow, else the saved choice (`ApiaryWeb.StagesLive.ModelPart.state/4`).
  defp model_field(nil, _stage_id, _id, _entry), do: nil

  defp model_field(model, stage_id, id, entry) do
    if named?(entry) do
      workflow = entry["workflow"]
      draft_only = not MapSet.member?(model.workflows, workflow)
      state = ModelPart.state(model, model.rows, time_limit_key(stage_id, id), workflow)
      entries = ModelPart.entries(model, workflow, state.runtime)
      entry = ModelTiers.find(entries, state.value)
      {runtimes, runtime} = ModelPart.runtimes(model, entry, state.runtime)
      stored = model.overrides[workflow]
      editable = model.editable and not draft_only
      no_runtime = ModelPart.no_runtime(model, entry)

      # A refusal of the runtime shows under Runtime where it is shown, else under
      # Provider.
      runtime_fields = if entry && runtime, do: [:runtime], else: []

      {runtime_errors, errors} =
        Enum.split_with(state.errors, fn {field, _error} -> field in runtime_fields end)

      {provider_errors, tier_errors} =
        Enum.split_with(errors, fn {field, _error} -> field in [:provider, :runtime] end)

      %{
        form: "#{id}-model-form",
        options: [
          {gettext("Use workspace default"), ""} | for(e <- entries, do: {e.label, e.value})
        ],
        value: state.value,
        entry: entry,
        runtimes: runtimes,
        runtime: runtime,
        tiers: state.tiers,
        stored:
          if(runtime,
            do: ModelTiers.accepted(ModelTiers.stored(stored), runtime),
            else: ModelTiers.stored(stored)
          ),
        provider_errors:
          if(no_runtime, do: [no_runtime], else: []) ++
            for({_field, error} <- provider_errors, do: translate_error(error)),
        runtime_errors: for({_field, error} <- runtime_errors, do: translate_error(error)),
        provider_title: entry && ModelPart.provider_title(model, entry),
        tier_errors: tier_errors,
        done: state.done,
        editable: editable,
        draft_only: draft_only,
        default: model.default,
        button: editable and (entry != nil or stored != nil or state.done),
        save_off:
          not (ModelPart.changed?(model, state) or state.refused) or no_runtime != nil or
            (entry != nil and not ModelTiers.complete?(entry, state.tiers))
      }
    end
  end

  @doc false
  # time_limit_key/2 is the key of a row's time-limit field: the stage's id and the row's
  # id, so a field's state stays with its stage.
  @spec time_limit_key(String.t(), String.t()) :: String.t()
  def time_limit_key(stage_id, id), do: "#{stage_id}/#{id}"

  @doc false
  # minutes/1 is what a time-limit field's value comes to: `{:ok, minutes}` for a whole
  # number from 15 to 1440, `:empty` for none, else `:error`.
  @spec minutes(term) :: {:ok, pos_integer} | :empty | :error
  def minutes(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {minutes, ""} -> if minutes in TimeLimits.minutes_range(), do: {:ok, minutes}, else: :error
      _not_whole when value == "" -> :empty
      _not_whole -> :error
    end
  end

  def minutes(_value), do: :error

  @doc false
  # time_limit_keys/1 is each row of `stage` that has a time-limit field, as its key
  # (`time_limit_key/2`) with its workflow: the rows a time-limit event may be of.
  @spec time_limit_keys(map) :: [{String.t(), String.t()}]
  def time_limit_keys(stage),
    do: for({id, workflow} <- stage_rows(stage), do: {time_limit_key(stage["id"], id), workflow})

  # The rows of the stage with a workflow, each with its id and workflow, whose time
  # limits have a form; none without time limits.
  defp time_limit_rows(nil, _stage), do: []
  defp time_limit_rows(_time_limit, stage), do: stage_rows(stage)

  defp stage_rows(stage) do
    (stage["sequence"] || [])
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"loop" => %{"body" => body}}, i} ->
        for {inner, j} <- Enum.with_index(body), do: {"stage-entry-#{i}-#{j}", inner}

      {entry, i} ->
        [{"stage-entry-#{i}", entry}]
    end)
    |> Enum.flat_map(fn {id, entry} ->
      if named?(entry), do: [{id, entry["workflow"]}], else: []
    end)
  end

  # The time limit of the row `id` of `entry`, nil without time limits or a workflow:
  # what `time_limit/1` shows. The field's state is the row's while it is of the same
  # workflow, else the saved minutes.
  defp time_limit_field(nil, _stage_id, _id, _entry), do: nil

  defp time_limit_field(time_limit, stage_id, id, entry) do
    if named?(entry) do
      workflow = entry["workflow"]
      # A workflow of the draft alone, which the saved process does not have yet.
      draft_only = not MapSet.member?(time_limit.workflows, workflow)
      key = time_limit_key(stage_id, id)
      saved = Map.get(time_limit.saved, workflow)
      saved_value = if saved, do: Integer.to_string(saved), else: ""

      state =
        case Map.get(time_limit.rows, key) do
          %{workflow: ^workflow} = state -> state
          _other -> %{value: saved_value, touched: false, done: false}
        end

      minutes = minutes(state.value)

      %{
        key: key,
        form: "#{id}-time-limit-form",
        workflow: workflow,
        saved: saved,
        value: state.value,
        invalid: minutes == :error,
        shown_error: minutes == :error and state.touched,
        changed: limit_changed?(minutes, saved),
        done: state.done,
        editable: time_limit.editable and not draft_only,
        draft_only: draft_only,
        note: time_limit.note
      }
    end
  end

  defp named?(entry), do: entry["workflow"] not in [nil, ""]

  # Whether a save would change the limit: another number, or an empty field where a limit
  # is saved.
  defp limit_changed?({:ok, minutes}, saved), do: minutes != saved
  defp limit_changed?(:empty, saved), do: not is_nil(saved)
  defp limit_changed?(:error, _saved), do: false

  # The fold's line of a workflow's time limit: the saved minutes, else the default.
  defp time_limit_summary(nil),
    do: gettext("Time limit: %{minutes} minutes (default)", minutes: TimeLimits.default_minutes())

  defp time_limit_summary(minutes),
    do: gettext("Time limit: %{minutes} minutes", minutes: minutes)

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :stage_id, :string, required: true
  attr :key, :map, default: nil, doc: "the entry's return key; nil for an entry with none"
  attr :stages, :list, required: true
  attr :errors, :list, default: [], doc: "what is wrong with its most returns"

  # The fold of a workflow entry's return key (choice 10), under its machine type: the
  # stage to return to on changes requested, "Do not return" or one of the stages before
  # the entry's, and, with a stage picked, the most returns and the line on what happens
  # after them. An entry with no key has the fold with "Do not return" picked, and only
  # the select. Picking a stage sets the key (`Draft`), "Do not return" removes it. A key
  # to a stage that is not earlier, or to a removed stage, keeps its stage in the field,
  # where it and the fold's line show what to pick, and a save shows the same error.
  defp return_fold(assigns) do
    earlier = earlier_stages(assigns.stages, assigns.stage_id)
    to = assigns.key && assigns.key["stage"]
    limit = assigns.key && Runner.returns_limit(assigns.key)

    refused =
      if to && not Enum.any?(earlier, &(&1["id"] == to)),
        do: Words.return_refused(stage_name(assigns.stages, assigns.stage_id))

    options =
      [{gettext("Do not return"), ""} | Enum.map(earlier, &{&1["name"], &1["id"]})] ++
        if(refused, do: [{refused, to}], else: [])

    assigns =
      assign(assigns,
        options: options,
        limit: limit,
        to: to || "",
        summary:
          cond do
            is_nil(assigns.key) ->
              gettext("On changes requested: do not return")

            refused ->
              refused

            true ->
              ngettext(
                "On changes requested: return to %{stage}, at most %{count} return",
                "On changes requested: return to %{stage}, at most %{count} returns",
                limit,
                stage: stage_name(assigns.stages, to)
              )
          end,
        line: limit && Words.return_line(limit)
      )

    ~H"""
    <details
      id={"#{@id}-return-#{@stage_id}"}
      class="q-tool group"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="nokey">
        <span class="flex items-center gap-1.5 text-[12.5px]/[18px] text-muted max-md:min-h-10 pointer-coarse:min-h-10">
          <.icon name="hero-chevron-right-micro" class="q-chev size-3.5" />
          <span class="min-w-0 flex-1 [overflow-wrap:anywhere]">{@summary}</span>
          <span class="shrink-0 font-medium text-accent underline underline-offset-[3px] group-open:hidden">
            {gettext("Change")}
          </span>
          <span class="hidden shrink-0 font-medium text-accent underline underline-offset-[3px] group-open:inline">
            {gettext("Close")}
          </span>
        </span>
      </summary>
      <div class="grid gap-3 pt-2 pb-2 pl-5">
        <.input
          id={"#{@id}-return"}
          name={"#{@name}[return]"}
          type="select"
          value={@to}
          label={gettext("On changes requested, return to")}
          options={@options}
          class="w-64"
        />
        <div :if={@key} class="q-stage-rounds">
          <.input
            id={"#{@id}-returns"}
            name={"#{@name}[returns]"}
            type="number"
            min="1"
            max="10"
            value={@limit}
            errors={@errors}
            label={gettext("Returns at most")}
            class="w-14"
          />
        </div>
        <p :if={@key} class="text-[13px]/5 text-muted">{@line}</p>
      </div>
    </details>
    """
  end

  # Whether a workflow entry has the return fold: it has a key, or it is outside a loop
  # (`stages` is empty in a loop) in a stage that has an earlier stage.
  defp return_fold?(entry, stage_id, stages),
    do: stages != [] and (is_map(entry["return"]) or earlier_stages(stages, stage_id) != [])

  defp earlier_stages(stages, stage_id), do: Enum.take_while(stages, &(&1["id"] != stage_id))

  # The name of the stage `id` in `stages`; the id itself for a stage that is not there.
  defp stage_name(stages, id) do
    case Enum.find(stages, &(&1["id"] == id)) do
      %{"name" => name} -> name
      nil -> to_string(id)
    end
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

  # The options of a workflow's field: the listed workflows in alphabetical order, then the
  # entry's workflow when the list does not have it, so the field shows the entry's name.
  # An entry with no workflow gets an empty option first, selected, so the field shows no
  # name; a change of another field sends "", which keeps the entry without one
  # (`ApiaryWeb.StagesLive.Editor`).
  defp workflow_options(declared, workflow) do
    listed = declared |> Enum.uniq() |> Enum.sort()

    cond do
      workflow in [nil, ""] -> [{"", ""} | listed]
      workflow in listed -> listed
      true -> listed ++ [workflow]
    end
  end

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
  # label, and the notes under it: an entry's name and condition, a loop's condition. A
  # machine type is the default's words of the picker or a type's name
  # (`MachineTypeWords.entry_words/3`). A workflow with a return to an earlier stage
  # (choice 10) says to which stage and how many times at most. With time limits, a
  # workflow's line ends with its limit, the saved minutes or the default.
  defp sequence_lines(stage, machine, types, doc, time_limit) do
    Enum.flat_map(stage["sequence"], fn
      %{"loop" => %{"rounds" => rounds, "body" => body}} = loop ->
        [
          {ngettext("Loop: at most %{number} round", "Loop: at most %{number} rounds", rounds,
             number: rounds
           ), nil, List.wrap(Words.condition(loop, doc, stage["id"]))}
          | Enum.map(body, &entry_line(&1, machine, types, doc, stage["id"], time_limit))
        ]

      entry ->
        [entry_line(entry, machine, types, doc, stage["id"], time_limit)]
    end)
  end

  defp entry_line(entry, machine, types, doc, stage_id, time_limit) do
    workflow = entry["workflow"]
    machine = MachineTypeWords.entry_words(types, machine, entry["machine"])
    stage = Enum.find(doc["stages"] || [], &(&1["id"] == stage_id))

    line =
      gettext("%{workflow}, machine type %{machine}", workflow: workflow, machine: machine) <>
        return_clause(Words.earlier_return(entry, stage, doc)) <>
        limit_clause(time_limit, workflow)

    {line, workflow, Words.entry_notes(entry, doc, stage_id)}
  end

  # The clause of a workflow with a return to an earlier stage: the stage and the most
  # returns. Empty for a workflow with none.
  defp return_clause(nil), do: ""

  defp return_clause({to, limit}) do
    ngettext(
      ", returns to %{stage} at most %{count} time",
      ", returns to %{stage} at most %{count} times",
      limit,
      stage: to
    )
  end

  # The clause of a workflow's time limit: the saved minutes, or the default. Empty with no
  # time limits.
  defp limit_clause(nil, _workflow), do: ""

  defp limit_clause(time_limit, workflow) do
    case Map.get(time_limit.saved, workflow) do
      nil ->
        gettext(", time limit %{minutes} minutes (default)",
          minutes: TimeLimits.default_minutes()
        )

      minutes ->
        gettext(", time limit %{minutes} minutes", minutes: minutes)
    end
  end

  defp artifact_line(%{"type" => type, "required" => true}),
    do: gettext("%{type}, required", type: type)

  defp artifact_line(%{"type" => type}), do: gettext("%{type}, optional", type: type)
end
