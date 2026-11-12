defmodule ApiaryProWeb.PathScopeTest do
  @moduledoc """
  A path whose second segment is a reserved name that no page answers, such as `workspaces`
  under an organisation, can hold no workspace's slug: it is not found, and no log-in is
  asked for, as the core answers a path that can hold no slug (`ApiaryWeb.PathScopeTest`).
  The edition reserves only the second segments of its pages, which ask for a log-in.
  """
  use ApiaryWeb.ConnCase, async: true

  # A response, whether the pipeline sent it or the endpoint rendered an error, without
  # the request id, and with the content security policy's nonce, fresh for each request,
  # left out of its value.
  defp answer(request) do
    conn = request.()
    {conn.status, conn.resp_body, headers(conn.resp_headers)}
  rescue
    _error ->
      {status, headers, body} = assert_error_sent(:not_found, request)
      {status, body, headers(headers)}
  end

  defp headers(headers) do
    headers
    |> Enum.reject(fn {name, _} -> name == "x-request-id" end)
    |> Enum.map(fn
      {"content-security-policy" = name, value} ->
        {name, String.replace(value, ~r/'nonce-[^']*'/, "'nonce'")}

      header ->
        header
    end)
    |> Enum.sort()
  end

  test "a reserved name that no page answers is not found without a log-in" do
    for path <- ["/acme/workspaces"] do
      assert answer(fn -> get(build_conn(), path) end) ==
               answer(fn -> get(build_conn(), "/no/such/path/at/all/here") end),
             path
    end
  end
end
