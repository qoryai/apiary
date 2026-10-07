defmodule ApiaryWeb.ContentSecurityPolicy do
  @moduledoc """
  The `content-security-policy` of every answer the router gives and of the documentation
  under `/docs`: only the console's own scripts run. A script that a bug lets into a page,
  in markup, an attribute or a `javascript:` address, is refused by the browser, so a page
  that shows a secret once shows it to the person in front of it and to no script.

  A plug of the endpoint (`ApiaryWeb.Endpoint`), after its static files and the code
  reloader and before the documentation and the router, so the console's pages, the
  storybook, the development tools, an edition's pages and the error pages of the router
  and its routes all carry it, a `404` of `ApiaryWeb.Features.Routes` among them. Not so
  an error raised inside the endpoint after this plug by an exception that holds no
  request, a `Plug.Parsers` `400` or `413`: Phoenix renders it from the request as it
  reached the endpoint, before this plug, so it answers without the policy, as plain text
  ("Bad Request", "Request Entity Too Large") with no script.
  Each request gets a fresh nonce, 144 random bits in base64, assigned as `:csp_nonce`;
  a `<script>` written into a page carries it (`nonce={@csp_nonce}`), as the root layout's
  theme script does. Nothing else may be inline: no `on…=` attribute, no `javascript:`
  address. LiveView's `phx-*` bindings and `Phoenix.LiveView.JS` commands are not inline
  script and need nothing; LiveView, Phoenix and the bundled libraries use neither `eval`
  nor `new Function`, so the policy has no `'unsafe-eval'`.

  The policy, directive by directive:

  - `default-src 'self'`: whatever has no directive of its own (frames, workers, media,
    the manifest) comes from the console's own origin.
  - `script-src 'self' 'nonce-…'`: the bundles under `/assets` and the scripts that carry
    the request's nonce; never `'unsafe-inline'`, `'unsafe-eval'` or `'strict-dynamic'`
    (no script loads another from elsewhere). Under `/docs` the policy also allows the one
    inline script ExDoc writes into every page, by its hash: the documentation is static
    files, which carry no nonce.
  - `style-src 'self' 'unsafe-inline'`: the stylesheets under `/assets`, and inline styles.
    The terminal of a run page (xterm.js, vendored as it is released) writes `<style>`
    elements and `style` attributes while it runs, and the storybook and the development
    tools set `style` attributes; a nonce cannot cover what a library creates at run time,
    and with a nonce in the list a browser ignores `'unsafe-inline'`. A style cannot run
    script, and with `img-src`, `font-src` and `connect-src` held to the console's origin
    an injected style cannot send what a page shows anywhere else.
  - `img-src 'self' data:`: the console's images, and the `data:` SVGs its stylesheet
    draws icons and select arrows with.
  - `font-src 'self'`: the fonts under `/fonts`.
  - `connect-src 'self' ws(s)://<host>`: LiveView's socket and its long-poll fallback, and
    the console's own requests. CSP Level 3 counts a `ws:` or `wss:` address of the page's
    own host and port as `'self'`; the socket's origin from the endpoint's URL
    (`PUBLIC_URL`) is named as well, for a browser that does not.
  - `object-src 'none'`: no plug-ins.
  - `base-uri 'self'`: no `<base>` sends relative addresses elsewhere.
  - `form-action 'self'`: forms post to the console only.
  - `frame-ancestors 'none'`: no page is framed, by another site or by the console. The
    development tools under `/dev` (the storybook, LiveDashboard, the mailbox) frame
    their own pages, and only there `allow_frames: :self` makes it `'self'`.

  A reverse proxy in front of the release must pass the header on as it is: one that
  strips or replaces it takes this protection away (`guides/hosting-checklist.md`).
  `Phoenix.Controller.put_secure_browser_headers/2` sets its own short policy only when
  there is none, so it leaves this one in place.
  """

  @behaviour Plug

  import Plug.Conn

  @header "content-security-policy"

  # The inline script ExDoc writes at the top of every page's body
  # (`ExDoc.Formatter.HTML.Assets.inline_js_source/0`), by its SHA-256. A test holds it to
  # the installed ExDoc, so an upgrade that changes the script fails until this changes too.
  @ex_doc_script "sha256-bIKxeQ2FHjoRvRMBTkBzTiaQlopuJjAXtgIIXQaOYZI="

  @doc false
  def ex_doc_script, do: @ex_doc_script

  @impl Plug
  def init(opts), do: Keyword.validate!(opts, allow_frames: :none)

  @impl Plug
  @doc """
  Sets the policy and assigns its nonce, `:csp_nonce`. Called again further down, with
  `allow_frames: :self`, it keeps the request's nonce and only lets the console frame the
  page.
  """
  def call(conn, opts) do
    nonce = conn.assigns[:csp_nonce] || nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(@header, policy(nonce, docs?(conn), Keyword.fetch!(opts, :allow_frames)))
  end

  @doc """
  The policy for `nonce`: under `/docs` when `docs?` is true, and framed by the console's
  own pages when `allow_frames` is `:self` rather than `:none`.
  """
  @spec policy(String.t(), boolean(), :none | :self) :: String.t()
  def policy(nonce, docs? \\ false, allow_frames \\ :none) do
    Enum.join(
      [
        "default-src 'self'",
        Enum.join(["script-src 'self' 'nonce-#{nonce}'" | docs_script(docs?)], " "),
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self' #{socket_origin()}",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors #{frames(allow_frames)}"
      ],
      "; "
    )
  end

  defp docs_script(true), do: ["'#{@ex_doc_script}'"]
  defp docs_script(false), do: []

  defp frames(:none), do: "'none'"
  defp frames(:self), do: "'self'"

  defp docs?(%Plug.Conn{path_info: ["docs" | _]}), do: true
  defp docs?(_conn), do: false

  # 18 random bytes, 24 characters of base64 without padding.
  defp nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

  # The LiveView socket's origin as the browser reaches it, from the endpoint's URL:
  # `wss:` for `https`, `ws:` for `http`, the port only when it is not the default.
  defp socket_origin do
    %URI{scheme: scheme, host: host, port: port} = ApiaryWeb.Endpoint.struct_url()
    socket_scheme = if scheme == "https", do: "wss", else: "ws"
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    case {scheme, port} do
      {"https", 443} -> "#{socket_scheme}://#{host}"
      {"http", 80} -> "#{socket_scheme}://#{host}"
      {_, nil} -> "#{socket_scheme}://#{host}"
      _ -> "#{socket_scheme}://#{host}:#{port}"
    end
  end
end
