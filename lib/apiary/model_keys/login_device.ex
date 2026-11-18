defmodule Apiary.ModelKeys.LoginDevice do
  @moduledoc """
  The three calls of a device sign-in (`Apiary.ModelKeys.DeviceSignIn`), each one HTTPS
  POST to an address of the provider's catalogue entry, `oauth_device`, with the client id
  of its `oauth_refresh`, as `codex login --device-auth` makes them (openai/codex
  `codex-rs/login/src/device_code_auth.rs`, `oauth/client.rs`):

    * `request_code/2`: `usercode_url`, a JSON body with `client_id`; the response has the
      code to show (`user_code`), the device id, the seconds between two polls (`interval`,
      a number or a string of one) and when the code stops working (`expires_at`); a
      missing or unreadable `expires_at` (its format was never measured) is taken as 15
      minutes from the call;
    * `poll/2`: `poll_url`, a JSON body with `device_auth_id` and `user_code`; while the
      person has not approved, the response is a 403 or a 404; after the approval it is a
      2xx with `authorization_code`, `code_challenge` and `code_verifier`;
    * `exchange/4`: the token endpoint of `oauth_refresh`, a form with `grant_type`
      `authorization_code`, `client_id`, `code`, `redirect_uri` and `code_verifier`; the
      response has the tokens.

  The addresses and the client id come from the catalogue entry alone, never from a
  person's input or a stored value, and `Apiary.Kinds.Endpoint.check/1` checks each
  address at every call. A call verifies TLS against the operating system's certificate
  authorities (and the file at the path in `SSL_CERT_FILE`, as an adapter call does), follows
  no redirect, is not retried, and stops after 15 seconds (5 to connect, 10 for each read) in
  a separate task. It keeps at most 64 KiB of the response. The user agent is `qory-apiary`.

  A failure is one of the fixed words `http_<status>`, `timeout`, `network`, `bad_response`
  and `bad_endpoint`, never a part of the response. Neither the response's body, the
  request, nor an error of the HTTP client reaches a log, a return value or an exception
  message: the task's crash is caught inside it. A failed poll has a third element, the
  seconds of a `Retry-After` header, at most 60, or nil.
  """

  alias Apiary.Adapters.{CallTrust, Calls}
  alias Apiary.Kinds.Endpoint

  @supervisor __MODULE__.Supervisor
  @connect_timeout 5_000
  @receive_timeout 10_000
  @total_timeout 15_000
  @shutdown_ms 20_000
  @max_response 65_536
  @default_lifetime 15 * 60
  @retry_after_max 60
  @user_agent "qory-apiary"

  @typedoc "The addresses of a catalogue entry's `oauth_device`."
  @type device :: %{required(String.t()) => String.t()}

  @typedoc "A failure of a call."
  @type failure :: {:error, String.t()} | :shutdown

  @typedoc "A failed poll: the failure's word and the seconds the provider asked to wait."
  @type poll_failure :: failure | {:error, String.t(), pos_integer | nil}

  @typedoc "What `request_code/2` reads from the response."
  @type code :: %{
          device_auth_id: String.t(),
          user_code: String.t(),
          interval: pos_integer,
          expires_at: DateTime.t()
        }

  @doc "The name of the supervisor that runs each call's task, for the application's children."
  @spec supervisor() :: atom
  def supervisor, do: @supervisor

  @doc """
  Requests a code to show from the provider: `{:ok, code}`, `:off` for a 404, or a
  failure. The 404 is taken as the response for an account whose device code sign-in is
  off. This is unconfirmed until a real run: no checkout of `codex` was available, and the
  probe of 2026-11-18 never saw a 404.
  """
  @spec request_code(device, String.t()) :: {:ok, code} | :off | failure
  def request_code(%{"usercode_url" => url}, client_id) when is_binary(client_id) do
    with :ok <- check(url),
         {:ok, status, body, _headers} <- post(url, json: %{"client_id" => client_id}) do
      case status do
        status when status in 200..299 -> code(body)
        404 -> :off
        status -> {:error, "http_#{status}"}
      end
    end
  end

  def request_code(_device, _client_id), do: {:error, "bad_endpoint"}

  @doc """
  Checks whether the person approved the sign-in of the code: `:pending`, `{:ok, grant}`
  with the `authorization_code` and the `code_verifier` of the exchange, or a failure. A
  response with another status is `{:error, "http_<status>", retry_after}`.
  """
  @spec poll(device, %{device_auth_id: String.t(), user_code: String.t()}) ::
          :pending | {:ok, %{code: String.t(), verifier: String.t()}} | poll_failure
  def poll(%{"poll_url" => url}, %{device_auth_id: id, user_code: code}) do
    with :ok <- check(url),
         {:ok, status, body, headers} <-
           post(url, json: %{"device_auth_id" => id, "user_code" => code}) do
      case status do
        status when status in [403, 404] -> :pending
        status when status in 200..299 -> grant(body)
        status -> {:error, "http_#{status}", retry_after(headers)}
      end
    end
  end

  def poll(_device, _code), do: {:error, "bad_endpoint"}

  @doc """
  Trades the grant of an approved sign-in for the tokens at the token endpoint
  `token_url` (`oauth_refresh`'s `url`): `{:ok, response}`, the response's JSON object, or a
  failure.
  """
  @spec exchange(String.t(), device, String.t(), %{code: String.t(), verifier: String.t()}) ::
          {:ok, map} | failure
  def exchange(token_url, %{"redirect_uri" => redirect_uri}, client_id, grant)
      when is_binary(client_id) do
    with :ok <- check(token_url),
         :ok <- check(redirect_uri),
         {:ok, status, body, _headers} <-
           post(token_url,
             form: [
               grant_type: "authorization_code",
               client_id: client_id,
               code: grant.code,
               redirect_uri: redirect_uri,
               code_verifier: grant.verifier
             ]
           ) do
      case {status, decode(body)} do
        {status, %{} = response} when status in 200..299 -> {:ok, response}
        {status, _response} when status in 200..299 -> {:error, "bad_response"}
        {status, _response} -> {:error, "http_#{status}"}
      end
    end
  end

  def exchange(_url, _device, _client_id, _grant), do: {:error, "bad_endpoint"}

  defp check(url) do
    case Endpoint.check(url) do
      :ok -> :ok
      {:error, _refusal} -> {:error, "bad_endpoint"}
    end
  end

  defp code(body) do
    with %{} = response <- decode(body),
         id when is_binary(id) and id != "" <- response["device_auth_id"],
         code when is_binary(code) and code != "" <-
           response["user_code"] || response["usercode"] do
      {:ok,
       %{
         device_auth_id: id,
         user_code: code,
         interval: interval(response["interval"]),
         expires_at: expires_at(response["expires_at"])
       }}
    else
      _other -> {:error, "bad_response"}
    end
  end

  # The provider sends the interval as a string, as the probe of 2026-11-18 measured, or
  # a number: 1 to 60 seconds, 5 where it is neither.
  defp interval(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} -> interval(seconds)
      _other -> 5
    end
  end

  defp interval(value) when is_number(value), do: value |> trunc() |> max(1) |> min(60)
  defp interval(_value), do: 5

  # When the code stops working: an ISO 8601 text with an offset, or seconds since 1970.
  # The format was never measured, so anything else (a missing member, a timestamp with no
  # offset, a float) is 15 minutes from now; the sign-in's own 30-minute limit bounds it.
  defp expires_at(value) do
    with :error <- time(value),
         do: DateTime.add(DateTime.utc_now(), @default_lifetime, :second)
  end

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _other -> :error
    end
  end

  defp time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, at} -> at
      _other -> :error
    end
  end

  defp time(_value), do: :error

  # The seconds a `Retry-After` header gives, 1 to 60; an HTTP date and anything else is nil.
  defp retry_after(headers) do
    with [value | _] <- headers["retry-after"] || [],
         {seconds, ""} when seconds > 0 <- Integer.parse(String.trim(value)) do
      min(seconds, @retry_after_max)
    else
      _none -> nil
    end
  end

  defp grant(body) do
    with %{} = response <- decode(body),
         code when is_binary(code) and code != "" <- response["authorization_code"],
         verifier when is_binary(verifier) and verifier != "" <- response["code_verifier"] do
      {:ok, %{code: code, verifier: verifier}}
    else
      _other -> {:error, "bad_response"}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = response} -> response
      _other -> nil
    end
  end

  defp decode(_body), do: nil

  # The request in a task that is linked to nobody and stopped at the call's limit. The
  # task catches every failure, so its crash report, which would carry the request's
  # closure, is never written.
  defp post(url, body_options) do
    task =
      Task.Supervisor.async_nolink(
        @supervisor,
        fn ->
          Process.flag(:trap_exit, true)

          try do
            request(url, body_options)
          rescue
            _exception -> {:error, "network"}
          catch
            _kind, _reason -> {:error, "network"}
          end
        end,
        shutdown: @shutdown_ms
      )

    total = Application.get_env(:apiary, __MODULE__, [])[:total_timeout] || @total_timeout

    case Task.yield(task, total) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> if shutdown?(reason), do: :shutdown, else: {:error, "network"}
      nil -> {:error, "timeout"}
    end
  end

  defp shutdown?(reason),
    do: reason in [:shutdown, :killed] or match?({:shutdown, _detail}, reason)

  defp request(url, body_options) do
    options =
      ([
         method: :post,
         url: url,
         headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
         redirect: false,
         retry: false,
         decode_body: false,
         compressed: false,
         raw: true,
         receive_timeout: @receive_timeout,
         connect_options: [timeout: @connect_timeout] ++ transport_opts(),
         into: Calls.collect(@max_response)
       ] ++ body_options)
      |> Keyword.merge(Application.get_env(:apiary, __MODULE__, [])[:req_options] || [])

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        if Req.Response.get_private(response, :too_large),
          do: {:error, "bad_response"},
          else: {:ok, response.status, response.body, response.headers}

      {:error, %{reason: :timeout}} ->
        {:error, "timeout"}

      {:error, _exception} ->
        {:error, "network"}
    end
  end

  defp transport_opts do
    case CallTrust.transport_opts() do
      [] -> []
      tls -> [transport_opts: tls]
    end
  end
end
