defmodule ApiaryWeb.WorkItemLive.VerifyTab do
  # The parts of the tab of a stage with a `verification` output, as a run's
  # `verification.json` and its demo scenarios have them: the verification frame (the matrix
  # of the acceptance criteria, the "not verified" list, the model families, after a member
  # accepted an escalation, who accepted it, and the findings a member accepted at an
  # earlier stage's round limit) and the Scenarios frame (each scenario's film, or its
  # pictures, in scenario order, with its title and steps); and the table of the acceptance
  # criteria, on the tab of the stage that wrote them.
  #
  # Qory Apiary reads these from the JSON documents as the run wrote them, and parses no
  # Markdown of them: it maps no model id to a family, and takes each criterion's words
  # from the newest acceptance criteria, by the criterion's id.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Artifacts
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.WorkItemLive.{StageComponents, StageTab}

  # The types whose versions are a scenario's film or pictures, in one Scenarios frame.
  @media ~w(demo-video screenshot)
  @videos Apiary.Artifacts.Format.video_types()
  @subtitles "text/vtt; charset=utf-8"
  @images ~w(image/png image/jpeg image/gif image/webp)

  @states %{"met" => :met, "not_met" => :not_met}

  @doc false
  # media/0 is the types of a scenario's film or pictures.
  @spec media() :: [String.t()]
  def media, do: @media

  ## verification.json and acceptance-criteria.json

  @doc false
  # verification/1 is the parts of a verification document, a version's `verification.json`
  # decoded (`verification.schema.json`), that the tab shows: `commit`, the verified
  # version of the target (`target_version`); `rows`, the matrix, each `%{criterion:,
  # state:, evidence:}`, `criterion` the criterion's id as the document has it, such as
  # `ac-4`, and `state` `:met` or `:not_met`; `not_verified`, each `%{criterion:, reason:}`;
  # and `families`, the model families. The push checked the document against the schema;
  # a value of another shape, such as the Markdown of a version stored before, is nil.
  @spec verification(term) :: map | nil
  def verification(%{"matrix" => matrix, "not_verified" => not_verified} = document)
      when is_list(matrix) and is_list(not_verified) do
    rows =
      for %{"criterion" => id, "state" => state, "evidence" => evidence} <- matrix,
          is_binary(id) and is_binary(evidence),
          do: %{criterion: id, state: Map.get(@states, state, state), evidence: evidence}

    unverified =
      for %{"criterion" => id, "reason" => reason} <- not_verified,
          is_binary(id) and is_binary(reason),
          do: %{criterion: id, reason: reason}

    families =
      for family <- List.wrap(document["model_families"]), is_binary(family), do: family

    %{
      commit: text(document["target_version"]),
      rows: rows,
      not_verified: unverified,
      families: families
    }
  end

  def verification(_document), do: nil

  @doc false
  # criteria/1 is an acceptance criteria document, a version's `acceptance-criteria.json`
  # decoded (`acceptance-criteria.schema.json`), as the pages show it: `summary`, and
  # `criteria` in the document's order, each `%{id:, text:, check:, removed:}`, `removed`
  # the reason of a removed criterion, nil for a live one. Nil for a value of another
  # shape.
  @spec criteria(term) :: map | nil
  def criteria(%{"criteria" => criteria} = document) when is_list(criteria) do
    shown =
      for %{"id" => id, "text" => words} = criterion <- criteria,
          is_binary(id) and is_binary(words) do
        %{
          id: id,
          text: words,
          check: text(criterion["check"]),
          removed: removed(criterion["removed"])
        }
      end

    %{summary: text(document["summary"]), criteria: shown}
  end

  def criteria(_document), do: nil

  defp removed(%{"reason" => reason}) when is_binary(reason), do: reason
  defp removed(_removed), do: nil

  @doc false
  # criterion_text/2 is the text of the criterion `id` in `criteria` (`criteria/1`), the
  # first with that id; nil for none.
  @spec criterion_text(map | nil, String.t()) :: String.t() | nil
  def criterion_text(%{criteria: criteria}, id) do
    Enum.find_value(criteria, fn criterion -> criterion.id == id && criterion.text end)
  end

  def criterion_text(_criteria, _id), do: nil

  @doc false
  # shown_id/1 is a criterion's id as a page shows it, in upper case: `AC-4` for `ac-4`.
  @spec shown_id(String.t()) :: String.t()
  def shown_id(id), do: String.upcase(id)

  @doc false
  # newest_criteria/2 is the newest acceptance criteria of `artifacts`
  # (`Apiary.Artifacts.list/1`): the newest version of `acceptance-criteria` `main` that no
  # cancelled run wrote, when it is no withdrawal, read as `criteria/1`, with that version
  # (nil for none) and `reads` with what it read (`stored_json/3`).
  @spec newest_criteria([map], map) :: {map | nil, map | nil, map}
  def newest_criteria(artifacts, reads) do
    with %{} = artifact <-
           Enum.find(artifacts, &(&1.type == "acceptance-criteria" and &1.name == "main")),
         %{withdrawn: false} = version <- Artifacts.newest_counted(artifact) do
      reads = stored_json(reads, version.public_id, version)
      {criteria(reads[{:json, version.public_id}]), version, reads}
    else
      _none -> {nil, nil, reads}
    end
  end

  ## The scenarios

  @doc false
  # scenarios/5 is the stage `stage_id`'s scenarios of the take in `take_in`, in scenario
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
  # name. Only the versions that a run of the take in wrote count
  # (`ApiaryWeb.WorkItemLive.StageTab.of_take_in/2`), and a version a cancelled run wrote
  # counts for none (`Apiary.Artifacts.cancelled?/1`). `read_json` is a version's JSON
  # document, nil for none, for each version of `documents/3`.
  @spec scenarios([map], String.t(), integer | nil, String.t() | nil, (map -> map | nil)) ::
          [map]
  def scenarios(artifacts, stage_id, take_in, commit, read_json) do
    artifacts = StageTab.of_take_in(artifacts, take_in)

    case evidence(artifacts, stage_id) do
      [] -> media_scenarios(artifacts, stage_id, read_json)
      evidence -> evidence_scenarios(evidence, artifacts, commit, read_json)
    end
  end

  @doc false
  # documents/3 is the versions whose JSON documents `scenarios/5` reads for the same
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

  @doc false
  # queue/4 is the scenarios of the stage `stage_id` of the take in `take_in` (`scenarios/5`)
  # for `work_item`, whose `artifacts` are `Apiary.Artifacts.list/1`: the verified commit
  # is that of the stage's verification, and each JSON document is read from the store. The
  # tab and the artifact page of a scenario's film or pictures show the same list.
  @spec queue(map, [map], String.t(), integer | nil) :: [map]
  def queue(work_item, artifacts, stage_id, take_in) do
    {queue, _reads} = queue(work_item, artifacts, stage_id, take_in, %{})
    queue
  end

  @doc false
  # queue/5 is `queue/4` and `reads`, what the page read from the store before, by version
  # (`stored_json/3`, `verification_parts/3`): a version never changes, so each is read
  # once. It returns the scenarios and `reads` with what it read.
  @spec queue(map, [map], String.t(), integer | nil, map) :: {[map], map}
  def queue(work_item, artifacts, stage_id, take_in, reads) do
    {commit, reads} = verified_commit(work_item, artifacts, stage_id, take_in, reads)

    reads =
      artifacts
      |> documents(stage_id, take_in)
      |> Enum.reduce(reads, &stored_json(&2, &1.public_id, &1))

    {scenarios(artifacts, stage_id, take_in, commit, &Map.get(reads, {:json, &1.public_id})),
     reads}
  end

  # The commit that the stage's verification verified: the `target_version` of the newest
  # version of the verification `main` made at the stage that a run of the take in wrote
  # and no member cancelled (`StageTab.of_take_in/2`, `Artifacts.newest_counted/1`); nil for
  # none.
  defp verified_commit(_work_item, artifacts, stage_id, take_in, reads) do
    newest =
      for %{type: "verification", name: "main"} = artifact <-
            StageTab.of_take_in(artifacts, take_in),
          versions = Enum.filter(artifact.versions, &(&1.stage_id == stage_id)),
          %{withdrawn: false, number: number} <- [Artifacts.newest_counted(%{versions: versions})],
          do: number

    with [number] <- newest,
         {%{commit: commit}, reads} <- verification_parts(artifacts, number, reads) do
      {commit, reads}
    else
      {nil, reads} -> {nil, reads}
      [] -> {nil, reads}
    end
  end

  @doc false
  # verification_parts/3 is the parts of version `number` of the verification `main` of
  # `artifacts` (`Apiary.Artifacts.list/1`), as `verification/1` reads its JSON document,
  # nil for none, the document read once per version in `reads` (`stored_json/3`); it
  # returns the parts and `reads`.
  @spec verification_parts([map], pos_integer, map) :: {map | nil, map}
  def verification_parts(artifacts, number, reads) do
    version =
      for %{type: "verification", name: "main"} = artifact <- artifacts,
          %{number: ^number} = version <- artifact.versions,
          reduce: nil,
          do: (_found -> version)

    case version do
      nil ->
        {nil, reads}

      version ->
        reads = stored_json(reads, version.public_id, version)
        {verification(reads[{:json, version.public_id}]), reads}
    end
  end

  @doc false
  # stored_json/3 is `reads` with the JSON document of the version whose public id is `id`,
  # read once. A read the store could not do is not kept, so the next read tries again.
  @spec stored_json(map, String.t(), map) :: map
  def stored_json(reads, id, version) do
    key = {:json, id}

    case reads do
      %{^key => _read} ->
        reads

      _unread ->
        case Apiary.Stages.Artifacts.stored_json(version) do
          {:ok, decoded} -> Map.put(reads, key, decoded)
          {:error, :store_unavailable} -> reads
        end
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
      version: version
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
  attr :criteria, :map, required: true, doc: "`criteria/1`"

  @doc false
  # criteria_body/1 is the frame of the acceptance criteria: the summary, then the table of
  # the criteria, Id, Criterion and Check, in the document's order, each id in upper case;
  # a removed criterion with its text struck through, the badge Removed and the reason,
  # and its check muted. Under 640 px the check moves under the criterion. Each row's DOM id
  # ends in the criterion's id, which an About line links to.
  def criteria_body(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4">
      <p :if={@criteria.summary} id={"#{@id}-summary"} class="text-[14px]/6">
        {@criteria.summary}
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
              <th scope="col">{gettext("Id")}</th>
              <th scope="col">{gettext("Criterion")}</th>
              <th scope="col" class="q-from-sm">{gettext("Check")}</th>
            </tr>
          </thead>
          <tbody id={"#{@id}-rows"}>
            <tr :for={criterion <- @criteria.criteria} id={"#{@id}-#{criterion.id}"}>
              <td class={["whitespace-nowrap font-medium", criterion.removed && "text-muted"]}>
                {shown_id(criterion.id)}
              </td>
              <td class="whitespace-normal">
                <span :if={!criterion.removed}>{criterion.text}</span>
                <span :if={criterion.removed} class="text-muted line-through">{criterion.text}</span>
                <div
                  :if={criterion.removed}
                  class="mt-1 flex flex-wrap items-center gap-1.5 text-[12.5px]/5 text-muted"
                >
                  <.badge>{gettext("Removed")}</.badge>
                  <span>{criterion.removed}</span>
                </div>
                <div :if={criterion.check} class="q-to-sm mt-1 text-[12.5px]/5 text-muted">
                  {criterion.check}
                </div>
              </td>
              <td class={[
                "q-from-sm whitespace-normal text-[13px]/5",
                criterion.removed && "text-muted"
              ]}>
                {criterion.check}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :verification, :map, required: true, doc: "`verification/1`"
  attr :criteria, :map, default: nil, doc: "the newest acceptance criteria, `criteria/1`"

  attr :answers, :map,
    default: %{},
    doc: "by criterion id, the open question about it, `{number, path}`"

  attr :accepted, :string, default: nil, doc: "the member who accepted the escalation"

  attr :findings, :list,
    default: [],
    doc: "the findings accepted at an earlier stage's round limit, `accepted_findings`"

  attr :anchors, :map,
    default: %{},
    doc: "the DOM id of each scenario of the Scenarios frame, by its number"

  slot :inner_block, doc: "the verification's artifact row"

  @doc false
  # verification_body/1 is the verification frame's body: who accepted the escalation, the
  # matrix, the "not verified" list, the findings accepted at an earlier stage's round
  # limit, and the artifact row. A matrix row and an item of Not verified show the
  # criterion's id in upper case and its text from the newest acceptance criteria; a row
  # whose criterion has an open question links to it ("Answer question 4.").
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
                <.criterion id={row.criterion} criteria={@criteria} />
                <div class="q-to-sm mt-1 text-[12.5px]/5 text-muted">
                  <.evidence text={row.evidence} anchors={@anchors} />
                </div>
              </td>
              <td class="whitespace-nowrap">
                <.state_badge state={row.state} />
                <div :if={@answers[row.criterion]} class="mt-1 whitespace-nowrap text-[13px]/5">
                  <.link
                    id={"#{@id}-matrix-#{i}-answer"}
                    href={elem(@answers[row.criterion], 1)}
                    class="q-link"
                  >
                    {answer_words(elem(@answers[row.criterion], 0))}
                  </.link>
                </div>
              </td>
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
            <span><.criterion id={item.criterion} criteria={@criteria} /></span>
            <span class="text-[12.5px]/5 text-muted">{item.reason}</span>
          </li>
        </ul>
      </section>
      <section
        :if={@findings != []}
        id={"#{@id}-accepted-findings"}
        class="q-xp-sec"
        aria-labelledby={"#{@id}-accepted-findings-h"}
      >
        <h3 id={"#{@id}-accepted-findings-h"} class="q-xp-sec-t">
          {gettext("Accepted findings")}
        </h3>
        <%= for {accepted, k} <- Enum.with_index(@findings) do %>
          <p id={"#{@id}-accepted-findings-#{k}-by"} class="mb-2 text-[12.5px]/5 text-muted">
            {gettext("Accepted as it is in %{stage} by %{member}, %{when}.",
              stage: accepted.stage,
              member: accepted.member,
              when: ApiaryWeb.Format.datetime(accepted.at)
            )}
          </p>
          <ul
            :if={accepted.findings != []}
            id={"#{@id}-accepted-findings-#{k}"}
            class="grid gap-2 text-[13px]/5"
          >
            <li
              :for={{finding, i} <- Enum.with_index(accepted.findings)}
              id={"#{@id}-accepted-findings-#{k}-#{i}"}
              class="grid gap-0.5 border-b border-base-300 pb-2 last:border-b-0"
            >
              <span>{finding}</span>
            </li>
          </ul>
        <% end %>
      </section>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :criteria, :map, default: nil

  # A criterion in the matrix or in Not verified: its id in upper case, then its text from
  # the newest acceptance criteria, where they have that id.
  defp criterion(assigns) do
    assigns = assign(assigns, :text, criterion_text(assigns.criteria, assigns.id))

    ~H"""
    <span class="font-medium">{shown_id(@id)}</span>{if @text, do: [" ", @text]}
    """
  end

  # The words of a matrix row's link to the open question about its criterion, in the words
  # of a verdict point's: "Answer question 4.".
  defp answer_words(number),
    do:
      gettext("Answer %{question}.",
        question: gettext("question %{number}", number: ApiaryWeb.Format.number(number))
      )

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

  defp state_badge(assigns), do: ~H|<.badge>{@state}</.badge>|

  attr :id, :string, required: true
  attr :scenarios, :list, required: true, doc: "`scenarios/5`"
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
        <figure :for={{file, n} <- Enum.with_index(@videos)} class="grid content-start gap-2">
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
          <div class="flex flex-wrap items-center gap-2">
            <.watch
              id={if n == 0, do: "#{@id}-watch", else: "#{@id}-watch-#{n}"}
              scenario={@scenario}
              scope={@scope}
              number={@number}
              film={n}
            />
          </div>
          <figcaption class="text-[12.5px] text-muted break-all">{file.filename}</figcaption>
        </figure>
      </div>
      <div class="grid content-start gap-2">
        <h3 id={"#{@id}-h"} class="q-xp-sec-t">{scenario_title(@scenario)}</h3>
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
      <div class="flex flex-wrap items-center gap-2">
        <.watch id={"#{@id}-watch"} scenario={@scenario} scope={@scope} number={@number} />
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
  attr :scope, :any, required: true
  attr :number, :integer, required: true

  attr :film, :integer,
    default: nil,
    doc:
      "the film's place among the scenario's films, from 0; its link carries the time and speed"

  # The Watch button of a scenario: opens its version's page, the player page with the other
  # scenarios beside it. On a film, the `WatchHandoff` hook leaves the film's time and speed
  # for that page, which does not start it.
  defp watch(assigns) do
    ~H"""
    <.button
      id={@id}
      navigate={ArtifactComponents.version_path(@scope, @number, @scenario.version.public_id)}
      size="xs"
      title={gettext("Watch this scenario on its page, with the other scenarios beside it")}
      class={ArtifactComponents.size_class()}
      phx-hook={@film && "WatchHandoff"}
      data-version={@film && @scenario.version.public_id}
      data-film={@film}
    >
      <.icon name="hero-play-micro" class="size-4 shrink-0" />
      <span>{gettext("Watch")}</span>
    </.button>
    """
  end

  @doc false
  # pictures/1 is a pictures scenario's pictures, `{file, step, number}`: for each step, the
  # image whose name ends in `-step-<number>.<extension>`, else the image at the step's
  # place; with no steps, each image in name order, with no step.
  @spec pictures(map) :: [{map, map | nil, pos_integer}]
  def pictures(%{steps: [], version: version}) do
    for {file, i} <- Enum.with_index(images(version), 1), do: {file, nil, i}
  end

  def pictures(%{steps: steps, version: version}) do
    images = images(version)

    for {step, i} <- Enum.with_index(steps, 1),
        file =
          Enum.find(images, &(&1.filename =~ ~r/-step-#{i}\.[a-z]+$/)) || Enum.at(images, i - 1),
        file != nil,
        do: {file, step, i}
  end

  defp images(version), do: Enum.filter(version.files, &(&1.content_type in @images))

  @doc false
  # scenario_title/1 is a scenario's heading: "Scenario 2: Voucher line on a phone", else
  # its title as written, else its artifact's name.
  @spec scenario_title(map) :: String.t()
  def scenario_title(%{number: number, title: title})
      when is_integer(number) and is_binary(title),
      do: gettext("Scenario %{number}: %{title}", number: number, title: title)

  def scenario_title(%{title: title}) when is_binary(title), do: title
  def scenario_title(%{artifact: artifact}), do: artifact.name

  @doc false
  # step_title/2 is step `i` of a scenario in words: "Step 2: Reload the page".
  @spec step_title(pos_integer, %{title: String.t()}) :: String.t()
  def step_title(i, %{title: title}),
    do: gettext("Step %{number}: %{title}", number: i, title: title)

  defp file_src(%{scope: scope, number: number, scenario: %{version: version}}, file),
    do: ArtifactComponents.file_path(scope, number, version.public_id, file)
end
