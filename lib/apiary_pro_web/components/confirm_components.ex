defmodule ApiaryProWeb.ConfirmComponents do
  @moduledoc """
  The edition's confirmations of an act that asks for a name typed first: purging an
  organisation, dropping or deleting a client; and of one that takes
  a separate field: declining a policy request, with its reason. Each is in place where
  the act was asked for, a row of a list or a part of a page, never a dialog (the core's
  `docs/ui.md`, No modals).

  `typed_confirm/1` is the core's `ApiaryWeb.SettingsComponents.deletion_confirm/1` with
  the act's words on its button, since not every such act is a deletion: what is lost,
  the field to type, then the core's `ApiaryWeb.CoreComponents.inline_confirm/1`, its
  question, its red button, enabled once the field matches, and Cancel.

  `reason_confirm/1` is the same shape for an act that loses nothing and asks for words to
  go with it: the field, then the question with a button that is not red, and Cancel.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryProWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [button: 1, inline_confirm: 1]

  alias Phoenix.LiveView.JS

  @doc """
  typed_confirm/1 is a confirmation in place of an act whose name is typed to confirm it:
  a form, `id`-form, of what is lost (`:lost`), the field to type (`:field`), which takes
  the focus, then the question with its red button (`id`-confirm, `button`), enabled once
  `ready`, and Cancel, which with Escape runs `cancel`.
  """
  attr :id, :string, required: true, doc: "the act's id, which its parts' ids begin with"
  attr :question, :string, required: true
  attr :form, :any, required: true, doc: "the form of the field typed"
  attr :change, :string, required: true, doc: "the event of a change of the field"
  attr :submit, :string, required: true, doc: "the event of the red button"
  attr :ready, :boolean, required: true, doc: "whether the red button is enabled"
  attr :button, :string, required: true, doc: "the red button's words, such as Yes, purge"
  attr :loading_text, :string, required: true, doc: "the gerund it shows while it acts"
  attr :cancel, :any, required: true, doc: "a path to patch to, or a JS command"

  slot :lost, doc: "what is lost, a paragraph each" do
    attr :id, :string
  end

  slot :field, required: true

  def typed_confirm(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"#{@id}-form"}
      class="q-danger-confirm"
      phx-change={@change}
      phx-submit={@submit}
      novalidate
    >
      <div :if={@lost != []} class="q-danger-lost">
        <p :for={lost <- @lost} id={lost[:id]}>{render_slot(lost)}</p>
      </div>
      <div id={"#{@id}-field"} class="q-danger-field">
        {render_slot(@field)}
      </div>
      <.inline_confirm id={"#{@id}-confirming"} question={@question} cancel={@cancel}>
        <:action>
          <.button
            id={"#{@id}-confirm"}
            variant="danger"
            size="xs"
            type="submit"
            disabled={!@ready}
            loading_text={@loading_text}
          >
            {@button}
          </.button>
        </:action>
      </.inline_confirm>
      <%!-- After the confirmation's Cancel, which takes the focus as it mounts: the field
           to type takes it last. --%>
      <span hidden phx-mounted={JS.focus_first(to: "##{@id}-field")}></span>
    </.form>
    """
  end

  @doc """
  reason_confirm/1 is a confirmation in place of an act that loses nothing and takes a
  field with it, such as a reason: a form, `id`, that sends `submit`, with the field
  (`:field`, its hidden inputs too), which takes the focus, then the question
  (`id`-confirm) with what happens (`inner_block`), its button (`id`-button, `button`),
  never red and never disabled, and Cancel, which with Escape runs `cancel`.
  """
  attr :id, :string, required: true, doc: "the form's id, which its parts' ids begin with"
  attr :question, :string, required: true
  attr :form, :any, required: true, doc: "the form of the field"
  attr :submit, :string, required: true, doc: "the event of the button"
  attr :button, :string, required: true, doc: "the button's words, such as Yes, decline"
  attr :loading_text, :string, required: true, doc: "the gerund it shows while it acts"
  attr :cancel, :any, required: true, doc: "a path to patch to, or a JS command"
  slot :field, required: true
  slot :inner_block, doc: "what happens, a short sentence"

  def reason_confirm(assigns) do
    ~H"""
    <.form for={@form} id={@id} class="grid gap-3" phx-submit={@submit} novalidate>
      <div id={"#{@id}-field"} class="grid gap-3">
        {render_slot(@field)}
      </div>
      <.inline_confirm id={"#{@id}-confirm"} question={@question} cancel={@cancel}>
        {render_slot(@inner_block)}
        <:action>
          <.button id={"#{@id}-button"} size="xs" type="submit" loading_text={@loading_text}>
            {@button}
          </.button>
        </:action>
      </.inline_confirm>
      <%!-- After the confirmation's Cancel, which takes the focus as it mounts: the field
           takes it last. --%>
      <span hidden phx-mounted={JS.focus_first(to: "##{@id}-field")}></span>
    </.form>
    """
  end
end
