defmodule ApiaryWeb.TargetComponents do
  @moduledoc """
  The components of the targets' pages (`ApiaryWeb.TargetLive.Index`,
  `ApiaryWeb.TargetLive.Show`), and the two every page that names a target or a run's
  state shares: the target's notation and the state's mark.

  **The notation.** A target is its path in mono; its system goes before it, faint, only
  where the same path is in more than one system of the workspace
  (`Apiary.Runs.shared_paths/2`), its own header included. In words, in titles, labels
  and toasts, it is named the same way (`target_label/3`).

  **The address** follows the notation (question 9, answer A): `target_path/5` is where a
  target's page is, its path alone, `/:org/:workspace/targets/acme/shop`, and its system
  before the path only where the path is shared, `…/targets/gitlab.com/acme/shop`; its
  tabs follow a `-` segment (`…/-/policy`), GitLab's way, so no tab can be taken for a
  part of a path. A caller that cannot tell whether the path is shared writes the path
  alone: the page there lists the targets that share it.

  **A run's state** is a dot and, when the run needs a look, a word: running, failed,
  timed out, lost and pending say so; a run that ended well, or was closed, is the dot
  alone, its word for a screen reader. Never a pill.

  What Forager reported is untrusted: it is interpolated, never passed to `raw/1`.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope

  @typedoc """
  Whether a target's path is shared by another target of the workspace: a boolean, or the
  workspace's shared paths (`Apiary.Runs.shared_paths/2`).
  """
  @type shared :: boolean | MapSet.t(String.t())

  @doc """
  target_path/5 is the path of a target's page in the scope's workspace: its path alone,
  `…/targets/acme/shop`, or, where the path is `shared` by another target of the
  workspace, its system before it, `…/targets/gitlab.com/acme/shop` (question 9, answer
  A). `rest` is the segments of a tab after `-` (`["policy"]`, `["policy", "history"]`),
  none for its Overview. A nil system writes the path alone, whatever `shared` says.

  The path's segments are the target's own, each escaped, unless one of them is empty,
  `-`, `.` or `..`: then the path is one segment, its slashes escaped, so a segment of it
  is never read as the tab's separator or as a step up.

  For compatibility, `target_path/5` given an organisation and a workspace in place of
  the scope is `target_path/6` with `shared` false.
  """
  @spec target_path(Scope.t(), String.t() | nil, String.t(), [String.t()], shared) ::
          String.t()
  def target_path(scope, system, path, rest \\ [], shared \\ false)

  def target_path(
        %Scope{organisation: organisation, workspace: workspace},
        system,
        path,
        rest,
        shared
      ),
      do: target_path(organisation, workspace, system, path, rest, shared)

  def target_path(organisation, workspace, system, path, rest) when is_list(rest),
    do: target_path(organisation, workspace, system, path, rest, false)

  @doc "target_path/6 is `target_path/5` with the organisation and the workspace given."
  @spec target_path(term, term, String.t() | nil, String.t(), [String.t()], shared) ::
          String.t()
  def target_path(organisation, workspace, system, path, rest, shared) do
    segments =
      if(with_system?(system, path, shared), do: [system], else: []) ++
        path_segments(path) ++ if(rest == [], do: [], else: ["-" | rest])

    ~p"/#{organisation}/#{workspace}/targets/#{segments}"
  end

  @doc """
  target_label/3 is a target's name in words, as titles, headings, breadcrumbs, labels and
  toasts write it: named as it is addressed, its path alone, `acme/shop`, and its system
  before the path only where the path is `shared` by another target of the workspace,
  `gitlab.com/acme/shop`. A nil system writes the path alone. The exported policy file
  keeps the full name.
  """
  @spec target_label(String.t() | nil, String.t(), shared | nil) :: String.t()
  def target_label(system, path, shared) when is_binary(path) do
    if with_system?(system, path, shared), do: "#{system}/#{path}", else: path
  end

  @doc """
  with_system?/3 is the one test of a target's address (`target_path/6`) and its name
  (`target_label/3`, `ApiaryWeb.RunComponents.target_name/1`): whether both carry the
  system, which they do together or not at all. They do where `shared` says the path alone
  would not name the target alone: `true`, as a target's page passes it where its path is
  shared or reads as another target's system and path, or the workspace's shared paths
  holding the path. A nil system never does.
  """
  @spec with_system?(String.t() | nil, String.t(), shared | nil) :: boolean
  def with_system?(system, path, shared), do: is_binary(system) and shared?(shared, path)

  @doc """
  shared?/2 says whether `path` is shared by `shared`, a boolean or the workspace's shared
  paths (`Apiary.Runs.shared_paths/2`).
  """
  @spec shared?(shared | nil, String.t()) :: boolean
  def shared?(true, _path), do: true
  def shared?(%MapSet{} = shared, path), do: MapSet.member?(shared, path)
  def shared?(_shared, _path), do: false

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
  sends `pin` with the target's id. Its spoken name names the target as it is addressed
  (`target_label/3`): its system too only where its path is `shared`.
  """
  attr :id, :string, required: true
  attr :target, :map, required: true
  attr :pinned, :boolean, required: true
  attr :label, :boolean, default: false, doc: "the word beside the star, as a header has it"
  attr :shared, :any, default: false, doc: "whether the target's path is shared (`t:shared/0`)"
  attr :class, :any, default: nil

  def pin_button(assigns) do
    %{target: target, shared: shared} = assigns
    assigns = assign(assigns, :name, target_label(target.system, target.path, shared))

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
              do: gettext("Unpin %{target}", target: @name),
              else: gettext("Pin %{target}", target: @name)
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
  (`ApiaryWeb.RunComponents.given_title/1`, else the run's short id), the runtime and the
  host, faint, when it started, how long it took and its denied attempts. The target is
  the page's, so the row leaves it out.
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
          <.run_name run={run} />
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
