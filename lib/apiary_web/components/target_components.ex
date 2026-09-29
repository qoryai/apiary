defmodule ApiaryWeb.TargetComponents do
  @moduledoc """
  The components of the targets' pages (`ApiaryWeb.TargetLive.Index`,
  `ApiaryWeb.TargetLive.Show`), and the two every page that names a target or a run's
  state shares: the target's notation and the state's mark.

  **The notation.** A target is its path in mono; its system goes before it, faint, only
  where the same path is in more than one system of the workspace
  (`Apiary.Targets.shared_paths/2`) and on the target's own header. `target_path/4` is
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
  def target_path(%Scope{organisation: organisation, workspace: workspace}, system, path, rest \\ []),
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
  given. The caller decides whether it is (`Apiary.Targets.shared_paths/2`).
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
end
