defmodule ApiaryWeb.SendOn do
  # The page that sends a person on to an address outside the console, with a pass in its
  # query: Install's connect address (`ApiaryWeb.AdapterInstallController`) and Set up's
  # `setup_url` (`ApiaryWeb.AdapterSetupController`), each answering a form's POST.
  #
  # The console's pages say `form-action 'self'` (`ApiaryWeb.ContentSecurityPolicy`),
  # which a browser applies to the redirects that follow a form's POST too. So the person
  # is not sent there by a redirect: the answer is a page with no text that refreshes to
  # it at once (`<meta http-equiv="refresh">`), a new navigation, not a form's. It says
  # `Referrer-Policy: no-referrer`, so the address is not told which page sent the person,
  # and `Cache-Control: no-store`, so the pass is kept by no cache. The address is in the
  # answer's body alone, which nothing logs.
  #
  # The feature its pages belong to is hidden from the documentation, so the module is
  # too.
  @moduledoc false

  import Plug.Conn

  @doc false
  # Answers `conn` with the page that sends the person on to `url`, an address an adapter
  # declared, held to `Apiary.Adapters.Wire.url?/1` and stored under
  # `Apiary.Nodes.Node`'s changesets, with the pass, escaped as an attribute.
  @spec send_on(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def send_on(conn, url) do
    content = Phoenix.HTML.attributes_escape(content: "0;url=" <> url)

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      [
        ~s(<!DOCTYPE html><html><head><meta charset="utf-8">),
        ~s(<meta name="referrer" content="no-referrer">),
        ~s(<meta http-equiv="refresh"),
        Phoenix.HTML.safe_to_string(content),
        ~s(></head><body></body></html>)
      ]
    )
  end
end
