defmodule ApiaryWeb.RunCancelComponents do
  @moduledoc """
  A member's cancel of a running run (`Apiary.Runs.cancel/2`), as the run page and the work
  item page show it: the **Cancel run** button, its inline confirm, "Cancelling" in the
  place of the run's state until its exit, and the line after the exit.
  """

  use ApiaryWeb, :html

  alias Apiary.Runs.Run
  alias ApiaryWeb.Format

  @doc """
  The **Cancel run** button, which opens the inline confirm (`event`, with `values` as
  the click's values).
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :values, :map, default: %{}
  attr :class, :any, default: nil

  def cancel_button(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      size="xs"
      class={@class}
      phx-click={JS.push(@event, value: @values)}
    >
      {gettext("Cancel run")}
    </.button>
    """
  end

  @doc """
  The inline confirm of the cancel of run `number`: its question, what happens, and for a
  run that writes changes its end pushes (`write`), that they are not pushed. **Cancel
  run** sends `event` with `values`; **Keep running** runs `keep`.
  """
  attr :id, :string, required: true
  attr :number, :integer, required: true
  attr :write, :boolean, default: false
  attr :event, :string, required: true
  attr :values, :map, default: %{}
  attr :keep, :any, required: true, doc: "a JS command that closes the confirm"
  attr :class, :any, default: nil

  def cancel_confirm(assigns) do
    ~H"""
    <.inline_confirm
      id={@id}
      class={@class}
      question={gettext("Cancel run %{number}?", number: @number)}
      cancel={@keep}
      cancel_label={gettext("Keep running")}
    >
      {gettext(
        "The agent stops at its next report to Qory Apiary, and the run changes nothing more. What it already sent stays, marked as from a cancelled run."
      )}
      <span :if={@write}>
        {gettext("Its changes are not pushed, unless the run had already started pushing them.")}
      </span>
      <:action>
        <.button
          id={"#{@id}-yes"}
          type="button"
          variant="danger"
          size="xs"
          phx-click={JS.push(@event, value: @values)}
          loading_text={gettext("Cancelling")}
        >
          {gettext("Cancel run")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  @doc """
  "Cancelling", in the place of the state of a run a member cancelled, until its exit,
  with the dot of the run's state.
  """
  attr :id, :string, default: nil
  attr :state, :string, required: true

  def cancelling(assigns) do
    ~H"""
    <span id={@id} class={["q-sdot", "q-sdot-#{@state}"]}>
      <i aria-hidden="true"></i><span>{gettext("Cancelling")}</span>
    </span>
    """
  end

  @doc """
  Whether a run a member cancelled has ended, as its line reads it: its exit arrived, or
  it ended by `Apiary.Runs.Run.ended?/2`, a lost run only once it is lost for good. A lost
  run that may still attach again reads as a running one, "Cancelling".
  """
  @spec ended?(map) :: boolean
  defdelegate ended?(run), to: Apiary.Runs.Cancel

  @doc """
  Whether the state of `run` reads "Cancelling" on every page that shows it: a member
  cancelled the run (`Apiary.Runs.Run.cancel_requested?/1`) and it has not ended
  (`ended?/1`). A map that is not a whole run needs the fields `ended?/1` reads.
  """
  @spec cancelling?(map) :: boolean
  defdelegate cancelling?(run), to: Apiary.Runs.Cancel

  @doc """
  The line of a run a member cancelled (`run`, with its mark), by `person` (a map with
  `name` and `email`, as the work item page reads a person), for the reader whose
  address is `reader`:

    * before its exit, while its machine is `quiet_since` a time, that no report came
      from the machine since then; nothing else, as the state reads "Cancelling";
    * after an exit with the cancel's reason, who cancelled it and when; for a run whose
      push step had started (`pushing`), that it was pushing its changes, then, given
      what it wrote to its targets (`writes`, `Apiary.Runs.TargetWrite.writes/2`), one
      line for each repository it pushed or may have pushed, or that no push to its
      repositories was recorded;
    * after any other exit, who cancelled it and when, and that nothing it sent counts.
  """
  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :person, :map, required: true
  attr :reader, :string, default: nil
  attr :pushing, :boolean, default: false
  attr :writes, :list, default: nil
  attr :quiet_since, :any, default: nil
  attr :class, :any, default: nil

  def cancel_line(assigns) do
    assigns = assign(assigns, text: line(assigns), written: written(assigns))

    ~H"""
    <p :if={@text} id={@id} class={@class}>
      <%!-- One child, so a flex line class keeps the sentence's spaces. --%>
      <span class="min-w-0"><.rich text={@text}>
        <:part name={:person}><.canceller person={@person} reader={@reader} /></:part>
        <:part name={:time}><.at at={@run.cancel_requested_at} /></:part>
        <:part name={:since}><.at at={@quiet_since} /></:part>
      </.rich><span
        :for={{line, n} <- Enum.with_index(@written, 1)}
        id={"#{@id}-written-#{n}"}
        class="block"
      >{line}</span></span>
    </p>
    """
  end

  defp line(%{run: run} = assigns) do
    cond do
      not ended?(run) and assigns.quiet_since != nil ->
        rich_gettext(
          "No report from the machine since %{since}. The run ends at its next report, or is marked lost once its heartbeats stop.",
          since: {:part, :since}
        )

      not ended?(run) ->
        nil

      run.state == "cancelled" and run.exit_reason == Run.cancel_reason() and assigns.pushing ->
        rich_gettext("Cancelled by %{person} at %{time}, while the run was pushing its changes.",
          person: {:part, :person},
          time: {:part, :time}
        )

      run.state == "cancelled" and run.exit_reason == Run.cancel_reason() ->
        rich_gettext("Cancelled by %{person} at %{time}",
          person: {:part, :person},
          time: {:part, :time}
        )

      true ->
        rich_gettext(
          "Cancelled by %{person} at %{time}. The run ended %{exit} before it stopped; nothing it sent counts.",
          person: {:part, :person},
          time: {:part, :time},
          exit: String.downcase(ApiaryWeb.RunComponents.state_label(run.exit_state || run.state))
        )
    end
  end

  # The lines after "while the run was pushing its changes.": each repository a write
  # changed or may have changed, in the order of its first write; with none, that no push
  # was recorded: a push may leave no write, through a connection the proxy does not
  # read, say. A repository whose every write was refused has no line.
  defp written(%{run: run, pushing: true, writes: writes}) when is_list(writes) do
    if ended?(run) and run.state == "cancelled" and run.exit_reason == Run.cancel_reason() do
      case for(%{written: written} = write <- writes, written != :refused, do: write) do
        [] -> [gettext("No push to this run's targets was recorded.")]
        shown -> Enum.map(shown, &written_line/1)
      end
    else
      []
    end
  end

  defp written(_assigns), do: []

  defp written_line(%{written: :changed, path: path}),
    do: gettext("%{repository} was pushed.", repository: path)

  defp written_line(%{written: :maybe, path: path}),
    do: gettext("%{repository} may have been pushed.", repository: path)

  # The person who cancelled: their letter with the address as its tooltip, and their
  # name; "(you)" after the reader's; "Former member" for a deleted account.
  attr :person, :map, required: true
  attr :reader, :string, default: nil

  defp canceller(assigns) do
    ~H"""
    <span class="whitespace-nowrap"><.avatar
      email={@person.email}
      reader={@reader}
      size="xs"
    /><span :if={@person.email != ApiaryWeb.People.former_member()}>{" "}{@person.name}</span><span :if={
      @person.email == @reader
    }>{" "}{gettext("(you)")}</span></span>
    """
  end

  attr :at, :any, required: true

  defp at(assigns) do
    ~H"""
    <time :if={@at} datetime={DateTime.to_iso8601(@at)}>{Format.time(@at, seconds: true)}</time>
    """
  end
end
