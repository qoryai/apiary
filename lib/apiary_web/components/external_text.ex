defmodule ApiaryWeb.ExternalText do
  @moduledoc """
  A text of one line an external system sent, as a page shows it: a collection's or an
  item's title, a name, an author, a release's name. It is isolated in `<bdi>`, so its
  direction runs into nothing around it, with its invisible characters dropped and its
  control characters shown as U+FFFD (`Apiary.ExternalText.line/1`).

      <.external_text text={@ticket.title} />

  Where markup cannot go, in an attribute, a page title or a toast, the text is
  `Apiary.ExternalText.line/1`.
  """
  use Phoenix.Component

  attr :text, :string, required: true, doc: "the text as sent; nil shows nothing"
  attr :rest, :global

  def external_text(assigns) do
    ~H"""
    <bdi :if={@text} {@rest}>{Apiary.ExternalText.line(@text)}</bdi>
    """
  end
end
