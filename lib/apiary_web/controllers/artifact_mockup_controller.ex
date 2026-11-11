defmodule ApiaryWeb.ArtifactMockupController do
  # One screen of a mockup of pages (`Apiary.Artifacts.Mockup`), the page the version
  # page shows in its frame, for a person signed in who may read the work item. Not a
  # page of the console: the frame loads it, and its links load the other screens.
  #
  #     GET /:org/:workspace/work/:number/artifacts/:version_id/mockup/:screen
  #
  # Scoped as the version's files are (`ApiaryWeb.ArtifactFileController`): the
  # organisation and the workspace of the path resolved for a member, the work item by
  # its number read with `work_item.read` (`Apiary.Access`), the version one of that work
  # item's (`av_…`), a mockup of pages, and `:screen` the id of one of its screens, or
  # the id and `.html`, the address a page's link `<id>.html` resolves to. Its
  # pipeline, `:mockup_frame`, sends no redirect to sign in and sets no security header of
  # the console's pages, so every answer, a refusal included, carries only this route's
  # headers. Anything else, also a request with no session, is `404` with a page of one
  # line, "Reload the page to try again. This screen cannot be shown."
  #
  # Every answer has:
  #
  #   * `content-security-policy: default-src 'none'; style-src 'unsafe-inline';
  #     img-src data:; font-src data:; base-uri 'none'; form-action 'none';
  #     frame-ancestors 'self'; sandbox`, in place of the console's policy: no script,
  #     no load from any address but a `data:` image or font, no form, an opaque origin,
  #     and only a page of the console may frame it;
  #   * `content-type: text/html; charset=utf-8`, not as an attachment;
  #   * `x-content-type-options: nosniff` and `cache-control: private, no-store`.
  #
  # With the feature `workflow_model` off for the instance, the route is not found, as
  # every route of the feature (`ApiaryWeb.Features.Routes`).
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :controller

  alias Apiary.{Features, Organisations}
  alias ApiaryWeb.ArtifactLive.Load

  @policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; " <>
            "base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox"

  # Before the feature's gate, whose `404` is the console's error page: a person not shown
  # the feature gets this route's `404`.
  plug :place
  use ApiaryWeb.Features, :workflow_model

  # policy/0 is the `content-security-policy` of every answer of this route.
  @doc false
  @spec policy() :: String.t()
  def policy, do: @policy

  def show(conn, %{"number" => number, "version_id" => version_id, "screen" => screen}) do
    scope = conn.assigns.current_scope

    with %{} = work_item <- Load.work_item(scope, number),
         %{} = version <- Load.version(work_item, version_id),
         type = Load.type(work_item, version.artifact.type),
         {:ok, index} <- Load.mockup(type, version),
         {:ok, bytes} <-
           Load.mockup_page(version, index, String.replace_suffix(screen, ".html", "")) do
      conn |> headers() |> send_resp(200, bytes)
    else
      _not_found -> not_found(conn)
    end
  end

  # The path's organisation and workspace, for a person signed in who reaches them, and
  # the feature shown to that person; else this route's `404`.
  defp place(conn, _opts) do
    %{"org" => organisation, "workspace" => workspace} = conn.path_params

    with {:ok, scope} <-
           Organisations.resolve_scope(conn.assigns.current_scope, organisation, workspace),
         true <- Features.visible?(scope, :workflow_model) do
      ApiaryWeb.Lingo.put_locale(scope)
      assign(conn, :current_scope, scope)
    else
      _unreached -> conn |> not_found() |> halt()
    end
  end

  defp not_found(conn) do
    text = gettext("Reload the page to try again. This screen cannot be shown.")
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
  end
end
