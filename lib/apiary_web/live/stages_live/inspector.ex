defmodule ApiaryWeb.StagesLive.Inspector do
  # The inspector of the Stages canvas: the selected stage's form, its name, sequence,
  # inputs, outputs and gate, or its details read-only (`may` false). The Stages page and
  # Instance settings › Workspace types show it under the canvas; each sends its form's
  # events to `ApiaryWeb.StagesLive.Editor`.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.StagesLive.Words

  # A stage's alert lines: each workflow it runs that the harness does not declare.
  @doc false
  def stage_alerts(problems, stage) do
    for {:missing_workflow, id, name} <- problems,
        id == stage["id"],
        do: Words.undeclared(stage["name"], name)
  end

  # Under "Default machine type" only (Vito's text, 2026-10-31).
  @doc false
  def machine_hint,
    do:
      gettext(
        "Qory Apiary stores the machine type with each run of the workflow. It does not choose the machine that runs it."
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
  attr :problems, :list, required: true
  attr :machine, :string, required: true

  attr :named, :boolean,
    default: true,
    doc: "whether a gate may name its approvers; false offers any member alone"

  def stage_panel(%{may: false} = assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-3 rounded-box border border-base-300 p-4"
    >
      <h2 id="stage-panel-title" class="text-[15px]/6 font-semibold">{@stage["name"]}</h2>
      <.alerts stage={@stage} problems={@problems} />
      <dl class="grid gap-2 text-[13.5px]/5">
        <dt class="font-medium">{gettext("Sequence")}</dt>
        <dd :for={line <- sequence_lines(@stage, @machine)}>{line}</dd>
        <dd :if={@stage["sequence"] == []}>{gettext("No workflow")}</dd>
        <dt class="font-medium">{gettext("Inputs")}</dt>
        <dd :for={item <- @stage["inputs"]}>{artifact_line(item)}</dd>
        <dd :if={@stage["inputs"] == []}>{gettext("None")}</dd>
        <dt class="font-medium">{gettext("Outputs")}</dt>
        <dd :for={item <- @stage["outputs"]}>{artifact_line(item)}</dd>
        <dd :if={@stage["outputs"] == []}>{gettext("None")}</dd>
        <dt class="font-medium">{gettext("Gate")}</dt>
        <dd>{Words.gate_value(@stage, @people)}</dd>
      </dl>
    </section>
    """
  end

  def stage_panel(assigns) do
    ~H"""
    <section
      id="stage-panel"
      aria-labelledby="stage-panel-title"
      class="grid gap-4 rounded-box border border-base-300 p-4"
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
      <.alerts stage={@stage} problems={@problems} />
      <.form
        for={%{}}
        as={:stage}
        id="stage-form"
        phx-change="edit_stage"
        novalidate
        class="grid gap-5"
      >
        <.input
          id="stage-name"
          name="stage[name]"
          value={@stage["name"]}
          errors={Map.get(@stage_errors, @stage["id"], [])}
          label={gettext("Name")}
          maxlength="60"
          autocomplete="off"
        />

        <fieldset id="stage-sequence" class="grid gap-2">
          <legend class="mb-1 text-[13.5px]/5 font-medium">{gettext("Sequence")}</legend>
          <p :if={@stage["sequence"] == []} class="text-[13px]/5 text-muted">
            {gettext("No workflow")}
          </p>
          <%= for {entry, i} <- Enum.with_index(@stage["sequence"]) do %>
            <%= if loop = entry["loop"] do %>
              <div
                id={"stage-loop-#{i}"}
                class="grid gap-2 rounded-box border border-dashed border-base-300 p-3"
              >
                <div class="flex flex-wrap items-end gap-3">
                  <.input
                    id={"stage-loop-#{i}-rounds"}
                    name={"stage[sequence][#{i}][rounds]"}
                    type="number"
                    min="1"
                    max="10"
                    value={loop["rounds"]}
                    errors={List.wrap(@rounds_errors[to_string(i)])}
                    label={gettext("Loop: rounds at most")}
                    class="w-20"
                  />
                  <.button
                    type="button"
                    size="xs"
                    variant="danger-ghost"
                    phx-click="remove_loop"
                    phx-value-at={i}
                  >
                    {gettext("Remove loop")}
                  </.button>
                </div>
                <.entry
                  :for={{inner, j} <- Enum.with_index(loop["body"])}
                  entry={inner}
                  name={"stage[sequence][#{i}][body][#{j}]"}
                  id={"stage-entry-#{i}-#{j}"}
                  declared={@declared}
                  machine={@machine}
                  remove={length(loop["body"]) > 1 && %{"at" => j, "loop" => i}}
                />
                <div>
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
                declared={@declared}
                machine={@machine}
                remove={%{"at" => i}}
              />
            <% end %>
          <% end %>
          <div class="flex flex-wrap gap-2">
            <.button id="stage-add-entry" type="button" size="xs" phx-click="add_entry">
              {gettext("Add workflow")}
            </.button>
            <.button id="stage-add-loop" type="button" size="xs" phx-click="add_loop">
              {gettext("Add loop")}
            </.button>
          </div>
        </fieldset>

        <.artifacts key="inputs" stage={@stage} types={@types} />
        <.artifacts key="outputs" stage={@stage} types={@types} />

        <fieldset id="stage-gate" class="grid gap-2">
          <legend class="mb-1 text-[13.5px]/5 font-medium">{gettext("Gate")}</legend>
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
      </.form>
    </section>
    """
  end

  attr :stage, :map, required: true
  attr :problems, :list, required: true

  defp alerts(assigns) do
    ~H"""
    <.notice :for={line <- stage_alerts(@problems, @stage)} kind={:warning}>
      <span data-stage-alert>{line}</span>
    </.notice>
    """
  end

  attr :entry, :map, required: true
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :declared, :list, required: true
  attr :machine, :string, required: true
  attr :remove, :any, required: true

  defp entry(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-end gap-3">
      <.input
        id={"#{@id}-workflow"}
        name={"#{@name}[workflow]"}
        type="select"
        value={@entry["workflow"]}
        label={gettext("Workflow")}
        options={workflow_options(@declared, @entry["workflow"])}
      />
      <.input
        id={"#{@id}-machine"}
        name={"#{@name}[machine]"}
        value={@entry["machine"]}
        label={gettext("Machine type")}
        placeholder={@machine}
        autocomplete="off"
        spellcheck="false"
        class="w-36"
      />
      <.button
        :if={@remove}
        type="button"
        size="xs"
        variant="danger-ghost"
        phx-click="remove_entry"
        phx-value-at={@remove["at"]}
        phx-value-loop={@remove["loop"]}
        aria-label={gettext("Remove %{workflow}", workflow: @entry["workflow"])}
      >
        {gettext("Remove")}
      </.button>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :stage, :map, required: true
  attr :types, :list, required: true

  defp artifacts(assigns) do
    ~H"""
    <fieldset id={"stage-#{@key}"} class="grid gap-2">
      <legend class="mb-1 text-[13.5px]/5 font-medium">
        {if @key == "inputs", do: gettext("Inputs"), else: gettext("Outputs")}
      </legend>
      <p :if={@stage[@key] == []} class="text-[13px]/5 text-muted">{gettext("None")}</p>
      <div
        :for={{item, i} <- Enum.with_index(@stage[@key])}
        id={"stage-#{@key}-#{i}"}
        class="flex flex-wrap items-end gap-3"
      >
        <.input
          id={"stage-#{@key}-#{i}-type"}
          name={"stage[#{@key}][#{i}][type]"}
          type="select"
          value={item["type"]}
          label={gettext("Type")}
          options={Enum.uniq(Enum.map(@types, & &1.name) ++ [item["type"]])}
        />
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
          phx-click="remove_artifact"
          phx-value-key={@key}
          phx-value-at={i}
          aria-label={gettext("Remove %{type}", type: item["type"])}
        >
          {gettext("Remove")}
        </.button>
      </div>
      <div>
        <.button
          id={"stage-add-#{@key}"}
          type="button"
          size="xs"
          phx-click="add_artifact"
          phx-value-key={@key}
        >
          {if @key == "inputs", do: gettext("Add input"), else: gettext("Add output")}
        </.button>
      </div>
    </fieldset>
    """
  end

  # The workflows the harness declares (`Apiary.Processes.declared_workflows/1`). A
  # workflow it no longer declares stays shown as the entry's value, and cannot be chosen.
  defp workflow_options(declared, workflow) do
    if workflow in declared,
      do: declared,
      else: declared ++ [[key: workflow, value: workflow, disabled: true]]
  end

  defp sequence_lines(stage, machine) do
    Enum.flat_map(stage["sequence"], fn
      %{"loop" => %{"rounds" => rounds, "body" => body}} ->
        [
          ngettext("Loop: at most %{number} round", "Loop: at most %{number} rounds", rounds,
            number: rounds
          )
          | Enum.map(body, &entry_line(&1, machine))
        ]

      entry ->
        [entry_line(entry, machine)]
    end)
  end

  defp entry_line(entry, machine),
    do:
      gettext("%{workflow}, machine type %{machine}",
        workflow: entry["workflow"],
        machine: entry["machine"] || machine
      )

  defp artifact_line(%{"type" => type, "required" => true}),
    do: gettext("%{type}, required", type: type)

  defp artifact_line(%{"type" => type}), do: gettext("%{type}, optional", type: type)
end
