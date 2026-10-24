defmodule ApiaryWeb.TargetComponents do
  @moduledoc """
  The components of the targets' pages (`ApiaryWeb.TargetLive.Index`,
  `ApiaryWeb.TargetLive.Show`), and the two every page that names a target or a run's
  state shares: the target's notation and the state's mark.

  **The notation.** A target is its path in mono; its system goes before it, faint, only
  where the same path is in more than one system of the workspace
  (`Apiary.Runs.shared_paths/2`), the header of the target's page included. In words, in
  titles, labels and toasts, it is named the same way (`target_label/3`).

  **The address** is the target's public id, Qory Apiary's id for it (`tg_…`,
  `Apiary.Runs.Target`): `target_path/3` is where a target's page is,
  `/:org/:workspace/targets/tg_…`, and its tabs follow it (`…/tg_…/policy`). The system
  and the path, Forager's labels, name the target; they never address it.

  **A run's state** is a dot and, when the run needs a look, a word: running, failed,
  timed out, lost and pending say so; a run that ended well is the dot alone, its word
  for a screen reader. Never a pill.

  What Forager reported is untrusted: it is interpolated, never passed to `raw/1`.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope

  @typedoc """
  Whether a target's path is shared by another target of the workspace: a boolean, or the
  workspace's shared paths (`Apiary.Runs.shared_paths/2`).
  """
  @type shared :: boolean | MapSet.t(String.t())

  @typedoc "A target as `target_path/3` takes it: anything with its public id, or the id."
  @type addressed :: %{required(:public_id) => String.t(), optional(atom) => term} | String.t()

  @doc """
  target_path/3 is the path of a target's page in the scope's workspace, by the target's
  public id: `…/targets/tg_…`. `target` is the target, anything with its `public_id`, or
  the id itself. `rest` is the segments of a tab (`["policy"]`, `["policy", "history"]`),
  none for its Overview.
  """
  @spec target_path(Scope.t(), addressed, [String.t()]) :: String.t()
  def target_path(%Scope{organisation: organisation, workspace: workspace}, target, rest \\ []),
    do: target_path(organisation, workspace, target, rest)

  @doc "target_path/4 is `target_path/3` with the organisation and the workspace given."
  @spec target_path(term, term, addressed, [String.t()]) :: String.t()
  def target_path(organisation, workspace, target, rest) when is_list(rest),
    do: ~p"/#{organisation}/#{workspace}/targets/#{[public_id(target) | rest]}"

  defp public_id(%{public_id: id}) when is_binary(id), do: id
  defp public_id(id) when is_binary(id), do: id

  @doc """
  target_label/3 is a target's name in words, as titles, headings, breadcrumbs, labels and
  toasts write it: its path alone, `acme/shop`, and its system before the path only where
  the path is `shared` by another target of the workspace,
  `git.example/acme/shop`. A nil system writes the path alone. The exported policy file
  keeps the full name.

  The system and the path are texts Forager sent: each is written as a page shows one
  (`Apiary.ExternalText.present/1`), or marked (`Apiary.ExternalText.marked/1`) where
  nothing is left of it, while what decides whether the system is written is the path as
  sent. The name is words to read, never a value to match or address a target by.
  """
  @spec target_label(String.t() | nil, String.t(), shared | nil) :: String.t()
  def target_label(system, path, shared) when is_binary(path) do
    if with_system?(system, path, shared),
      do: "#{shown_sent(system)}/#{shown_sent(path)}",
      else: shown_sent(path)
  end

  # A text Forager sent, as `target_label/3` and a run's row write it: as a page shows one,
  # or marked where nothing is left of it, since it was sent; "" stays "", and nil nil.
  defp shown_sent(text) when is_binary(text) and text != "",
    do: Apiary.ExternalText.present(text) || Apiary.ExternalText.marked(text)

  defp shown_sent(text), do: text

  @doc """
  with_system?/3 is the one test of a target's name (`target_label/3`,
  `ApiaryWeb.RunComponents.target_name/1`): whether it carries the system. It does where
  `shared` says the path alone would not name the target alone: `true`, as a target's
  page passes it where its path is shared, or the workspace's shared paths holding the
  path. A nil system never does.
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
  A run's state as a dot and its word (pending, running, failed, cancelled, lost); the dot
  alone for one that completed, its word there for a screen reader. `word` forces the word,
  as a header does.
  """
  attr :state, :string, required: true, values: Apiary.Runs.Run.states()
  attr :word, :boolean, default: false, doc: "show the word whatever the state"
  attr :class, :any, default: nil
  attr :rest, :global

  def state_mark(assigns) do
    assigns =
      assign(
        assigns,
        :quiet,
        assigns.state == "completed" and !assigns.word
      )

    ~H"""
    <span class={["q-sdot", "q-sdot-#{@state}", @class]} {@rest}>
      <i aria-hidden="true"></i><span class={@quiet && "sr-only"}>{state_label(@state)}</span>
    </span>
    """
  end

  @doc """
  The star that pins a target for the reader, or takes the pin away: a toggle button that
  sends `pin` with the target's id. Its spoken name names the target in its notation
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
          navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{run.public_id}"}
          class="q-tgt-title"
        >
          <.run_name run={run} />
        </.link>
      </:col>
      <:col :let={run} label={gettext("Runtime")} kind="faint" from="md" class="whitespace-nowrap">
        <.external_text text={shown_sent(run.runtime)} />
        <.external_text text={shown_sent(run.runtime_version)} />
      </:col>
      <:col :let={run} label={gettext("Host")} kind="faint" from="md" class="whitespace-nowrap">
        <%= case place_of(run) do %>
          <% {:pool, name} -> %>
            <span>{name}</span>
          <% {:host, host} -> %>
            <span class="q-mono"><.external_text text={shown_sent(host)} /></span>
          <% nil -> %>
            <span class="q-mono"></span>
        <% end %>
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
