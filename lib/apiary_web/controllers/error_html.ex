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

  # The default is to render a plain text page based on the template name. For example,
  # "404.html" becomes "Not Found", in the body's words.
  def render(template, _assigns) do
    case Map.fetch(@messages, template |> String.split(".") |> hd()) do
      {:ok, msgid} -> Gettext.gettext(ApiaryWeb.Gettext, msgid)
      :error -> Phoenix.Controller.status_message_from_template(template)
    end
  end
end
