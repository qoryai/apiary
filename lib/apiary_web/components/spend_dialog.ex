defmodule ApiaryWeb.SpendDialog do
  # The confirmation before an action that spends: one that starts a run, which uses a
  # machine and model tokens, or a build machine. The action's click opens a dialog over
  # the page, with the action's name as a question, one line on what starts, the
  # action's fields where it has them, and Cancel and the action's name. Only the
  # confirm button acts.
  #
  # **The page's part.** A page keeps the open confirmation in its `:spend` assign, nil
  # while none is open. Where a click starts a run, the page assigns `ask/3`'s map and
  # does nothing else; `dialog/1` draws it. The confirm button sends `"spend_confirm"`
  # with the dialog's fields: the page takes the map (`take/2`), sets `:spend` to nil
  # first, and acts with the action's event and the click's params, the dialog's fields
  # put over them. A second `"spend_confirm"` finds `:spend` nil and does nothing, so a
  # double click starts one run. `"spend_cancel"` sets `:spend` to nil and changes
  # nothing else; the page's fields keep what the reader typed.
  #
  # **The dialog** is a native `<dialog>` opened modal by the `SpendDialog` hook
  # (`assets/js/hooks/spend_dialog.js`): the page under it is inert, so focus stays in
  # it. Focus goes to Cancel, not to the confirm button, where an Enter held down from
  # the action's button would confirm at once; with `focus` set, it goes to that element
  # (`data-focus`). Focus goes back to the action's button (`return_to`) when the dialog
  # closes. Escape and a click outside the box send `"spend_cancel"`.
  # LiveView disables the confirm button while its submit is in flight.
  #
  # `frame/1` is the dialog with any body and width, for an action whose confirmation
  # shows more than a line and a note. With a `side`, it is the wide dialog: a box almost
  # as tall as the window, a head with the title and a close button (×), a body edge to
  # edge whose two columns, the body and the side, scroll apart, and a foot with a line
  # beside the buttons (`foot_line`). Its focus opens on Cancel, as for any dialog, or
  # on the element whose id is `focus`. With a `body_label`, its first column is a region with that name for a screen
  # reader; without one, a plain block.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Organisations.Workspace
  alias Apiary.WorkspaceSetup

  @note_units 2 * 2_000

  # The box's distance from the top of the page, in px, as in the approved pictures.
  @top 170

  @typedoc """
  An open confirmation: the action's `event` and the `params` of its click, the dialog's
  `title` and `action` (the confirm button's words), its `line`, rich text, the id of the
  action's button (`return_to`), the action's note, or nil for none, and the box's
  distance from the top of the page in px (`top`).
  """
  @type t :: %{
          event: String.t(),
          params: map,
          title: String.t(),
          action: String.t(),
          line: term,
          return_to: String.t() | nil,
          top: pos_integer,
          note: nil | %{value: String.t(), optional: boolean, hint: String.t() | nil}
        }

  # ask/3 is the confirmation of `event`, sent with `params`; `opts` has `:title`,
  # `:action`, `:line` and `:return_to`, and `:note` for an action with a note: the
  # dialog then shows the note's field with `params["note"]`, and `optional` and `hint`
  # as set in `:note`; `:top` for a box at another distance from the top than 170 px.
  @doc false
  @spec ask(String.t(), map, keyword) :: t
  def ask(event, params, opts) do
    note =
      case Keyword.get(opts, :note) do
        nil ->
          nil

        note ->
          %{
            value: note_value(params["note"]),
            optional: Keyword.get(note, :optional, true),
            hint: Keyword.get(note, :hint)
          }
      end

    %{
      event: event,
      params: params,
      title: Keyword.fetch!(opts, :title),
      action: Keyword.fetch!(opts, :action),
      line: Keyword.fetch!(opts, :line),
      return_to: Keyword.get(opts, :return_to),
      top: top(Keyword.get(opts, :top, @top)),
      note: note
    }
  end

  # `:top` of `ask/3`: an integer of px; any other value raises.
  defp top(top) when is_integer(top), do: top

  defp top(other),
    do: raise(ArgumentError, "Pass :top to ask/3 as an integer of px, not #{inspect(other)}.")

  defp note_value(value) when is_binary(value), do: value
  defp note_value(_value), do: ""

  # take/2 is the open confirmation's event and the params to act with: the click's,
  # with the dialog's note over them where the dialog has a note field; nil while no
  # confirmation is open.
  @doc false
  @spec take(t | nil, map) :: {String.t(), map} | nil
  def take(nil, _params), do: nil

  def take(%{event: event, params: params, note: nil}, _dialog), do: {event, params}

  def take(%{event: event, params: params}, dialog),
    do: {event, Map.put(params, "note", note_value(dialog["note"]))}

  ## The lines

  # run_line/2 is what a run starts: `{:workflow, name}` where the code knows the
  # run's workflow, else `{:stage, name}`, the stage whose next run it is; on a machine
  # of the workspace's one serving pool, by its name, or of a pool in the workspace.
  @doc false
  @spec run_line({:workflow | :stage, String.t()}, Workspace.t()) :: term
  def run_line({:workflow, workflow}, %Workspace{} = workspace) do
    rich_gettext("Starts a run of %{workflow} on %{machine}. The run uses model tokens.",
      workflow: {:m, workflow},
      machine: machine(workspace)
    )
  end

  def run_line({:stage, stage}, %Workspace{} = workspace) do
    gettext("Starts the next run of %{stage} on %{machine}. The run uses model tokens.",
      stage: stage,
      machine: machine(workspace)
    )
  end

  # take_in_line/3 is what a take in starts, said with the action's name (`action`, the
  # confirm button's words), from what `Apiary.Stages.take_in_starts/2` reads: a run of
  # `workflow`, or a run with no workflow named for nil, on a machine, in the words of
  # `run_line/2`; nil where the take in starts no run, so the foot has no line.
  @doc false
  @spec take_in_line(String.t(), {:run, String.t() | nil} | :none, Workspace.t()) ::
          term | nil
  def take_in_line(action, {:run, workflow}, %Workspace{} = workspace)
      when is_binary(workflow) do
    rich_gettext(
      "%{action} starts a run of %{workflow} on %{machine}. The run uses model tokens.",
      action: action,
      workflow: {:m, workflow},
      machine: machine(workspace)
    )
  end

  def take_in_line(action, {:run, nil}, %Workspace{} = workspace) do
    gettext("%{action} starts a run on %{machine}. The run uses model tokens.",
      action: action,
      machine: machine(workspace)
    )
  end

  def take_in_line(_action, :none, %Workspace{}), do: nil

  # test_line/1 is what the set-up's Run the test starts: a run of the harness built in.
  @doc false
  @spec test_line(Workspace.t()) :: String.t()
  def test_line(%Workspace{} = workspace) do
    gettext("Starts a run of qory's hello example on %{machine}. The run uses model tokens.",
      machine: machine(workspace)
    )
  end

  # build_line/1 is what a target's Rebuild starts: a build for each pool of the
  # target's workspace. A build uses no model.
  @doc false
  @spec build_line(Workspace.t()) :: String.t()
  def build_line(%Workspace{name: name}),
    do: gettext("Starts one build machine per pool of %{workspace}.", workspace: name)

  # The machine a run takes: of the one pool that serves the workspace's runs
  # (`Apiary.WorkspaceSetup.serving_pools/1`), by its name; with more than one, of a pool
  # in the workspace; with none, a machine with no pool.
  defp machine(%Workspace{} = workspace) do
    case WorkspaceSetup.serving_pools(workspace) do
      [] -> gettext("a machine")
      [%{name: name}] when is_binary(name) -> gettext("a machine of %{pool}", pool: name)
      _more -> gettext("a machine of a pool in %{workspace}", workspace: workspace.name)
    end
  end

  ## The dialog

  attr :spend, :map, required: true, doc: "the open confirmation (`ask/3`)"
  attr :id, :string, default: "spend-dialog"

  # The open confirmation: its line, then the action's note, where it has one.
  @doc false
  def dialog(assigns) do
    ~H"""
    <.frame
      id={@id}
      title={@spend.title}
      action={@spend.action}
      return_to={@spend.return_to}
      describedby={"#{@id}-line"}
      top={@spend.top}
    >
      <p id={"#{@id}-line"}><.rich text={@spend.line} /></p>
      <.input
        :if={@spend.note}
        id={"#{@id}-note"}
        name="note"
        type="textarea"
        value={@spend.note.value}
        label={gettext("Note")}
        optional={@spend.note.optional}
        hint={@spend.note.hint}
        rows="3"
        maxlength={note_units()}
      />
    </.frame>
    """
  end

  defp note_units, do: @note_units

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :action, :string, required: true, doc: "the confirm button's words: the action's name"

  attr :return_to, :string,
    default: nil,
    doc: "the id of the action's button, which takes the focus back"

  attr :top, :integer,
    default: @top,
    doc: "the box's distance from the top of the page, in px"

  attr :describedby, :string,
    default: nil,
    doc: "the id of the line on what starts, which a screen reader reads with the title"

  attr :width, :string, default: nil, doc: "the box's CSS width; 500 px wide, or less, unless set"
  attr :confirm, :string, default: "spend_confirm", doc: "the event the confirm button sends"
  attr :cancel, :string, default: "spend_cancel", doc: "the event Cancel sends"

  attr :change, :string,
    default: nil,
    doc: "the event the form sends as its fields change; none unless set"

  attr :focus, :string,
    default: nil,
    doc: "the id of the element that takes the focus as the dialog opens; Cancel's unless set"

  slot :inner_block, required: true, doc: "the body: what starts, and the action's fields"

  attr :body_label, :string,
    default: nil,
    doc:
      "the wide dialog's name of its first column, the body, for a screen reader; nil makes the column no region"

  slot :side, doc: "the wide dialog's second column, beside the body"
  slot :foot_line, doc: "the wide dialog's line beside the buttons: what starts"

  # The dialog with any body, as `dialog/1` fills it; with a `side`, the wide dialog.
  @doc false
  def frame(%{side: [_ | _]} = assigns) do
    ~H"""
    <dialog
      id={@id}
      class="q-spend q-spend-wide"
      style={"padding-top: #{Integer.to_string(@top)}px"}
      aria-labelledby={"#{@id}-title"}
      aria-describedby={@describedby}
      phx-hook="SpendDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      phx-window-keydown={@cancel}
      phx-key="Escape"
      data-return={@return_to}
      data-focus={@focus || "#{@id}-cancel"}
    >
      <form
        id={"#{@id}-form"}
        class="q-spend-box"
        style={@width && "width: min(#{@width}, 100%)"}
        phx-submit={@confirm}
        phx-change={@change}
        phx-click-away={@cancel}
        novalidate
      >
        <div class="q-spend-head">
          <h2 id={"#{@id}-title"} class="q-spend-t">{@title}</h2>
          <.button
            id={"#{@id}-close"}
            type="button"
            variant="ghost"
            class="btn-square"
            phx-click={@cancel}
            aria-label={gettext("Close")}
            title={gettext("Close")}
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" />
          </.button>
        </div>
        <div class="q-spend-cols">
          <div class="q-spend-col" role={@body_label && "region"} aria-label={@body_label}>
            {render_slot(@inner_block)}
          </div>
          <div class="q-spend-col q-spend-side">{render_slot(@side)}</div>
        </div>
        <div class="q-spend-foot">
          <p :if={@foot_line != []} id={"#{@id}-line"} class="q-spend-line">
            {render_slot(@foot_line)}
          </p>
          <.button id={"#{@id}-cancel"} type="button" phx-click={@cancel}>
            {gettext("Cancel")}
          </.button>
          <.button id={"#{@id}-go"} type="submit" variant="primary">{@action}</.button>
        </div>
      </form>
    </dialog>
    """
  end

  def frame(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="q-spend"
      style={"padding-top: #{Integer.to_string(@top)}px"}
      aria-labelledby={"#{@id}-title"}
      aria-describedby={@describedby}
      phx-hook="SpendDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      phx-window-keydown={@cancel}
      phx-key="Escape"
      data-return={@return_to}
      data-focus={@focus || "#{@id}-cancel"}
    >
      <form
        id={"#{@id}-form"}
        class="q-spend-box"
        style={@width && "width: min(#{@width}, 100%)"}
        phx-submit={@confirm}
        phx-click-away={@cancel}
        novalidate
      >
        <h2 id={"#{@id}-title"} class="q-spend-t">{@title}</h2>
        <div class="q-spend-body">{render_slot(@inner_block)}</div>
        <div class="q-spend-foot">
          <.button id={"#{@id}-cancel"} type="button" phx-click={@cancel}>
            {gettext("Cancel")}
          </.button>
          <.button id={"#{@id}-go"} type="submit" variant="primary">{@action}</.button>
        </div>
      </form>
    </dialog>
    """
  end
end
