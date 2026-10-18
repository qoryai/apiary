defmodule ApiaryWeb.ExternalText do
  @moduledoc """
  A text of one line an external system sent, as a page shows it: an item's title, a name,
  an author, a release's name. It is isolated in `<bdi>`, so its
  direction runs into nothing around it, with its invisible characters dropped and its
  control characters shown as U+FFFD (`Apiary.ExternalText.line/1`). A text that was sent
  but has nothing left to show once cleaned, or only whitespace, is marked
  (`Apiary.ExternalText.sent/1`), so it never reads as absent; nil and an empty text
  show nothing.

      <.external_text text={@item.title} />

  Where markup cannot go, in an attribute, a page title or a toast, the text is
  `Apiary.ExternalText.line/1`.
  """
  use Phoenix.Component

  attr :text, :string, required: true, doc: "the text as sent; nil or an empty text shows nothing"
  attr :rest, :global

  def external_text(assigns) do
    assigns = assign(assigns, :shown, Apiary.ExternalText.sent(assigns.text))

    ~H"""
    <bdi :if={@shown} {@rest}>{@shown}</bdi>
    """
  end
end
