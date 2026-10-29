defmodule ApiaryWeb.HarnessComponents do
  # The harness choice of a workspace (`Apiary.Stacks.Sources.choose/3`), as the set-up's
  # Harness step (`ApiaryWeb.WorkspaceSetupLive`) and Workspace settings › Workflow
  # (`ApiaryWeb.WorkflowLive`) show it, and the stacks chosen for the workspace's
  # destinations (`Apiary.Stacks.Sources.choose_target/3`), as the Harness step shows them.
  #
  # `choices/1` is the two choices, the fields of a form named `harness`: `choice`, `qory`
  # or `repository`; and, for a harness repository, `source`, a linked repository of
  # `Apiary.Stacks.Sources.linked/1`, and `ref`, its branch or tag. The Qory harness shows
  # its address and the first 7 characters of its pin, and, with `file_first`, the line
  # that a target's harness file comes first. A harness repository lists the linked
  # repositories under Source, a choice with a search box, with Reading… until they are
  # read; with `complete` and none listed, a line in place of Source says that none has a
  # stack. Under Branch or tag, the hint is the organisation's connection a linked
  # repository is read through. `line/1` is the choice with its pin, as Workflow shows it.
  # With `shared`, as the Harness step passes it, `choices/1` lists the harness the
  # organisation shares first, as the `choice` `shared`. `form_params/2` is the form's
  # values for a saved choice, `choice/2` the choice the form's values come to, and
  # `refusal_words/4` why a save was refused.
  # `qory/2` is the Qory harness the choices show.
  #
  # `targets/1` is the destinations, each with Workspace default or the stack chosen for
  # it, and Change for a person who may save. Change opens the form `target_stack` of one
  # destination, with the fields `choice`, which is `default`, `qory` or `repository`;
  # and, for a harness source, `source`, among the three groups of Workflow's Source
  # (`source_options/3`), `address`, `stack`, an index among the stacks read, and `ref`,
  # its branch or tag, which an assigned source has fixed. `target_choice/1` is the choice
  # the form comes to.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Adapters
  alias Apiary.Lingo.Domain
  alias Apiary.Stacks.Document

  @short 7

  attr :form, Phoenix.HTML.Form, required: true
  attr :chosen, :map, required: true, doc: "the saved choice, `t:Apiary.Stacks.Sources.chosen/0`"
  attr :qory, :map, required: true, doc: "the Qory harness's base: `git` and `ref`"
  attr :linked, :list, default: nil, doc: "the linked repositories, nil while they are read"

  attr :complete, :boolean,
    default: false,
    doc: "whether the listing read every linked repository, so an empty one has no stack"

  attr :organisation, :string, required: true
  attr :disabled, :boolean, default: false

  attr :file_first, :boolean,
    default: false,
    doc: "whether the Qory harness shows that a target's harness file comes first"

  attr :shared, :map,
    default: nil,
    doc: "the harness the organisation shares, listed first as the choice `shared`; nil for none"

  # The two choices, and the fields of a harness repository once it is chosen. With
  # `shared`, the harness the organisation shares comes first, under "Shared in
  # <organisation>", marked "every workspace", with its address and pin.
  def choices(assigns) do
    choice = assigns.form[:choice].value
    source = source(assigns.linked, assigns.form[:source].value)

    assigns =
      assign(assigns,
        choice: choice,
        source: source,
        none: assigns.complete and assigns.linked == [],
        shared_title: assigns.shared && choice_title(assigns.shared.choice),
        shared_line:
          assigns.shared && "#{address(assigns.shared.git)} · #{short(assigns.shared.pin)}",
        options: [
          {"qory", choice_title(:qory),
           "#{address(assigns.qory["git"])} · #{short(assigns.qory["ref"])}"},
          {"repository", choice_title(:repository), nil}
        ]
      )

    ~H"""
    <fieldset id="harness-choice" class="q-choices grid gap-2">
      <div
        :if={@shared}
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
          <span class="q-choice-p font-mono">{@shared_line}</span>
        </label>
      </div>
      <label
        :for={{value, title, line} <- @options}
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
        <span :if={line} class={["q-choice-p", value == "qory" && "font-mono"]}>{line}</span>
        <span
          :if={value == "qory" and @file_first}
          id="harness-choice-qory-file"
          class="q-choice-p"
        >
          {gettext("A target's harness file comes first.")}
        </span>
      </label>
    </fieldset>

    <div :if={@choice == "repository"} id="harness-repository" class="grid gap-4">
      <p :if={@none} id="harness-source-none" class="text-[13px]/[20px] text-muted">
        {none_words()}
      </p>
      <.input
        :if={!@none}
        field={@form[:source]}
        id="harness-source"
        type="choice"
        label={gettext("Source")}
        prompt={if is_nil(@linked), do: gettext("Reading…")}
        options={Enum.map(@linked || [], &source_option/1)}
        search={@linked not in [nil, []] || nil}
        disabled={@disabled or @linked in [nil, []]}
      />
      <.input
        field={@form[:ref]}
        id="harness-ref"
        type="text"
        label={gettext("Harness version")}
        hint={
          @source &&
            gettext("Read through the %{adapter} connection of %{organisation}.",
              organisation: @organisation,
              adapter: Adapters.title(@source.location.adapter)
            )
        }
        disabled={@disabled}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
      />
    </div>
    """
  end

  attr :chosen, :map, required: true, doc: "the choice, `t:Apiary.Stacks.Sources.chosen/0`"

  # The choice and its pin: "Qory harness · pinned at fe3b3ab"; a harness repository's
  # address under it.
  def line(assigns) do
    ~H"""
    <span id="harness-line" class="grid gap-0.5">
      <span>{line_words(@chosen)}</span>
      <span
        :if={@chosen.choice == :repository and is_binary(@chosen.git)}
        id="harness-line-address"
        class="font-mono text-muted"
      >
        {address(@chosen.git)}
      </span>
    </span>
    """
  end

  defp line_words(%{choice: :qory, pin: pin}),
    do:
      gettext("%{harness} · pinned at %{commit}",
        harness: gettext("Qory harness"),
        commit: short(pin)
      )

  defp line_words(%{choice: :repository, pin: pin}),
    do:
      gettext("%{harness} · pinned at %{commit}",
        harness: gettext("A harness source"),
        commit: short(pin)
      )

  attr :targets, :list,
    required: true,
    doc:
      "the destinations: `id`, `title` and `chosen`, `t:Apiary.Stacks.Sources.target_chosen/0` or nil"

  attr :may, :boolean, required: true, doc: "whether the person may save, so sees Change"
  attr :edit, :map, default: nil, doc: "the open form of a destination, nil for none"
  attr :qory, :map, required: true, doc: "the Qory harness's base: `git` and `ref`"
  attr :linked, :list, default: nil, doc: "the linked repositories, nil while they are read"

  attr :complete, :boolean,
    default: false,
    doc: "whether the listing read every linked repository, so an empty one has no stack"

  attr :assigned, :list, default: [], doc: "the sources an instance admin assigned"
  attr :organisation, :string, required: true

  # The destinations, each with its stack, and the form of the one whose Change was
  # pressed. No list shows for a workspace with no destination.
  def targets(assigns) do
    ~H"""
    <section :if={@targets != []} id="harness-targets" class="grid gap-2">
      <h2 class="text-[13.5px]/5 font-medium">{gettext("Targets")}</h2>
      <ul class="grid gap-2">
        <li :for={target <- @targets} id={"harness-target-#{target.id}"} class="grid gap-3">
          <div class="flex flex-wrap items-start gap-x-6 gap-y-1 text-[13.5px]/5">
            <span class="min-w-0 flex-1 truncate font-mono">{target.title}</span>
            <span id={"harness-target-#{target.id}-line"} class="min-w-0 flex-1">
              {target_line(target.chosen)}
            </span>
            <.button
              :if={@may and !(@edit && @edit.id == target.id)}
              id={"harness-target-#{target.id}-change"}
              type="button"
              size="sm"
              phx-click="change_target"
              phx-value-id={target.id}
            >
              {gettext("Change")}
            </.button>
          </div>
          <.target_form
            :if={(@may and @edit) && @edit.id == target.id}
            edit={@edit}
            qory={@qory}
            linked={@linked}
            complete={@complete}
            assigned={@assigned}
            organisation={@organisation}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :edit, :map, required: true
  attr :qory, :map, required: true
  attr :linked, :list, default: nil
  attr :complete, :boolean, default: false
  attr :assigned, :list, default: []
  attr :organisation, :string, required: true

  # The form of one destination: the three choices, and for a harness source, Source,
  # the stacks read, and the branch or tag.
  defp target_form(assigns) do
    edit = assigns.edit

    assigns =
      assign(assigns,
        form:
          to_form(
            %{
              "choice" => edit.choice,
              "source" => edit.source_id,
              "address" => edit.address,
              "stack" => edit.stack,
              "ref" => edit.ref
            },
            as: :target_stack
          ),
        ready: target_choice(edit) != nil,
        options: [
          {"default", gettext("Workspace default"), nil},
          {"qory", gettext("Qory harness"),
           "#{address(assigns.qory["git"])} · #{short(assigns.qory["ref"])}"},
          {"repository", gettext("A harness source"), nil}
        ]
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
      <fieldset id="harness-target-choice" class="q-choices grid gap-2">
        <label
          :for={{value, title, line} <- @options}
          id={"harness-target-choice-#{value}"}
          for={"harness-target-choice-#{value}-radio"}
          class="q-choice"
        >
          <input
            type="radio"
            id={"harness-target-choice-#{value}-radio"}
            name={@form[:choice].name}
            value={value}
            checked={@edit.choice == value}
            disabled={@edit.saving}
            class="radio radio-sm radio-primary"
          />
          <span class="q-choice-h">{title}</span>
          <span :if={line} class="q-choice-p font-mono">{line}</span>
        </label>
      </fieldset>

      <div :if={@edit.choice == "repository"} id="harness-target-repository" class="grid gap-4">
        <.input
          field={@form[:source]}
          type="choice"
          label={gettext("Source")}
          prompt={gettext("Choose a source")}
          options={source_options(@linked, @assigned, @complete)}
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
      </div>

      <.notice :if={@edit.refusal} kind={:error}>
        <span id="harness-target-refusal">{@edit.refusal}</span>
      </.notice>

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

  # The stack chosen for a destination: Workspace default for none, the Qory harness with
  # its pin, or a harness source's repository, the stack it narrows to, and its pin. A
  # stack of an assigned source is saved at the assignment's ref, which is no pin where it
  # is a branch or a tag: the line says so.
  defp target_line(nil), do: gettext("Workspace default")

  defp target_line(%{choice: :qory, pin: pin}),
    do:
      gettext("%{harness} · pinned at %{commit}",
        harness: gettext("Qory harness"),
        commit: short(pin)
      )

  defp target_line(%{choice: :repository, git: git, narrowing: narrowing, pin: pin}) do
    harness = repository(git)
    stack = narrowing["stack"] || narrowing["path"]

    case {stack, commit?(pin)} do
      {nil, true} ->
        gettext("%{harness} · pinned at %{commit}", harness: harness, commit: short(pin))

      {nil, false} ->
        gettext("%{harness} · at %{ref}, not pinned", harness: harness, ref: pin)

      {stack, true} ->
        gettext("%{harness} · %{stack} · pinned at %{commit}",
          harness: harness,
          stack: stack,
          commit: short(pin)
        )

      {stack, false} ->
        gettext("%{harness} · %{stack} · at %{ref}, not pinned",
          harness: harness,
          stack: stack,
          ref: pin
        )
    end
  end

  @doc false
  # source_options/3 is the groups of a Source choice, as Workflow and a destination's form
  # show it: the linked repositories, with Reading… until they are read, and the line that
  # none has a stack where `complete` and none is listed, neither of which can be chosen;
  # the assigned sources; and the public address, which a search keeps in view.
  @spec source_options([map] | nil, [map], boolean) :: [{String.t(), [map]}]
  def source_options(linked, assigned, complete) do
    linked =
      case linked do
        nil -> [%{value: "", title: gettext("Reading…"), disabled: true}]
        [] when complete -> [%{value: "", title: none_words(), disabled: true, keep: true}]
        linked -> Enum.map(linked, &source_option/1)
      end

    [
      {pgettext("plain", "Linked repositories"), linked},
      {gettext("Assigned by an instance admin"), Enum.map(assigned, &source_option/1)},
      {gettext("Public address"),
       [%{value: "address", title: gettext("Enter an address"), keep: true}]}
    ]
  end

  # Why no linked repository is listed, where the listing read them all.
  defp none_words,
    do:
      pgettext(
        "plain",
        "No connected repository has a qory-stack.yaml file. Connect a work source, or add the file to a repository."
      )

  defp source_option(source), do: %{value: source.id, title: source.label, mono: :title}

  # Each stack read, by its index: its export name, else the folder it is in, else its
  # file at the root.
  defp stack_options(stacks) do
    for {stack, index} <- Enum.with_index(stacks),
        do: {stack.name || stack.base["path"] || "qory-stack.yaml", Integer.to_string(index)}
  end

  # Why the stacks of `source` were not read, in the words of Workflow's Source.
  defp read_words(:not_covered, source, organisation),
    do:
      pgettext(
        "plain",
        "Link %{source} to %{organisation}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment.",
        source: label(source),
        organisation: organisation
      )

  defp read_words(:no_stack, source, _organisation),
    do:
      gettext(
        "Add a qory-stack.yaml file to %{source}, or choose another source: %{source} has no stack.",
        source: label(source)
      )

  defp read_words({:limited, seconds}, source, _organisation),
    do:
      ngettext(
        "Wait %{count} second, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        "Wait %{count} seconds, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        seconds,
        source: label(source)
      )

  defp read_words(_unreadable, source, _organisation), do: unread_words(source)

  @doc false
  # target_choice/1 is the choice the form of a destination comes to, for
  # `Apiary.Stacks.Sources.choose_target/3`: a harness source's stack of the index
  # chosen, at the branch or tag given, or at an assigned source's `ref`; nil for a
  # harness source with no stack read or no branch or tag.
  @spec target_choice(map) :: Apiary.Stacks.Sources.target_choice() | nil
  def target_choice(%{choice: "default"}), do: :default
  def target_choice(%{choice: "qory"}), do: :qory

  def target_choice(
        %{choice: "repository", source: %{} = source, stacks: [_ | _] = stacks} = edit
      ) do
    ref = if source.kind == :assigned, do: source.ref, else: String.trim(edit.ref || "")

    with {index, ""} when index >= 0 <- Integer.parse(edit.stack || ""),
         %{} = stack <- Enum.at(stacks, index),
         true <- is_binary(ref) and ref != "" do
      {:stack, source, stack, ref}
    else
      _none -> nil
    end
  end

  def target_choice(_edit), do: nil

  @doc false
  # qory/2 is the base of the Qory harness the choices show for `workspace`: the saved
  # choice's, else that of the definition of the workspace's type.
  @spec qory(map, Apiary.Organisations.Workspace.t()) :: map
  def qory(%{choice: :qory, saved: true, git: git, pin: pin}, _workspace),
    do: %{"git" => git, "ref" => pin}

  def qory(_chosen, workspace),
    do: workspace |> Domain.for_workspace() |> Domain.definition() |> Map.fetch!(:harness)

  @doc false
  # form_params/2 is the form's values for the saved choice `chosen`, among the linked
  # repositories `linked`, nil while they are read: a harness repository's linked
  # repository, else the first, and its pin as the ref; else `main`.
  @spec form_params(map, [map] | nil) :: map
  def form_params(chosen, linked) do
    saved = chosen.choice == :repository && Enum.find(linked || [], &(&1.git == chosen.git))
    first = List.first(linked || [])

    %{
      "choice" => Atom.to_string(chosen.choice),
      "source" => ((saved || first) && (saved || first).id) || "",
      "ref" => if(saved, do: chosen.pin, else: "main")
    }
  end

  @doc false
  # fill/3 is the form's `params` with the source and the ref of `form_params/2` where
  # `params` has none, and that source where `params` has an empty one: a harness
  # repository just chosen shows a linked repository.
  @spec fill(map, map, [map] | nil) :: map
  def fill(params, chosen, linked) do
    defaults = chosen |> form_params(linked) |> Map.take(["source", "ref"])
    params = if params["source"] == "", do: Map.delete(params, "source"), else: params
    Map.merge(defaults, params)
  end

  @doc false
  # choice/2 is the choice the form's `params` come to, among `linked`, for
  # `Apiary.Stacks.Sources.choose/3`; nil for a harness repository without a source or a
  # ref, and for any other value.
  @spec choice(map, [map] | nil) :: Apiary.Stacks.Sources.choice() | nil
  def choice(%{"choice" => "qory"}, _linked), do: :qory

  def choice(%{"choice" => "repository"} = params, linked) do
    ref = String.trim(params["ref"] || "")

    case source(linked, params["source"]) do
      %{} = source when ref != "" -> {:repository, source, ref}
      _none -> nil
    end
  end

  def choice(_params, _linked), do: nil

  @doc false
  # unchanged?/2 is whether `choice` is the saved choice `chosen`: the same choice, and
  # for a harness repository the same address at its pin.
  @spec unchanged?(Apiary.Stacks.Sources.choice() | nil, map) :: boolean
  def unchanged?(choice, %{saved: true} = chosen) do
    case choice do
      {:repository, source, ref} ->
        chosen.choice == :repository and source.git == chosen.git and ref == chosen.pin

      choice ->
        choice == chosen.choice
    end
  end

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
      else: unread_words(source)
  end

  def refusal_words(_reason, _source, _ref, _organisation), do: nil

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

  # The linked repository with the id `id`, else nil.
  defp source(linked, id) when is_list(linked) and is_binary(id),
    do: Enum.find(linked, &(&1.id == id))

  defp source(_linked, _id), do: nil

  # A harness's address without its scheme, as a credential-free address shows.
  defp address(git) when is_binary(git),
    do: git |> Document.shown() |> String.replace_prefix("https://", "")

  defp address(_git), do: ""

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
