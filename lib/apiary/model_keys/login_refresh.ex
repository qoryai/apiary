defmodule Apiary.ModelKeys.LoginRefresh do
  @moduledoc """
  The call that refreshes a key's sign-in (`Apiary.ModelKeys.Login`): one HTTPS POST to
  the token endpoint of the provider's catalogue entry, `oauth_refresh`, as `codex` sends
  it. The body is JSON, not form-encoded: `grant_type` `refresh_token`, `client_id`,
  `refresh_token` and `refresh_reason` (`proactive_expiry` or `scheduled`), and no
  `scope`.

  This is the one call to the provider's login server that Qory Apiary makes, with no
  adapter. The URL and the client id come from the catalogue entry alone, never from a
  person's input or a stored value, and `Apiary.Kinds.Endpoint.check/1` checks the URL
  at every call. The call verifies TLS against the operating system's certificate
  authorities (and the file `SSL_CERT_FILE` names, as an adapter call does), follows no redirect, is not retried, and
  stops after 15 seconds (5 to connect, 10 for each read) in a separate task. It keeps
  at most 64 KiB of the answer. The user agent is `qory-apiary`.

  `call/3` returns `{:ok, tokens}` with the new access token and, when the provider sent
  one, the new refresh token, or a failure that is `{:permanent, cause}` for a refusal
  that stays (the provider rejected the refresh token: the cause is one of
  `Apiary.ModelKeys.Login.causes/0`) or `{:transient, cause}` for one that may pass:
  `http_<status>`, `timeout`, `network`, `bad_response`, `bad_endpoint`. A cause is one of
  those fixed words, never a part of the provider's answer. Neither the answer's body, the
  request, nor an error of the HTTP client reaches a log, a return value or an exception
  message: the task's crash is caught inside it.

  The answer is classified as `codex` does (`login/src/auth/manager.rs`): the code is the
  first text that is not blank of `error` (a string), `error.code` and the top-level
  `code`, in lower case. An answer of 200 whose `access_token` is not printable ASCII
  (it goes into a header) is `bad_response`. A code
  that is one of the three named ones is permanent whatever the status, then a 400
  `invalid_grant`, then any 401 (`refresh_unauthorized`); every other status is transient.
  """

  alias Apiary.Adapters.{CallTrust, Calls}
  alias Apiary.Kinds.Endpoint

  @supervisor __MODULE__.Supervisor
  @connect_timeout 5_000
  @receive_timeout 10_000
  @total_timeout 15_000
  @max_answer 65_536
  @user_agent "qory-apiary"
  @named_codes ~w(refresh_token_expired refresh_token_reused refresh_token_invalidated)
  @reasons ~w(proactive_expiry scheduled)

  @typedoc "The catalogue entry's `oauth_refresh`: the token endpoint and the client id."
  @type endpoint :: %{required(String.t()) => String.t()}

  @typedoc "What a refresh brings back: the refresh token is nil when the provider kept it."
  @type tokens :: %{access_token: String.t(), refresh_token: String.t() | nil}

  @type result ::
          {:ok, tokens} | {:permanent, String.t()} | {:transient, String.t()}

  @doc "The name of the supervisor that runs each call's task, for the application's children."
  @spec supervisor() :: atom
  def supervisor, do: @supervisor

  @doc """
  Refreshes the sign-in whose refresh token is `refresh_token`, at the endpoint
  `oauth_refresh` of the catalogue entry, for `reason`, `"proactive_expiry"` or
  `"scheduled"`.
  """
  @spec call(endpoint, String.t(), String.t()) :: result
  def call(%{"url" => url, "client_id" => client_id}, refresh_token, reason)
      when is_binary(url) and is_binary(client_id) and is_binary(refresh_token) and
             reason in @reasons do
    case Endpoint.check(url) do
      :ok ->
        body = %{
          "grant_type" => "refresh_token",
          "client_id" => client_id,
          "refresh_token" => refresh_token,
          "refresh_reason" => reason
        }

        run(url, body)

      {:error, _refusal} ->
        {:transient, "bad_endpoint"}
    end
  end

  def call(_endpoint, _refresh_token, _reason), do: {:transient, "bad_endpoint"}

  # The request in a task that is linked to nobody and stopped at the call's limit. The
  # task catches every failure, so its crash report, which would carry the request's
  # closure, is never written.
  defp run(url, body) do
    task =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        try do
          request(url, body)
        rescue
          _exception -> {:transient, "network"}
        catch
          _kind, _reason -> {:transient, "network"}
        end
      end)

    total = Application.get_env(:apiary, __MODULE__, [])[:total_timeout] || @total_timeout

    case Task.yield(task, total) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:transient, "network"}
      nil -> {:transient, "timeout"}
    end
  end

  defp request(url, body) do
    options =
      [
        method: :post,
        url: url,
        json: body,
        headers: [{"user-agent", @user_agent}],
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        raw: true,
        receive_timeout: @receive_timeout,
        connect_options: [timeout: @connect_timeout] ++ transport_opts(),
        into: Calls.collect(@max_answer)
      ]
      |> Keyword.merge(Application.get_env(:apiary, __MODULE__, [])[:req_options] || [])

    case Req.request(options) do
      {:ok, %Req.Response{} = response} ->
        if Req.Response.get_private(response, :too_large),
          do: {:transient, "bad_response"},
          else: classify(response.status, response.body)

      {:error, %{reason: :timeout}} ->
        {:transient, "timeout"}

      {:error, _exception} ->
        {:transient, "network"}
    end
  end

  defp transport_opts do
    case CallTrust.transport_opts() do
      [] -> []
      tls -> [transport_opts: tls]
    end
  end

  defp classify(200, body), do: tokens(body)
  defp classify(status, _body) when status in 201..299, do: {:transient, "bad_response"}

  defp classify(status, body) do
    code = error_code(body)

    cond do
      code in @named_codes -> {:permanent, code}
      status == 400 and code == "invalid_grant" -> {:permanent, "invalid_grant"}
      status == 401 -> {:permanent, "refresh_unauthorized"}
      true -> {:transient, "http_#{status}"}
    end
  end

  defp tokens(body) do
    case decode(body) do
      %{"access_token" => access_token} = answer
      when is_binary(access_token) and access_token != "" ->
        if printable?(access_token),
          do: with_refresh_token(answer, access_token),
          else: {:transient, "bad_response"}

      _other ->
        {:transient, "bad_response"}
    end
  end

  # The access token goes into a request header: printable ASCII with no space, as the
  # account id is checked (`Apiary.ModelKeys.Login.parse/1`).
  defp printable?(access_token), do: String.match?(access_token, ~r/\A[!-~]+\z/)

  defp with_refresh_token(answer, access_token) do
    case answer do
      %{"refresh_token" => refresh_token}
      when is_binary(refresh_token) and refresh_token != "" ->
        {:ok, %{access_token: access_token, refresh_token: refresh_token}}

      _kept ->
        {:ok, %{access_token: access_token, refresh_token: nil}}
    end
  end

  # The provider's error code, in lower case, as `codex` reads it: the first non-blank text
  # of `error` (a string), `error.code` and the top-level `code`; nil when none is. A blank
  # `error` falls through to the next. It is compared and never stored.
  defp error_code(body) do
    answer = decode(body)

    candidates =
      case answer do
        %{"error" => %{"code" => code}} -> [code, answer["code"]]
        %{"error" => error} -> [error, answer["code"]]
        %{} -> [answer["code"]]
        _other -> []
      end

    Enum.find_value(candidates, &code_text/1)
  end

  defp code_text(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: String.downcase(text))

  defp code_text(_other), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = answer} -> answer
      _other -> nil
    end
  end

  defp decode(_body), do: nil
end
