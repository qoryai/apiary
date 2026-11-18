defmodule ApiaryWeb.WorkItemLive.VerifyTab do
  # The parts of the tab of a stage with a `verification` output, as a run's `verification.md`
  # and its demo scenarios have them: the verification frame (the matrix of the acceptance
  # criteria, the "not verified" list, the model families and, after a member accepted an
  # escalation, who accepted it) and the Scenarios frame (each scenario's film, or its
  # pictures, in scenario order, with its title and steps).
  #
  # Qory Apiary reads these from the files as the run wrote them: it maps no model id to a
  # family and writes no criterion's words.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Artifacts
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.ArtifactLive.Markdown
  alias ApiaryWeb.WorkItemLive.{StageComponents, StageTab}

  # The types whose versions are a scenario's film or pictures, in one Scenarios frame.
  @media ~w(demo-video screenshot)
  @videos ~w(video/mp4 video/webm)
  @subtitles "text/vtt; charset=utf-8"
  @images ~w(image/png image/jpeg image/gif image/webp)

  @states %{"Met" => :met, "Not met" => :not_met, "Needs a person" => :needs_person}

  @doc false
  # media/0 is the types of a scenario's film or pictures.
  @spec media() :: [String.t()]
  def media, do: @media

  ## verification.md

  @doc false
  # verification/1 is the parts of a `verification.md` that the tab shows: `commit`, the
  # verified commit from `## Summary` ("Commit: <id>"), nil for none; `rows`, the rows of
  # the table of `## Matrix`, each `%{criterion:, state:, evidence:}`, `state` `:met`,
  # `:not_met`, `:needs_person` or the cell as written; `not_verified`, the items of
  # `## Not verified`, each `%{item:, reason:}`, the item's criterion and the reason
  # after it, or the line as written with no reason; and `families`, the lines of
  # `## Model families`. Nil for a text with no table of the columns Criterion, State and
  # Evidence under `## Matrix`, and for a text that a Markdown render does not format: over
  # `ApiaryWeb.ArtifactLive.Markdown.max_bytes/0` bytes, not UTF-8, with tables that could
  # have more cells than `Markdown.max_cells/0` (`Markdown.formattable?/1`, checked before
  # the parser builds any cell), or one the page cannot read within the budget of a
  # Markdown render (`Markdown.budget/0`).
  @spec verification(String.t() | nil) :: map | nil
  def verification(text) when is_binary(text) do
    if byte_size(text) <= Markdown.max_bytes() and Markdown.formattable?(text) do
      case Apiary.Kinds.Budget.run(fn -> parse(text) end, Markdown.budget()) do
        {:ok, parsed} -> parsed
        {:error, _passed} -> nil
      end
    end
  end

  def verification(_text), do: nil

  defp parse(text) do
    sections = text |> MDEx.parse_document!(extension: [table: true]) |> sections()

    with %{} = rows <- matrix(sections["Matrix"] || []) do
      %{
        commit: commit(sections["Summary"] || []),
        rows: rows.rows,
        not_verified: not_verified(sections["Not verified"] || []),
        families: families(sections["Model families"] || [])
      }
    end
  end

  # The nodes under each `##` heading, by its words.
  defp sections(%MDEx.Document{nodes: nodes}) do
    {sections, _title} =
      Enum.reduce(nodes, {%{}, nil}, fn
        %MDEx.Heading{level: 2, nodes: words}, {sections, _title} ->
          title = words |> plain() |> String.trim()
          {Map.put_new(sections, title, []), title}

        _node, {sections, nil} ->
          {sections, nil}

        node, {sections, title} ->
          {Map.update!(sections, title, &(&1 ++ [node])), title}
      end)

    sections
  end

  defp matrix(nodes) do
    with %MDEx.Table{nodes: [%MDEx.TableRow{nodes: head} | rows]} <-
           Enum.find(nodes, &match?(%MDEx.Table{}, &1)),
         ["Criterion", "State", "Evidence"] <- Enum.map(head, &cell/1) do
      %{
        rows:
          for %MDEx.TableRow{nodes: cells} <- rows do
            [criterion, state, evidence] =
              cells |> Enum.map(&cell/1) |> Kernel.++(["", "", ""]) |> Enum.take(3)

            %{criterion: criterion, state: Map.get(@states, state, state), evidence: evidence}
          end
      }
    else
      _none -> nil
    end
  end

  defp cell(%MDEx.TableCell{nodes: nodes}), do: nodes |> plain() |> String.trim()

  defp commit(nodes) do
    case Regex.run(~r/\bCommit: *([0-9a-f]{40}|[0-9a-f]{64})\b/, plain(nodes)) do
      [_line, commit] -> commit
      nil -> nil
    end
  end

  # An item `AC-2, "<criterion>": <reason>` is the criterion and the reason; another
  # item, such as "None.", is the item as written, with no reason.
  defp not_verified(nodes) do
    for %MDEx.List{nodes: items} <- nodes,
        %MDEx.ListItem{nodes: item} <- items,
        line = item |> plain() |> String.trim(),
        line not in ["", "None."] do
      case Regex.run(~r/^([A-Za-z]+-[0-9]+, +".+?"): +(.+)$/s, line) do
        [_line, criterion, reason] -> %{item: criterion, reason: reason}
        nil -> %{item: line, reason: nil}
      end
    end
  end

  # The model families as the run wrote them, one sentence or line of the section each:
  # "Build: claude. Verify: gpt-5.1." is "Build claude" and "Verify gpt-5.1". A sentence
  # ends at a "." before a space or the end of the text, so a "." inside a model's name
  # stays in it.
  defp families(nodes) do
    text = nodes |> plain() |> String.trim()

    pairs =
      for part <- String.split(text, ~r/\.(?=\s|$)|\n/, trim: true),
          [_part, stage, family] <- [Regex.run(~r/^\s*([^:]+?): *(.+?)\s*$/, part)],
          do: "#{stage} #{family}"

    cond do
      pairs != [] -> pairs
      text == "" -> []
      true -> [text]
    end
  end

  defp plain(nodes) when is_list(nodes), do: nodes |> Enum.map(&plain/1) |> Enum.join()
  defp plain(%MDEx.SoftBreak{}), do: "\n"
  defp plain(%MDEx.LineBreak{}), do: "\n"
  defp plain(%MDEx.Paragraph{nodes: nodes}), do: plain(nodes) <> "\n"
  defp plain(%{literal: literal}) when is_binary(literal), do: literal
  defp plain(%{nodes: nodes}) when is_list(nodes), do: plain(nodes)
  defp plain(_node), do: ""

  ## The scenarios

  @doc false
  # scenarios/6 is the stage `stage_id`'s scenarios of the take in `take_in`, in scenario
  # order, from `artifacts` (`Apiary.Artifacts.list/1`, without a withdrawn name):
  # `%{key:, number:, title:, steps:, kind:, artifact:, version:}`, `kind` `:film` for a
  # `demo-video` version and `:pictures` for a `screenshot` one, `steps` each `%{title:,
  # expected:}`, `artifact` with `version` as its one version, so its row shows that
  # version. `key` is the scenario's name, unique among the scenarios.
  #
  # Each `demo-evidence` name's newest version at the stage gives one scenario: its film or
  # pictures (`media`), title and steps; with `commit`, only the evidence of that commit.
  # At a stage with no `demo-evidence`, each `demo-video` and `screenshot` name's newest
  # version is a scenario, with the title and steps of the newest `demo-script` of the same
  # name. Of the versions not in `persons`, only those that a run of the take in wrote count
  # (`ApiaryWeb.WorkItemLive.StageTab.of_take_in/2`), and a version a cancelled run wrote
  # counts for none (`Apiary.Artifacts.cancelled?/1`). `read_json` is a version's JSON
  # document, nil for none, for each version of `documents/3`.
  #
  # `persons` is the versions of films and pictures that a person made and that an approval
  # of the stage records (`ApiaryWeb.WorkItemLive.StageTab.verify_frames/3`), each
  # `%{type:, name:, id:, number:, writer:}`, `id` the version's public id and `writer` the
  # member's short name. Each is a scenario with `writer` set, for its caption: in the
  # place of the scenario of the same artifact where that one has a lower number, else
  # after the others, with its name as its title and no number. A run's scenario has
  # `writer` nil.
  @spec scenarios(
          [map],
          String.t(),
          integer | nil,
          String.t() | nil,
          (map -> map | nil),
          [map]
        ) :: [map]
  def scenarios(artifacts, stage_id, take_in, commit, read_json, persons \\ []) do
    of_take_in = StageTab.of_take_in(artifacts, take_in)

    scenarios =
      case evidence(of_take_in, stage_id) do
        [] -> media_scenarios(of_take_in, stage_id, read_json)
        evidence -> evidence_scenarios(evidence, of_take_in, commit, read_json)
      end

    Enum.reduce(persons, scenarios, &fed(&2, artifacts, &1))
  end

  # `scenarios` with the person's version `person` (`scenarios/6`).
  defp fed(scenarios, artifacts, %{type: type, name: name, id: id, writer: writer}) do
    with %{} = artifact <- Enum.find(artifacts, &(&1.type == type and &1.name == name)),
         %{} = version <- Enum.find(artifact.versions, &(&1.public_id == id)) do
      shown = %{artifact: %{artifact | versions: [version]}, version: version, writer: writer}
      at = Enum.find_index(scenarios, &(&1.artifact.type == type and &1.artifact.name == name))

      cond do
        at == nil ->
          # The key has the type and the name between "--", so it is no run scenario's key
          # and no such key with a suffix of an id after it.
          entry = scenario("#{type}--#{name}--", nil, %{}, artifact, version)
          scenarios ++ [Map.merge(entry, shown)]

        Enum.at(scenarios, at).version.number < version.number ->
          List.update_at(scenarios, at, &Map.merge(&1, shown))

        true ->
          scenarios
      end
    else
      _none -> scenarios
    end
  end

  @doc false
  # documents/3 is the versions whose JSON documents `scenarios/6` reads for the same
  # `artifacts`, `stage_id` and `take_in`: each scenario's demo evidence, or, at a stage
  # with none, the demo script of each film or pictures.
  @spec documents([map], String.t(), integer | nil) :: [map]
  def documents(artifacts, stage_id, take_in) do
    artifacts = StageTab.of_take_in(artifacts, take_in)

    case evidence(artifacts, stage_id) do
      [] ->
        for {artifact, _version} <- media(artifacts, stage_id),
            script = script(artifacts, artifact.name),
            script != nil,
            do: script

      evidence ->
        for {_name, version} <- evidence, do: version
    end
  end

  defp evidence(artifacts, stage_id) do
    for %{type: "demo-evidence"} = artifact <- artifacts,
        version = at_stage(artifact, stage_id),
        version != nil,
        do: {artifact.name, version}
  end

  defp media(artifacts, stage_id) do
    for %{type: type} = artifact <- artifacts,
        type in @media,
        version = at_stage(artifact, stage_id),
        version != nil,
        do: {artifact, version}
  end

  # The newest counted version of the demo script `name`, nil for none.
  defp script(artifacts, name) do
    case Enum.find(artifacts, &(&1.type == "demo-script" and &1.name == name)) do
      nil -> nil
      script -> Artifacts.newest_counted(script)
    end
  end

  defp evidence_scenarios(evidence, artifacts, commit, read_json) do
    for {name, version} <- evidence,
        %{"media" => %{"type" => type, "name" => media_name, "version" => number}} = data <-
          [read_json.(version)],
        is_nil(commit) or data["commit"] == commit,
        type in @media,
        artifact = Enum.find(artifacts, &(&1.type == type and &1.name == media_name)),
        media = artifact && Enum.find(artifact.versions, &(&1.number == number)),
        media != nil and not media.withdrawn and not Artifacts.cancelled?(media) do
      scenario(name, name, data, artifact, media)
    end
    |> ordered()
  end

  defp media_scenarios(artifacts, stage_id, read_json) do
    for {artifact, version} <- media(artifacts, stage_id) do
      data =
        case script(artifacts, artifact.name) do
          nil -> %{}
          script -> read_json.(script) || %{}
        end

      scenario("#{artifact.type}-#{artifact.name}", artifact.name, data, artifact, version)
    end
    |> ordered()
  end

  defp scenario(key, name, data, artifact, version) do
    %{
      key: key,
      number: number(data["scenario"]) || number(name),
      title: text(data["title"]),
      steps:
        for(
          %{"title" => title} = step when is_binary(title) <- List.wrap(data["steps"]),
          do: %{title: title, expected: text(step["expected"])}
        ),
      kind: if(artifact.type == "screenshot", do: :pictures, else: :film),
      artifact: %{artifact | versions: [version]},
      version: version,
      writer: nil
    }
  end

  # The newest version of `artifact` made at the stage that no cancelled run wrote and
  # that is no withdrawal; nil for none.
  defp at_stage(artifact, stage_id) do
    Enum.find(
      artifact.versions,
      &(&1.stage_id == stage_id and not &1.withdrawn and not Artifacts.cancelled?(&1))
    )
  end

  defp ordered(scenarios),
    do: Enum.sort_by(scenarios, &{is_nil(&1.number), &1.number, Artifacts.name_order(&1.key)})

  defp number("scenario-" <> number) do
    case Integer.parse(number) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp number(_name), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  @doc false
  # label/2 is an artifact's words in a row on the tab, in today's plain form: the type
  # with a space for each "-" (`StageComponents.type_words/1`), the name where it is not
  # `main`, and the version's number, such as "demo video scenario-1 v1".
  @spec label(map, map) :: String.t()
  def label(%{type: type, name: "main"}, %{number: number}),
    do:
      gettext("%{type} v%{number}",
        type: StageComponents.type_words(type),
        number: ApiaryWeb.Format.number(number)
      )

  def label(%{type: type, name: name}, %{number: number}),
    do:
      gettext("%{type} %{name} v%{number}",
        type: StageComponents.type_words(type),
        name: name,
        number: ApiaryWeb.Format.number(number)
      )

  ## The frames' bodies

  attr :id, :string, required: true
  attr :verification, :map, required: true, doc: "`verification/1`"
  attr :accepted, :string, default: nil, doc: "the member who accepted the escalation"

  attr :anchors, :map,
    default: %{},
    doc: "the DOM id of each scenario of the Scenarios frame, by its number"

  slot :inner_block, doc: "the verification's artifact row"

  @doc false
  # verification_body/1 is the verification frame's body: who accepted the escalation, the
  # matrix, the "not verified" list and the artifact row.
  def verification_body(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4">
      <p :if={@accepted} id={"#{@id}-accepted"} class="text-[12.5px]/5 text-muted">
        {gettext("Accepted as it is by %{member}", member: @accepted)}
      </p>
      <div
        class="q-tbl overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
        tabindex="0"
        role="region"
        aria-label={gettext("Acceptance criteria")}
      >
        <table class="table">
          <thead>
            <tr>
              <th scope="col">{gettext("Criterion")}</th>
              <th scope="col">{gettext("State")}</th>
              <th scope="col" class="q-from-sm">{gettext("Evidence")}</th>
            </tr>
          </thead>
          <tbody id={"#{@id}-matrix"}>
            <tr :for={{row, i} <- Enum.with_index(@verification.rows)} id={"#{@id}-matrix-#{i}"}>
              <td class="whitespace-normal">
                {row.criterion}
                <div class="q-to-sm mt-1 text-[12.5px]/5 text-muted">
                  <.evidence text={row.evidence} anchors={@anchors} />
                </div>
              </td>
              <td class="whitespace-nowrap"><.state_badge state={row.state} /></td>
              <td class="q-from-sm whitespace-normal text-[13px]/5">
                <.evidence text={row.evidence} anchors={@anchors} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <section
        :if={@verification.not_verified != []}
        id={"#{@id}-not-verified"}
        class="q-xp-sec"
        aria-labelledby={"#{@id}-not-verified-h"}
      >
        <h3 id={"#{@id}-not-verified-h"} class="q-xp-sec-t">{gettext("Not verified")}</h3>
        <ul class="grid gap-2 text-[13px]/5">
          <li
            :for={{item, i} <- Enum.with_index(@verification.not_verified)}
            id={"#{@id}-not-verified-#{i}"}
            class="grid gap-0.5 border-b border-base-300 pb-2 last:border-b-0"
          >
            <span>{item.item}</span>
            <span :if={item.reason} class="text-[12.5px]/5 text-muted">{item.reason}</span>
          </li>
        </ul>
      </section>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :text, :string, required: true
  attr :anchors, :map, required: true

  # An Evidence cell: its text, each reference to a scenario of the Scenarios frame a link
  # to that scenario.
  # The parts are joined with no space between them, which a template would add.
  defp evidence(assigns), do: ~H"{evidence_html(@text, @anchors)}"

  defp evidence_html(text, anchors) do
    {:safe,
     for part <- evidence_parts(text, anchors) do
       case part do
         {:link, words, anchor} ->
           [~s|<a href="#|, escape(anchor), ~s|" class="text-accent">|, escape(words), "</a>"]

         words ->
           escape(words)
       end
     end}
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc false
  # evidence_parts/2 is the Evidence cell `text` in parts: each reference to a scenario
  # whose number has a DOM id in `anchors` is `{:link, words, id}`, and the text around
  # it is a string. A reference is one of the phrases "Demo video: scenario 1", "Pictures:
  # scenario 2" and "the pictures of scenario 2", linked whole; any other text stays text,
  # as does a phrase for a scenario not in `anchors`. The phrases are case-sensitive, and
  # the number is read as an integer, so "scenario 02" is scenario 2.
  @spec evidence_parts(String.t(), %{integer => String.t()}) ::
          [String.t() | {:link, String.t(), String.t()}]
  def evidence_parts(text, anchors) when map_size(anchors) == 0, do: [text]

  def evidence_parts(text, anchors) do
    reference()
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn part ->
      with [_whole, number] <- Regex.run(reference(), part),
           {number, ""} <- Integer.parse(number),
           %{^number => anchor} <- anchors do
        [{:link, part, anchor}]
      else
        _text -> [part]
      end
    end)
    |> Enum.chunk_by(&is_binary/1)
    |> Enum.flat_map(fn
      [text | _more] = texts when is_binary(text) -> [Enum.join(texts)]
      links -> links
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # The one pattern for the phrases of an Evidence cell that name a scenario; the first
  # group is the scenario's number.
  defp reference do
    ~r/\b(?:Demo video: |Pictures: |the pictures of )scenario ([0-9]+)\b/
  end

  attr :state, :any, required: true

  defp state_badge(%{state: :met} = assigns),
    do: ~H|<.badge color="success" dot>{gettext("Met")}</.badge>|

  defp state_badge(%{state: :not_met} = assigns),
    do: ~H|<.badge color="error" dot>{gettext("Not met")}</.badge>|

  defp state_badge(%{state: :needs_person} = assigns),
    do: ~H|<.badge color="warning" dot>{gettext("Needs a person")}</.badge>|

  defp state_badge(assigns), do: ~H|<.badge>{@state}</.badge>|

  attr :id, :string, required: true
  attr :scenarios, :list, required: true, doc: "`scenarios/6`"
  attr :scope, :any, required: true
  attr :number, :integer, required: true

  @doc false
  # scenarios_body/1 is the Scenarios frame's body: each scenario in its order, a film
  # with its file name and captions and, beside it, its title, steps and artifact row; or
  # its pictures, one per step, each with the step's title and expected result.
  def scenarios_body(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4">
      <.scenario
        :for={scenario <- @scenarios}
        id={"#{@id}-#{scenario.key}"}
        scenario={scenario}
        scope={@scope}
        number={@number}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :scenario, :map, required: true
  attr :scope, :any, required: true
  attr :number, :integer, required: true

  defp scenario(%{scenario: %{kind: :film}} = assigns) do
    files = assigns.scenario.version.files

    assigns =
      assign(assigns,
        videos: Enum.filter(files, &(&1.content_type in @videos)),
        subtitles: Enum.filter(files, &(&1.content_type == @subtitles))
      )

    ~H"""
    <div
      id={@id}
      class="grid gap-3 border-b border-base-300 last:border-b-0 lg:grid-cols-[minmax(0,1fr)_minmax(10rem,14rem)]"
    >
      <div class="grid content-start gap-2">
        <figure :for={file <- @videos} class="grid content-start gap-2">
          <video
            controls
            preload="metadata"
            class="max-h-[70vh] max-w-full rounded-field bg-black"
            aria-label={file.filename}
          >
            <source src={file_src(assigns, file)} type={file.content_type} />
            <%!-- No track is `default`: the captions start off, on every film of the tab. --%>
            <track
              :for={track <- @subtitles}
              kind="captions"
              label={track.filename}
              src={file_src(assigns, track)}
            />
          </video>
          <figcaption class="text-[12.5px] text-muted break-all">{file.filename}</figcaption>
        </figure>
      </div>
      <div class="grid content-start gap-2">
        <h3 id={"#{@id}-h"} class="q-xp-sec-t">{scenario_title(@scenario)}</h3>
        <.caption id={@id} scenario={@scenario} />
        <ul :if={@scenario.steps != []} id={"#{@id}-steps"} class="grid gap-2 text-[13px]/5">
          <li :for={{step, i} <- Enum.with_index(@scenario.steps, 1)} class="grid gap-0.5">
            <span>{step_title(i, step)}</span>
            <span :if={step.expected} class="text-[12.5px]/5 text-muted">
              {gettext("Expected: %{result}", result: step.expected)}
            </span>
          </li>
        </ul>
        <ArtifactComponents.list
          id={"#{@id}-row"}
          artifacts={[@scenario.artifact]}
          scope={@scope}
          number={@number}
          label={&label/2}
        />
      </div>
    </div>
    """
  end

  defp scenario(%{scenario: %{kind: :pictures}} = assigns) do
    assigns = assign(assigns, :pictures, pictures(assigns.scenario))

    ~H"""
    <div id={@id} class="grid gap-3 border-b border-base-300 last:border-b-0">
      <h3 id={"#{@id}-h"} class="q-xp-sec-t">{scenario_title(@scenario)}</h3>
      <.caption id={@id} scenario={@scenario} />
      <p class="text-[12.5px]/5 text-muted">
        {gettext("Pictures, one for each step, 390 px wide.")}
      </p>
      <div id={"#{@id}-pictures"} class="flex flex-wrap gap-4">
        <figure
          :for={{file, step, i} <- @pictures}
          id={"#{@id}-picture-#{i}"}
          class="grid w-36 content-start gap-1"
        >
          <img
            src={file_src(assigns, file)}
            alt={
              if step,
                do: gettext("Picture: %{step}", step: step_title(i, step)),
                else: gettext("Image: %{filename}", filename: file.filename)
            }
            class="max-w-full rounded-field border border-base-300 object-contain object-left"
            loading="lazy"
          />
          <figcaption class="grid gap-0.5 text-[12.5px]/5">
            <span>{if step, do: step_title(i, step), else: file.filename}</span>
            <span :if={step && step.expected} class="text-muted">
              {gettext("Expected: %{result}", result: step.expected)}
            </span>
          </figcaption>
        </figure>
      </div>
      <ArtifactComponents.list
        id={"#{@id}-row"}
        artifacts={[@scenario.artifact]}
        scope={@scope}
        number={@number}
        label={&label/2}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :scenario, :map, required: true

  # A person's scenario's caption: the version's number and the member's short name, as an
  # output frame's caption has them.
  defp caption(assigns) do
    ~H"""
    <p :if={@scenario.writer} id={"#{@id}-caption"} class="q-xp-cap">
      <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
      <span phx-no-format>{gettext("Version %{version}", version: ApiaryWeb.Format.number(@scenario.version.number))} · {@scenario.writer}</span>
    </p>
    """
  end

  # A pictures scenario's pictures, `{file, step, number}`: for each step, the image whose
  # name ends in `-step-<number>.<extension>`, else the image at the step's place; with no
  # steps, each image in name order, with no step.
  defp pictures(%{steps: [], version: version}) do
    for {file, i} <- Enum.with_index(images(version), 1), do: {file, nil, i}
  end

  defp pictures(%{steps: steps, version: version}) do
    images = images(version)

    for {step, i} <- Enum.with_index(steps, 1),
        file =
          Enum.find(images, &(&1.filename =~ ~r/-step-#{i}\.[a-z]+$/)) || Enum.at(images, i - 1),
        file != nil,
        do: {file, step, i}
  end

  defp images(version), do: Enum.filter(version.files, &(&1.content_type in @images))

  defp scenario_title(%{number: number, title: title})
       when is_integer(number) and is_binary(title),
       do: gettext("Scenario %{number}: %{title}", number: number, title: title)

  defp scenario_title(%{title: title}) when is_binary(title), do: title
  defp scenario_title(%{artifact: artifact}), do: artifact.name

  defp step_title(i, %{title: title}),
    do: gettext("Step %{number}: %{title}", number: i, title: title)

  defp file_src(%{scope: scope, number: number, scenario: %{version: version}}, file),
    do: ArtifactComponents.file_path(scope, number, version.public_id, file)
end
