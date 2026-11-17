defmodule ApiaryWeb.SubmissionComponents do
  # The submissions of a work item as Qory Apiary shows them: the Submissions frame of a
  # stage's tab, one row for each run that stored a version of the submission type, and the
  # Submission block of a run's page, the row of the version that run stored
  # (`Apiary.Submissions`).
  #
  # A submission is untrusted data a run wrote. Every string in it reaches the page as
  # text, which HEEx escapes, and as an external system's text where it is words
  # (`Apiary.ExternalText`); a link is drawn only for an `https` address
  # (`Apiary.Submissions`) and has `rel="noopener noreferrer nofollow"`.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias ApiaryWeb.BacklogComponents
  alias ApiaryWeb.Format

  @doc """
  The Submissions frame: the rows (`Apiary.Submissions.list/4`), newest first, in a frame
  of a stage's tab. A row has `:path`, the address of its run's page, nil for none, set by
  the page where the reader may read runs. The first row's commits are open.

  `names` is the integration name that draws each system (`Apiary.Submissions.system_names/2`),
  and `stage_names` the process version's stage names by id.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :open, :boolean, default: true, doc: "whether the frame is open"
  attr :names, :map, default: %{}
  attr :stage_names, :map, default: %{}
  attr :now, :any, default: nil

  def frame(assigns) do
    assigns = assign(assigns, now: assigns.now || DateTime.utc_now())

    ~H"""
    <section id={@id} class="q-xp-frame" aria-labelledby={"#{@id}-h"}>
      <details
        id={"#{@id}-fold"}
        class="q-xp-frame-fold"
        open={@open}
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <summary id={"#{@id}-s"}>
          <div class="q-xp-frame-h">
            <.icon name="hero-chevron-right-micro" class="q-xp-chev q-xp-frame-i size-4" />
            <h2 id={"#{@id}-h"} class="q-xp-frame-t">{gettext("Submissions")}</h2>
          </div>
          <p class="q-xp-cap">
            <.icon name="hero-information-circle-micro" class="q-xp-cap-i size-3.5" />
            <span>{gettext("Newest first")}</span>
          </p>
        </summary>
        <div class="q-xp-body">
          <div id={"#{@id}-list"} class="q-artifact-list">
            <ul class="grid gap-2">
              <.submission
                :for={{row, place} <- Enum.with_index(@rows)}
                id={"#{@id}-#{row.id}"}
                row={row}
                names={@names}
                open={place == 0}
              >
                <:head>
                  <a :if={row.path} href={row.path} class="font-medium text-accent">
                    {run_words(row)}
                  </a>
                  <span :if={!row.path} class="font-medium">{run_words(row)}</span>
                  <span class="min-w-0 text-[12.5px]/5 text-muted [overflow-wrap:anywhere]">
                    {when_words(row, @stage_names, @now)}
                  </span>
                </:head>
              </.submission>
            </ul>
          </div>
        </div>
      </details>
    </section>
    """
  end

  @doc """
  The Submission block of a run's page, under the version list of Save the outputs: the
  heading `<Type> v<number>` and the row of the version (`Apiary.Submissions.for_run/3`),
  with its commits open.
  """
  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :type, :string, required: true, doc: "the submission type's name"
  attr :names, :map, default: %{}

  def block(assigns) do
    ~H"""
    <div id={@id} class="q-artifact-list">
      <ul class="grid gap-2">
        <.submission id={"#{@id}-row"} row={@row} names={@names} open>
          <:head>
            <span class="font-medium">
              {gettext("%{type} v%{number}", type: capital(@type), number: @row.number)}
            </span>
          </:head>
        </.submission>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :names, :map, required: true
  attr :open, :boolean, required: true, doc: "whether the commits of the row are open"
  slot :head, required: true

  # One submission: its first line, then for each repository the branch, the commits and
  # the draft, with a sentence where the run sent no draft. A repository's path comes first
  # when the submission has more than one.
  defp submission(assigns) do
    ~H"""
    <li id={@id} class="grid gap-0.5 border-b border-base-300 pb-2 last:border-b-0">
      <div class="flex flex-wrap items-baseline gap-x-2">
        {render_slot(@head)}
        <.badge :if={@row.approved} color="success" class="q-wi-badge">
          {gettext("Approved")}
        </.badge>
      </div>
      <.repository
        :for={{repository, place} <- Enum.with_index(@row.repositories)}
        id={"#{@id}-r#{place}"}
        row={@row}
        repository={repository}
        names={@names}
        open={@open}
        named={length(@row.repositories) > 1}
      />
    </li>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :repository, :map, required: true
  attr :names, :map, required: true
  attr :open, :boolean, required: true
  attr :named, :boolean, required: true

  defp repository(assigns) do
    ~H"""
    <p
      :if={@named}
      id={"#{@id}-path"}
      class="min-w-0 text-[12.5px]/5 text-muted [overflow-wrap:anywhere]"
    >
      <.external_text text={@repository.path} />
    </p>
    <dl class="q-prep-facts">
      <dt>{gettext("Reference")}</dt>
      <dd id={"#{@id}-branch"}>
        <span :if={@row.ref} class="font-mono"><.external_text text={@row.ref} /></span>
        <span :if={@row.ref}> · </span>
        <.commit url={@repository.url} short={@repository.short} />
      </dd>
      <dt :if={@repository.base != nil or @repository.commits != []}>{gettext("Revisions")}</dt>
      <dd :if={@repository.base != nil or @repository.commits != []} id={"#{@id}-commits"}>
        <details
          id={"#{@id}-fold"}
          class="q-sub-fold"
          open={@open}
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="flex items-center gap-1 cursor-pointer">
            <.icon name="hero-chevron-right-micro" class="q-sub-chev size-3.5 text-muted" />
            <span>
              {ngettext("%{number} revision", "%{number} revisions", @repository.count,
                number: Format.number(@repository.count)
              )}
            </span>
          </summary>
          <ol class="grid gap-0.5 mt-1">
            <li
              :if={@repository.base}
              id={"#{@id}-base"}
              class="flex flex-wrap items-baseline gap-x-2"
            >
              <.commit url={@repository.base.url} short={@repository.base.short} />
              <span :if={base_words(@repository.base.line)} class="text-muted">
                {base_words(@repository.base.line)}
              </span>
            </li>
            <li
              :for={{entry, place} <- Enum.with_index(@repository.commits)}
              id={"#{@id}-c#{place}"}
              class="flex flex-wrap items-baseline gap-x-2"
            >
              <.commit url={entry.url} short={entry.short} />
              <span :if={step_words(entry.step)}>{step_words(entry.step)}</span>
              <.badge :if={entry.head} color="info">{gettext("Head")}</.badge>
            </li>
          </ol>
        </details>
      </dd>
      <dt :if={match?({:draft, _draft}, @repository.draft)}>{gettext("Draft")}</dt>
      <dd :if={match?({:draft, _draft}, @repository.draft)} id={"#{@id}-draft"}>
        <.draft draft={elem(@repository.draft, 1)} mark={mark(@repository, @names)} />
      </dd>
    </dl>
    <p :if={@repository.draft == :none} id={"#{@id}-no-draft"} class="text-[12.5px]/5 text-muted">
      {gettext("The run sent no draft to the destination.")}
    </p>
    """
  end

  attr :url, :any, default: nil
  attr :short, :string, required: true

  # A commit's short id, a link where the submission has its address.
  defp commit(assigns) do
    ~H"""
    <a
      :if={@url}
      href={@url}
      target="_blank"
      rel="noopener noreferrer nofollow"
      class="text-accent font-mono"
    >
      {@short}
    </a>
    <span :if={!@url} class="font-mono">{@short}</span>
    """
  end

  attr :draft, :map, required: true
  attr :mark, :string, required: true

  # A draft: its system's mark beside its number, a link where the submission has its
  # address.
  defp draft(assigns) do
    title = Apiary.ExternalText.present(assigns.draft.title)

    words =
      if title,
        do: gettext("#%{number} “%{title}”", number: assigns.draft.number, title: title),
        else: "#" <> Integer.to_string(assigns.draft.number)

    assigns = assign(assigns, words: words)

    ~H"""
    <span class="inline-flex flex-wrap items-baseline gap-x-1.5">
      <BacklogComponents.integration_tile name={@mark} class="q-bl-mk" />
      <a
        :if={@draft.url}
        href={@draft.url}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="text-accent"
      >
        {@words}
      </a>
      <span :if={!@draft.url}>{@words}</span>
    </span>
    """
  end

  # The mark of a draft's system: the integration that draws it, else the system's own name,
  # as text sent by an external system.
  defp mark(%{system: system}, names) do
    Apiary.ExternalText.sent(Map.get(names, system) || system) || "?"
  end

  defp run_words(%{run: number}) when is_integer(number),
    do: gettext("Run %{run}", run: number)

  defp run_words(_row), do: gettext("A run")

  # The stage and the time the run ended: "Build · Today, 14:30".
  defp when_words(row, stage_names, now) do
    at = at_words(row.at, now)

    case Map.get(stage_names, row.stage_id) do
      nil -> at
      stage -> "#{stage} · #{at}"
    end
  end

  defp at_words(at, now) do
    case Format.days_back(at, now) do
      0 -> gettext("Today, %{time}", time: Format.time(at))
      1 -> gettext("Yesterday, %{time}", time: Format.time(at))
      _other -> Format.datetime(at)
    end
  end

  defp base_words({:head, run}), do: gettext("Base: the head of Run %{run}", run: run)
  defp base_words(:start), do: gettext("Base: where the work starts")
  defp base_words(:unknown), do: nil

  defp step_words({:change, id, nil}), do: Apiary.ExternalText.line(id)

  defp step_words({:change, id, change}),
    do: gettext("%{id} · %{change}", id: Apiary.ExternalText.line(id), change: external(change))

  defp step_words({:fix, finding}),
    do: gettext("Fix of review finding %{finding}", finding: Apiary.ExternalText.line(finding))

  defp step_words(nil), do: nil

  defp external(text), do: Apiary.ExternalText.sent(text) || ""

  # A type's name as a heading: "submission" is "Submission".
  defp capital(type) do
    {first, rest} =
      type |> ApiaryWeb.WorkItemLive.StageComponents.type_words() |> String.split_at(1)

    String.upcase(first) <> rest
  end
end
