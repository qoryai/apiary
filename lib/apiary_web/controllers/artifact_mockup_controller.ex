defmodule ApiaryWeb.ArtifactMockupController do
  # One screen of a mockup of pages (`Apiary.Artifacts.Mockup`), the page the version
  # page shows in its frame. Not a page of the console: the frame loads it, and its links
  # load the other screens.
  #
  #     GET /:org/:workspace/work/:number/artifacts/:version_id/mockup/:token/:page
  #
  # The frame is sandboxed with no token, so its page has an opaque origin, and a browser
  # sends no session cookie with a request from a link inside it (`SameSite=Lax`). So the
  # route reads no session and no cookie. `:token` (`token/3`) is signed by the version
  # page when it shows the viewer; its data are the version, the work item, the person
  # and the id of the person's session. `:page` is a screen's `<id>.html`, the address a
  # page's relative link resolves to.
  #
  # Every request is checked again: the token verifies, at most `@max_age` seconds old;
  # its version and work item are the path's, the work item the one at the path's
  # organisation, workspace and number; the session in it still lasts, so signing out
  # and a password change end the token; the person still reaches that workspace and
  # may read the work item (`work_item.read`, `Apiary.Access`), so access removed after
  # the token was signed counts at once; the version is a mockup of pages, and `<id>` the
  # id of one of its screens. Anything else is `404` with a page of one line, "Reload the
  # whole page to try again. This screen cannot be shown." With the feature `workflow_model`
  # hidden from the person, it is that `404` too. With the feature off for the instance,
  # the route does not exist: a request gets the router's not found page, under the
  # console's policy (`ApiaryWeb.Features.Routes`).
  #
  # The token is a bearer of the person's read of one version for an hour, so the log
  # keeps it out: the request log writes the path with `:token` in its place
  # (`Apiary.SecretLogFilter.redact_path/1`), and every other log line has it replaced
  # the same way. A response sends no referrer.
  #
  # Every answer has:
  #
  #   * `content-security-policy: default-src 'none'; style-src 'unsafe-inline';
  #     img-src data:; font-src data:; base-uri 'none'; form-action 'none';
  #     frame-ancestors 'self'; sandbox`, in place of the console's policy: no script,
  #     no load from any address but a `data:` image or font, no form, an opaque origin,
  #     and only a page of the console may frame it;
  #   * `content-type: text/html; charset=utf-8`, not as an attachment;
  #   * `x-content-type-options: nosniff`, `cache-control: private, no-store` and
  #     `referrer-policy: no-referrer`.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :controller

  alias Apiary.Accounts
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.{Features, Organisations}
  alias ApiaryWeb.ArtifactLive.Load

  @policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; " <>
            "base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox"

  @salt "mockup frame"
  @max_age 3600

  # Before the feature's gate, whose `404` is the console's error page: a person not shown
  # the feature gets this route's `404`.
  plug :place
  use ApiaryWeb.Features, :workflow_model

  # policy/0 is the `content-security-policy` of every answer of this route.
  @doc false
  @spec policy() :: String.t()
  def policy, do: @policy

  # token/3 is the token of the frame's address for the version `version` (`av_…`) of
  # the work item `work_item`, for the person `user` in the session `session` (the id
  # of its record, `Apiary.Accounts.session_token_id/1`), signed with the endpoint's
  # secret: `context` is a `Plug.Conn`, a socket or the endpoint.
  @doc false
  @spec token(
          term,
          %{
            version: String.t(),
            work_item: Ecto.UUID.t(),
            user: Ecto.UUID.t(),
            session: Ecto.UUID.t() | nil
          },
          keyword
        ) :: String.t()
  def token(context, %{version: v, work_item: w, user: u, session: s}, opts \\ []),
    do: Phoenix.Token.sign(context, @salt, %{v: v, w: w, u: u, s: s}, opts)

  # verify/2 is the token's data when it verifies within `@max_age` seconds, else
  # `:error`.
  @doc false
  @spec verify(term, String.t()) :: {:ok, map} | :error
  def verify(context, token) do
    case Phoenix.Token.verify(context, @salt, token, max_age: @max_age) do
      {:ok, %{v: _version, w: _work_item, u: _user, s: _session} = data} -> {:ok, data}
      _invalid -> :error
    end
  end

  def show(conn, %{"number" => number, "version_id" => version_id, "page" => page}) do
    %{scope: scope, token: token} = conn.assigns.mockup_frame

    with true <- token.v == version_id,
         %{} = work_item <- Load.work_item(scope, number),
         true <- work_item.id == token.w,
         %{} = version <- Load.version(work_item, version_id),
         type = Load.type(work_item, version.artifact.type),
         {:ok, index} <- Load.mockup(type, version),
         {:ok, screen} <- screen(page),
         {:ok, bytes} <- Load.mockup_page(version, index, screen) do
      conn |> headers() |> send_resp(200, bytes)
    else
      _not_found -> not_found(conn)
    end
  end

  # `<id>.html`: the screen's id.
  defp screen(page) do
    case String.split(page, ".html") do
      [id, ""] when id != "" -> {:ok, id}
      _other -> :error
    end
  end

  # The token verified, the person in it reaching the path's organisation and workspace,
  # and the feature shown to that person; else this route's `404`.
  defp place(conn, _opts) do
    %{"org" => organisation, "workspace" => workspace, "token" => token} = conn.path_params

    with {:ok, data} <- verify(conn, token),
         {%User{id: user_id} = user, _since} <- Accounts.get_user_by_session_token_id(data.s),
         true <- user_id == data.u,
         {:ok, scope} <-
           Organisations.resolve_scope(Scope.for_user(user), organisation, workspace),
         true <- Features.visible?(scope, :workflow_model) do
      ApiaryWeb.Lingo.put_locale(scope)

      conn
      |> assign(:current_scope, scope)
      |> assign(:mockup_frame, %{scope: scope, token: data})
    else
      _unreached -> conn |> not_found() |> halt()
    end
  end

  defp not_found(conn) do
    text = gettext("Reload the whole page to try again. This screen cannot be shown.")
    line = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    body =
      ~s(<!doctype html><html><head><meta charset="utf-8"><title></title></head><body><p>) <>
        line <> "</p></body></html>"

    conn |> headers() |> send_resp(404, body)
  end

  defp headers(conn) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> put_resp_header("content-security-policy", @policy)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
