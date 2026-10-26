defmodule ApiaryWeb.SetUpComponents do
  @moduledoc """
  What the pages that lead a person through a set-up share, one step a page in a narrow
  column with no sidebar (`ApiaryWeb.Layouts.app/1` with `sidebar={false}`): the step's
  title, with "Step n of m" beside it where there is more than one (`heading/1`), and its
  help, short steps under the title (`help/1`).
  """
  use ApiaryWeb, :html

  attr :step, :integer, default: nil, doc: "the step's number; none for a page of one step"
  attr :total, :integer, default: nil, doc: "how many steps there are"
  slot :inner_block, required: true, doc: "the title"
  slot :subtitle, doc: "one line under the title"

  @doc """
  heading/1 is a step's title, the page's `<h1>`, with "Step n of m" beside it when
  `step` and `total` are given, and its line under it.
  """
  def heading(assigns) do
    ~H"""
    <div class="grid gap-1.5">
      <div class="flex items-baseline justify-between gap-3">
        <h1 class="text-2xl/8 font-semibold tracking-[-0.025em]">{render_slot(@inner_block)}</h1>
        <span :if={@step && @total} id="set-up-step" class="whitespace-nowrap text-[13px] text-faint">
          {gettext("Step %{step} of %{total}", step: @step, total: @total)}
        </span>
      </div>
      <p :if={@subtitle != []} id="set-up-line" class="text-sm/5 text-muted">
        {render_slot(@subtitle)}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  @doc """
  help/1 is a step's help: short steps under its title, as paragraphs and one numbered
  list, in a quiet box.
  """
  def help(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid gap-2 rounded-box border border-line bg-base-200 px-4 py-3 text-[13px]/5 [&_ol]:grid [&_ol]:list-decimal [&_ol]:gap-1 [&_ol]:pl-5"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
