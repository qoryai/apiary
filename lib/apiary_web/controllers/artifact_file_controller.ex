defmodule ApiaryWeb.ArtifactFileController do
  # A file of a version of a work item's artifact (`Apiary.Artifacts`), for a person
  # signed in who may read the work item. Not a page: the version page links its files
  # here, and its views load images, videos and captions from here.
  #
  #     GET /:org/:workspace/work/:number/artifacts/:version_id/files/:filename
  #
  # Scoped like the work item's page: the pipeline resolves the organisation and the
  # workspace of the path for a member and answers `404` for anybody else; the work item
  # is the workspace's by its number, read with `work_item.read` (`Apiary.Access`); the
  # version is one of that work item's (`av_…`), and the file one of that version's by
  # its filename. Anything else is `404`, as an address that does not exist: another
  # workspace's work item, another work item's version, or a reader `Apiary.Access`
  # refuses. A request with no session is sent to sign in, as every page of a workspace.
  # With the feature `workflow_model` off or hidden, the route is not found.
  #
  # Every answer that serves a file has:
  #
  #   * `content-disposition: attachment`, with the filename as `filename*` in UTF-8
  #     (RFC 6266, RFC 8187) and an ASCII `filename` beside it, so a browser that opens
  #     the address downloads the file and never renders it as a page;
  #   * `x-content-type-options: nosniff`;
  #   * the content type the format check kept for the file (`Apiary.Artifacts.Format`);
  #   * `content-security-policy: default-src 'none'; sandbox`, in place of the console's
  #     policy, so a document opened anyway runs no script and loads nothing;
  #   * `cache-control: private, no-store`.
  #
  # An image, a video or a caption file in a page's `<img>`, `<video>` or `<track>`
  # loads from here as well. A browser applies the content type, `nosniff` and
  # `cache-control` to such a load, and ignores `content-disposition` and the
  # `content-security-policy` header there.
  # A stored copy on the volume is sent with `send_file`, and a `Range` of one span is
  # answered `206`, so a video can seek; a store that returns a stream sends it chunked.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :workflow_model

  alias Apiary.{Access, Artifacts, PublicId, WorkItems}
  alias Apiary.Artifacts.Version

  def show(conn, %{"number" => number, "version_id" => version_id, "filename" => filename}) do
    with {:ok, scope} <- scope(conn),
         %{} = work_item <- WorkItems.get_by_number(scope, number),
         true <- Access.can?(scope, :"work_item.read", work_item),
         {:ok, version} <- version(work_item, version_id),
         %{} = file <- Enum.find(version.files, &(&1.filename == filename)),
         {:ok, source} <- Artifacts.open_file(file) do
      send_source(conn, file, source)
    else
      _not_found -> send_plain(conn, 404, gettext("not found"))
    end
  end

  # The pipeline's `fetch_path_scope/2` has resolved the path's organisation and
  # workspace.
  defp scope(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{}, organisation: %{}, workspace: %{}} = scope -> {:ok, scope}
      _none -> :error
    end
  end

  # The version `version_id` among the versions of the work item's artifacts.
  defp version(work_item, version_id) do
    with true <- PublicId.valid?(Version.prefix(), version_id),
         %Version{artifact: artifact} = version <- get_version(version_id),
         true <- artifact.work_item_id == work_item.id,
         true <- artifact.workspace_id == work_item.workspace_id do
      {:ok, version}
    else
      _other -> :error
    end
  end

  defp get_version(version_id) do
    Artifacts.get_version!(version_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp send_source(conn, file, path) when is_binary(path) do
    conn = headers(conn, file)

    case range(conn, file.size) do
      {:ok, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{file.size}")
        |> send_file(206, path, first, last - first + 1)

      :whole ->
        send_file(conn, 200, path)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{file.size}")
        |> send_resp(416, "")
    end
  end

  defp send_source(conn, file, stream) do
    conn = conn |> headers(file) |> send_chunked(200)

    Enum.reduce_while(stream, conn, fn bytes, conn ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  defp headers(conn, file) do
    conn
    |> put_resp_header("content-type", file.content_type)
    |> put_resp_header("content-disposition", disposition(file.filename))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("accept-ranges", "bytes")
  end

  # `attachment`, the filename's ASCII letters, digits and `.`, `-` and `_` as
  # `filename` (any other character, one `_` each), and the whole filename in UTF-8,
  # percent-encoded, as `filename*`.
  @doc false
  @spec disposition(String.t()) :: String.t()
  def disposition(filename) do
    ascii = String.replace(filename, ~r/[^A-Za-z0-9._-]/u, "_")
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{encoded})
  end

  # The one span a `Range: bytes=…` asks for, within `size`: `{:ok, first, last}`;
  # `:whole` for no header, one this does not read, or several spans; `:unsatisfiable`
  # for a span that starts past the end.
  defp range(conn, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] -> span(spec, size)
      _none -> :whole
    end
  end

  defp span(spec, size) do
    case Regex.run(~r/\A(\d{0,19})-(\d{0,19})\z/, String.trim(spec)) do
      [_all, "", ""] ->
        :whole

      [_all, "", suffix] ->
        length = min(String.to_integer(suffix), size)
        if length == 0, do: :unsatisfiable, else: {:ok, size - length, size - 1}

      [_all, first, last] ->
        first = String.to_integer(first)
        last = if last == "", do: size - 1, else: min(String.to_integer(last), size - 1)

        cond do
          first >= size -> :unsatisfiable
          last < first -> :whole
          true -> {:ok, first, last}
        end

      nil ->
        :whole
    end
  end

  defp send_plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, body)
  end
end
