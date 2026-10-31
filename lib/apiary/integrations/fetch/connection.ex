defmodule Apiary.Integrations.Fetch.Connection do
  @moduledoc false
  # Connection is the Req adapter of `Apiary.Integrations.Fetch`: one Mint connection per
  # request, to the address the fetch checked, closed when the request ends, whether it
  # ends with an answer, an error or the fetch's deadline.
  #
  # Req's default adapter, Finch, starts a pool for each set of connect options and never
  # stops it; a fetch's options change with each host and each remaining time, so every
  # fetch would leave a pool, its atoms, its processes and an idle socket behind.
  #
  # The request's private `:fetch_connection` is `{address, hostname, deadline}`: the
  # address to connect to, the name for SNI and the certificate's check, and the
  # monotonic time in milliseconds by which the request ends. The address is a tuple, so
  # its size sets the IP family, with no transport option. The certificate is verified
  # as Mint verifies it by default; a test adds the certificate authorities of its
  # server in the private `:fetch_transport_opts`. The response's body goes through the
  # request's `into` function where it has one, else is kept whole.

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    {address, hostname, deadline} = Req.Request.get_private(request, :fetch_connection)

    case Mint.HTTP.connect(:https, address, request.url.port,
           hostname: hostname,
           protocols: [:http1],
           mode: :passive,
           transport_opts:
             [timeout: left(deadline)] ++
               Req.Request.get_private(request, :fetch_transport_opts, [])
         ) do
      {:ok, conn} ->
        try do
          send_request(conn, request, deadline)
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        {request, error}
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp send_request(conn, request, deadline) do
    path =
      case request.url do
        %URI{path: path, query: nil} -> path || "/"
        %URI{path: path, query: query} -> (path || "/") <> "?" <> query
      end

    headers = for {name, values} <- request.headers, value <- values, do: {name, value}
    method = request.method |> Atom.to_string() |> String.upcase()

    case Mint.HTTP.request(conn, method, path, headers, request.body) do
      {:ok, conn, ref} -> receive_response(conn, ref, request, Req.Response.new(), deadline)
      {:error, _conn, error} -> {request, error}
    end
  end

  defp receive_response(conn, ref, request, response, deadline) do
    case Mint.HTTP.recv(conn, 0, left(deadline)) do
      {:ok, conn, parts} ->
        case parts(parts, ref, {request, response}) do
          {:done, result} -> result
          {:halt, result} -> result
          {:cont, {request, response}} -> receive_response(conn, ref, request, response, deadline)
        end

      {:error, _conn, error, _parts} ->
        {request, error}
    end
  end

  defp parts([], _ref, acc), do: {:cont, acc}

  defp parts([{:status, ref, status} | rest], ref, {request, response}),
    do: parts(rest, ref, {request, %{response | status: status}})

  defp parts([{:headers, ref, headers} | rest], ref, {request, response}) do
    response =
      Enum.reduce(headers, response, fn {name, value}, response ->
        %{response | headers: Map.update(response.headers, name, [value], &(&1 ++ [value]))}
      end)

    parts(rest, ref, {request, response})
  end

  defp parts([{:data, ref, data} | rest], ref, {request, response}) do
    case request.into do
      fun when is_function(fun, 2) ->
        case fun.({:data, data}, {request, response}) do
          {:cont, acc} -> parts(rest, ref, acc)
          {:halt, acc} -> {:halt, acc}
        end

      nil ->
        body = if is_binary(response.body), do: response.body, else: ""
        parts(rest, ref, {request, %{response | body: body <> data}})
    end
  end

  defp parts([{:done, ref} | _rest], ref, acc), do: {:done, acc}
  defp parts([_other | rest], ref, acc), do: parts(rest, ref, acc)
end
