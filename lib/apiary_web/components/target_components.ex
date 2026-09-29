defmodule ApiaryWeb.TargetComponents do
  @moduledoc """
  The components of the targets' pages (`ApiaryWeb.TargetLive.Index`,
  `ApiaryWeb.TargetLive.Show`), and the two every page that names a target or a run's
  state shares: the target's notation and the state's mark.

  **The notation.** A target is its path in mono; its system goes before it, faint, only
  where the same path is in more than one system of the workspace
  (`Apiary.Runs.shared_paths/2`) and on the target's own header. `target_path/4` is
  where a target's page is: `/:org/:workspace/targets/:system/*path`, its tabs after a
  `-` segment (`…/-/runs`), GitLab's way, so no tab can be taken for a part of a path.

  **A run's state** is a dot and, when the run needs a look, a word: running, failed,
  timed out, lost and pending say so; a run that ended well, or was closed, is the dot
  alone, its word for a screen reader. Never a pill.

  What a runner reported is untrusted: it is interpolated, never passed to `raw/1`.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope

  @doc """
  target_path/4 is the path of a target's page in the scope's workspace, `rest` the
  segments of a tab after `-` (`["runs"]`, `["policy", "history"]`), none for its
  Overview. The path's segments are the target's own, each escaped, unless one of them is
  empty, `-`, `.` or `..`: then the path is one segment, its slashes escaped, so a
  segment of it is never read as the tab's separator or as a step up.
  """
  @spec target_path(Scope.t(), String.t(), String.t(), [String.t()]) :: String.t()
  def target_path(
        %Scope{organisation: organisation, workspace: workspace},
        system,
        path,
        rest \\ []
      ),
      do: target_path(organisation, workspace, system, path, rest)

  @doc "target_path/5 is `target_path/4` with the organisation and the workspace given."
  @spec target_path(term, term, String.t(), String.t(), [String.t()]) :: String.t()
  def target_path(organisation, workspace, system, path, rest) do
    segments = path_segments(path) ++ if(rest == [], do: [], else: ["-" | rest])
    ~p"/#{organisation}/#{workspace}/targets/#{system}/#{segments}"
  end

  @doc """
  path_segments/1 is the segments a target's path takes in its page's URL: its own, or
  the path whole when a segment of it would be misread (`target_path/4`).
  """
  @spec path_segments(String.t()) :: [String.t()]
  def path_segments(path) do
    segments = String.split(path, "/")
    if Enum.any?(segments, &(&1 in ["", "-", ".", ".."])), do: [path], else: segments
  end

  @doc """
  parse_glob/1 reads the glob of a target's page back: the path, and the segments of the
  tab after the first `-`. `path_segments/1` in reverse.
  """
  @spec parse_glob([String.t()]) :: {String.t(), [String.t()]}
  def parse_glob(glob) when is_list(glob) do
    {path, rest} = Enum.split_while(glob, &(&1 != "-"))
    {Enum.join(path, "/"), Enum.drop(rest, 1)}
  end

  @doc """
  A target in its notation: the path in mono, the system faint before it when `system` is
  given. The caller decides whether it is (`Apiary.Runs.shared_paths/2`).
  """
  attr :path, :string, required: true
  attr :system, :string, default: nil, doc: "shown before the path; nil leaves it out"
  attr :class, :any, default: nil
  attr :rest, :global

  def target_name(assigns) do
    ~H"""
    <span class={["q-tname", @class]} {@rest}><span :if={@system} class="q-tname-sys">{@system}<span class="q-tname-sep">/</span></span>{@path}</span>
    """
  end

  @doc """
  A run's state as a dot and, when the run needs a look, its word (running, pending,
  failed, timed out, lost); the dot alone for one that ended well or was closed, its word
  there for a screen reader. `word` forces the word, as a header does.
  """
  attr :state, :string, required: true, values: Apiary.Runs.Run.states()
  attr :word, :boolean, default: false, doc: "show the word whatever the state"
  attr :class, :any, default: nil
  attr :rest, :global

  def state_mark(assigns) do
    assigns = assign(assigns, :quiet, assigns.state in ~w(succeeded closed) and !assigns.word)

    ~H"""
    <span class={["q-sdot", "q-sdot-#{@state}", @class]} {@rest}>
      <i aria-hidden="true"></i><span class={@quiet && "sr-only"}>{state_label(@state)}</span>
    </span>
    """
  end

  @doc """
  The star that pins a target for the reader, or takes the pin away: a toggle button that
  sends `pin` with the target's id.
  """
  attr :id, :string, required: true
  attr :target, :map, required: true
  attr :pinned, :boolean, required: true
  attr :label, :boolean, default: false, doc: "the word beside the star, as a header has it"
  attr :class, :any, default: nil

  def pin_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="target_pin"
      phx-value-id={@target.id}
      aria-pressed={to_string(@pinned)}
      aria-label={
        if @label,
          do: nil,
          else:
            if(@pinned,
              do: gettext("Unpin %{target}", target: "#{@target.system}/#{@target.path}"),
              else: gettext("Pin %{target}", target: "#{@target.system}/#{@target.path}")
            )
      }
      class={[if(@label, do: "btn btn-sm q-tgt-pinbtn", else: "q-tgt-pin"), @class]}
    >
      <.icon
        name={if @pinned, do: "hero-star-solid", else: "hero-star"}
        class={if @label, do: "size-4 text-muted", else: "size-3.5"}
      />
      <span :if={@label}>{if @pinned, do: gettext("Pinned"), else: gettext("Pin")}</span>
    </button>
    """
  end

  @doc """
  The denied attempts of a row: the glyph and the number, red, when there are any;
  nothing otherwise.
  """
  attr :count, :integer, required: true
  attr :title, :string, default: nil

  def denied(assigns) do
    ~H"""
    <span :if={@count > 0} class="q-tgt-denied" title={@title}>
      <.icon name="hero-no-symbol-micro" class="size-3.5" />{Format.number(@count)}
    </span>
    """
  end

  @doc """
  A target's runs, one line each on the row spec (`<.table>`): the state's dot, the title
  (the task, or the run's id), the runtime and the host, faint, when it started, how long
  it took and its denied attempts. The target is the page's, so the row leaves it out.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :runs, :list, required: true
  attr :scope, :any, required: true
  attr :class, :any, default: nil

  def run_rows(assigns) do
    ~H"""
    <.table
      id={@id}
      label={@label}
      rows={@runs}
      row_id={&"#{@id}-#{&1.id}"}
      class={["q-tgt-runs", @class]}
    >
      <:col :let={run} label={gettext("State")} class="q-tgt-st">
        <.state_mark state={run.state} />
      </:col>
      <:col :let={run} label={gettext("Run")} kind="title" class="q-tgt-run">
        <.link
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{run.run_id}"}
          class="q-tgt-title"
        >
          {run.task || short_id(run.run_id)}
        </.link>
      </:col>
      <:col :let={run} label={gettext("Runtime")} kind="faint" from="md" class="whitespace-nowrap">
        {Enum.join(Enum.reject([run.runtime, run.runtime_version], &is_nil/1), " ")}
      </:col>
      <:col :let={run} label={gettext("Host")} kind="faint" from="md" class="whitespace-nowrap">
        <span class="q-mono">{run.host}</span>
      </:col>
      <:col :let={run} label={gettext("Started")} class="whitespace-nowrap">
        <.relative_time at={run.started_at || run.inserted_at} />
      </:col>
      <:col :let={run} label={gettext("Duration")} kind="num" from="sm" class="whitespace-nowrap">
        <.duration :if={run.state in Apiary.Runs.Run.alive_states()} {alive_clock(run)} />
        <.duration :if={run.state not in Apiary.Runs.Run.alive_states()} ms={run.duration_ms} />
      </:col>
      <:col :let={run} label={gettext("Denied")} kind="num">
        <.denied
          count={run.denied_count}
          title={
            ngettext("%{number} denied attempt", "%{number} denied attempts", run.denied_count,
              number: Format.number(run.denied_count)
            )
          }
        />
      </:col>
    </.table>
    """
  end

  defp alive_clock(run) do
    {seconds, at} = elapsed(run)
    %{elapsed_seconds: seconds, elapsed_at: at}
  end
end
