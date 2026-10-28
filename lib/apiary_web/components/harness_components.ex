defmodule ApiaryWeb.HarnessComponents do
  # The harness choice of a workspace (`Apiary.Stacks.Sources.choose/2`), as the set-up's
  # Harness step (`ApiaryWeb.WorkspaceSetupLive`) and Workspace settings › Workflow
  # (`ApiaryWeb.WorkflowLive`) show it.
  #
  # `choices/1` is the three choices, the fields of a form named `harness`: `choice`,
  # `qory`, `target_file` or `repository`; and, for a harness repository, `source`, a
  # linked repository of `Apiary.Stacks.Sources.linked/1`, and `ref`, its branch or tag.
  # The Qory harness shows its address and the first 7 characters of its pin. A harness
  # repository lists the linked repositories, with Reading… until they are read, and
  # under Branch or tag, the organisation's connection it is read through. `line/1` is the
  # choice with its pin, as Workflow shows it. `form_params/2` is the form's values for a
  # saved choice, `choice/2` the choice the form's values come to, and
  # `refusal_words/3` why a save was refused. `qory/2` is the Qory harness the choices
  # show.
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
  attr :organisation, :string, required: true
  attr :disabled, :boolean, default: false

  # The three choices, and the fields of a harness repository once it is chosen.
  def choices(assigns) do
    choice = assigns.form[:choice].value
    source = source(assigns.linked, assigns.form[:source].value)

    assigns =
      assign(assigns,
        choice: choice,
        source: source,
        options: [
          {"qory", gettext("Qory harness"),
           "#{address(assigns.qory["git"])} · #{short(assigns.qory["ref"])}"},
          {"target_file", gettext("The harness in each target"),
           gettext("Each run reads its target's harness file.")},
          {"repository", gettext("A harness source"), nil}
        ]
      )

    ~H"""
    <fieldset id="harness-choice" class="q-choices grid gap-2">
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
      </label>
    </fieldset>

    <div :if={@choice == "repository"} id="harness-repository" class="grid gap-4">
      <select
        id="harness-source"
        name={@form[:source].name}
        aria-label={gettext("A harness source")}
        disabled={@disabled or @linked in [nil, []]}
        class="select select-sm w-full font-mono"
      >
        <option :if={is_nil(@linked)} value="" disabled selected>{gettext("Reading…")}</option>
        <option
          :for={linked <- @linked || []}
          value={linked.id}
          selected={@source && @source.id == linked.id}
        >
          {linked.label}
        </option>
      </select>
      <.input
        field={@form[:ref]}
        id="harness-ref"
        type="text"
        label={gettext("Harness version")}
        hint={
          @source &&
            gettext("Read through %{organisation}'s %{adapter} connection.",
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

  defp line_words(%{choice: :target_file}), do: gettext("The harness in each target")

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
  # `Apiary.Stacks.Sources.choose/2`; nil for a harness repository without a source or a
  # ref, and for any other value.
  @spec choice(map, [map] | nil) :: Apiary.Stacks.Sources.choice() | nil
  def choice(%{"choice" => "qory"}, _linked), do: :qory
  def choice(%{"choice" => "target_file"}, _linked), do: :target_file

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
  # refusal_words/3 is why the save of a harness repository, `source`, was refused, in the
  # words of Workflow's reads of a source; nil for a refusal those words do not cover.
  @spec refusal_words(term, map | nil, String.t()) :: String.t() | nil
  def refusal_words({:limited, seconds}, source, _organisation),
    do:
      ngettext(
        "Wait %{count} second, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        "Wait %{count} seconds, then reload the page to read %{source} again. Qory Apiary limits how often a person can read sources.",
        seconds,
        source: label(source)
      )

  def refusal_words({:walk, %{failure: failure}}, source, organisation)
      when failure in [:not_covered, :not_allowed],
      do:
        pgettext(
          "plain",
          "Link %{source} to %{organisation}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment.",
          source: label(source),
          organisation: organisation
        )

  def refusal_words({:walk, _failure}, source, _organisation),
    do:
      gettext(
        "Reload the page to read %{source} again, or choose another source. Qory Apiary could not read its stack: the call to its integration failed, or a file in it is not valid.",
        source: label(source)
      )

  def refusal_words(_reason, _source, _organisation), do: nil

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

  defp short(pin) when is_binary(pin), do: String.slice(pin, 0, @short)
  defp short(_pin), do: ""
end
