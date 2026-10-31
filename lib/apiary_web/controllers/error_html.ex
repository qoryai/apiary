defmodule ApiaryWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use ApiaryWeb, :html

  # The status lines a page may show, marked for extraction; any other status shows
  # Phoenix's message as it is.
  @messages %{
    "404" => gettext_noop("Not Found"),
    "500" => gettext_noop("Internal Server Error")
  }

  # A `404` raised with a page (`ApiaryWeb.NotFound`'s `page`) under an organisation the
  # person reaches is that page inside the app's layout (`ApiaryWeb.DeadEnd`).
  def render("404.html", %{reason: %ApiaryWeb.NotFound{page: page}} = assigns)
      when not is_nil(page) do
    ApiaryWeb.DeadEnd.document(assigns, page) || render("404.html", %{})
  end

  # The default is to render a plain text page based on the template name. For example,
  # "404.html" becomes "Not Found", in the domain's words.
  def render(template, _assigns) do
    case Map.fetch(@messages, template |> String.split(".") |> hd()) do
      {:ok, msgid} -> Gettext.gettext(ApiaryWeb.Gettext, msgid)
      :error -> Phoenix.Controller.status_message_from_template(template)
    end
  end
end
