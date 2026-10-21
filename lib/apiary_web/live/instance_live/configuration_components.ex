defmodule ApiaryWeb.InstanceLive.ConfigurationComponents do
  @moduledoc """
  What the parts of Instance settings › Configuration (`ApiaryWeb.InstanceLive.Configuration`)
  share, the core's and the ones an edition adds after them
  (`c:ApiaryWeb.Edition.configuration_parts/1`): a row of one setting (`setting/1`), read
  only or with its field; the line that names the variable of the server's environment
  that sets a value (`env_line/1`); and the toast of a save (`saved/2`).

  An edition's part is a `Phoenix.LiveComponent`, rendered with its `id` and the page's
  `current_scope`, which holds its form, its save, its copy of what it saved and its
  trail's entry. Saving is an instance admin's after a recent sign-in, as
  `Apiary.InstanceConfig.authorize_save/1` asks. Where that answers `{:error, :sudo}`, the
  part sends the page `{:configuration, :sudo}` (`send(self(), {:configuration, :sudo})`),
  and the page leads to the log-in page with the flash it gives for its parts. Once
  saved, the part calls `saved/2`, and the page shows its toast.
  """
  use ApiaryWeb, :html

  @doc """
  setting/1 is one row: what the setting is, then its value, read only, or the field that
  changes it (`field`); one sentence of what it decides; what an empty field gives
  (`hint`) and the field's errors; and where a read-only value comes from (`source`).
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil, doc: "the value, read only; none where the row has a field"
  attr :for, :string, default: nil, doc: "the id of the row's field, which the label names"

  attr :source, :any,
    default: nil,
    doc: "rich text: the setting the value comes from, or that it is the default"

  attr :hint, :string, default: nil, doc: "under the sentence: what an empty field gives"
  attr :errors, :list, default: [], doc: "the field's errors, translated"
  attr :mono_label, :boolean, default: false, doc: "the label is a name the setting takes"
  slot :field, doc: "the field that changes the value, in place of the value"
  slot :inner_block, doc: "one sentence: what the value decides"

  def setting(assigns) do
    ~H"""
    <div id={@id} class="grid gap-x-6 gap-y-1 text-[13px]/[20px] sm:grid-cols-[200px_minmax(0,1fr)]">
      <dt class={["text-muted", @mono_label && "q-mono"]}>
        <label :if={@for} for={@for}>{@label}</label>{if !@for, do: @label}
      </dt>
      <dd class="m-0 flex min-w-0 flex-col gap-0.5">
        <div :if={@field != []} id={"#{@id}-field"} class="flex items-center gap-2">
          {render_slot(@field)}
        </div>
        <span :if={@field == []} id={"#{@id}-value"} class="font-medium">{@value}</span>
        <span :if={@inner_block != []} class="text-muted">{render_slot(@inner_block)}</span>
        <span :if={@hint} id={"#{@id}-hint"} class="text-[12px] text-faint">{@hint}</span>
        <p
          :for={{message, i} <- Enum.with_index(@errors)}
          id={if i == 0, do: "#{@id}-error", else: "#{@id}-error-#{i + 1}"}
          class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
        >
          <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />{message}
        </p>
        <span :if={@source} id={"#{@id}-source"} class="text-[12px] text-faint">
          <.rich text={@source} />
        </span>
      </dd>
    </div>
    """
  end

  @doc """
  env_line/1 is the source line of a value the server's environment sets: "Set by", and
  the variable, in mono.
  """
  @spec env_line(String.t()) :: String.t() | list
  def env_line(variable) when is_binary(variable),
    do: rich_gettext("Set by %{variable}", variable: {:code, variable, "q-mono"})

  @doc """
  saved/2 is the toast of a part's save, `text`, such as "Retention saved.": the page stays
  where it is. Given a part's socket, a `Phoenix.LiveComponent`'s, whose flash the page
  shows only on a redirect, it sends the page `{:configuration, {:saved, text}}`, and the
  page shows the toast.
  """
  @spec saved(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def saved(
        %Phoenix.LiveView.Socket{assigns: %{myself: %Phoenix.LiveComponent.CID{}}} = socket,
        text
      )
      when is_binary(text) do
    send(self(), {:configuration, {:saved, text}})
    socket
  end

  def saved(socket, text) when is_binary(text),
    do: Phoenix.LiveView.put_flash(socket, :info, text)
end
