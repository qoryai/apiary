defmodule ApiaryWeb.RegistryTokenController do
  @moduledoc false

  # With the `registry` feature, which the documentation leaves out: the token route of
  # the private image registry, `GET /registry/token?service=<registry>&scope=…`, which
  # the registry names as its token realm. With the feature off, every method is answered
  # as a path the instance does not serve (`ApiaryWeb.Features.Routes`).
  #
  # The run's gateway sets the run's registry credential on the request, `basic`, the
  # run's public id and its secret (`Apiary.Registry.Credential`). The answer is `200`,
  # `{"token", "expires_in", "issued_at"}`, the token (`Apiary.Registry.Token`) with the
  # entries `Apiary.Registry.Grant` grants of the request's scopes for the run
  # (`Apiary.Registry.RunAccess.rights/1`).
  #
  # The refusals, in order, each `{"errors":[{"code","message"}]}`, the message the fix
  # and then the cause:
  #
  #  1. a method other than GET or HEAD: `405`, `UNSUPPORTED`, with `Allow: GET`;
  #  2. no Basic credential that can be read: `401`, `UNAUTHORIZED`;
  #  3. a credential that matches no run: `401`, `UNAUTHORIZED`;
  #  4. a run that ended: `401`, `UNAUTHORIZED`;
  #  5. no `service`, or one other than `QORY_REGISTRY`: `400`, `UNSUPPORTED`;
  #  6. more than 16 scopes: `400`, `UNSUPPORTED`;
  #  7. nothing granted, no scope included: `401`, `UNAUTHORIZED`;
  #  8. more than 120 tokens to the run in 60 seconds: `429`, `TOOMANYREQUESTS`, with
  #     `Retry-After`;
  #  9. a failure to read or sign: `503`, `UNAVAILABLE`, with a line in the log.
  #
  # Every `401` has `WWW-Authenticate: Basic realm="Qory Apiary"`. No answer and no log
  # line has the credential or the token.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :registry

  require Logger

  alias Apiary.Registry
  alias Apiary.Registry.{Credential, Grant, RunAccess, Token}
  alias Apiary.Runs.RateLimit

  # 120 tokens a run at once, refilled at 2 a second: 120 in 60 seconds.
  @burst 120
  @rate 2

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    answer(conn, query(conn.query_string))
  rescue
    exception ->
      Logger.error(
        "a registry token request could not be answered: #{inspect(exception.__struct__)}"
      )

      refuse(
        conn,
        503,
        "UNAVAILABLE",
        "Try the pull or push again in 1 minute. Qory Apiary could not issue a registry " <>
          "token; the cause is in the instance's log."
      )
  end

  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "GET")
    |> refuse(
      405,
      "UNSUPPORTED",
      "Send the token request as a GET request. A POST request gets no registry token here."
    )
  end

  defp answer(conn, query) do
    with {:ok, username, secret} <- basic(conn),
         {:ok, run} <- verified(username, secret),
         :ok <- live(run),
         :ok <- service(query),
         {:ok, access} <- granted(run, query),
         :ok <- limited(run) do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      token = Token.issue(ApiaryWeb.Endpoint.url(), run.public_id, access, now)

      json(conn, %{
        token: token,
        expires_in: Token.lifetime_seconds(),
        issued_at: DateTime.to_iso8601(now)
      })
    else
      {:refuse, status, code, message} ->
        refuse(conn, status, code, message)

      {:limited, retry_after, message} ->
        conn
        |> put_resp_header("retry-after", "#{retry_after}")
        |> refuse(429, "TOOMANYREQUESTS", message)
    end
  end

  defp basic(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {username, secret} when username != "" and secret != "" ->
        {:ok, username, secret}

      _none ->
        unauthorized(
          "Send the token request through the run's gateway, which adds the run's registry " <>
            "credential. The request has no registry credential."
        )
    end
  end

  defp verified(username, secret) do
    case Credential.verify(username, secret) do
      {:ok, run} ->
        {:ok, run}

      :error ->
        unauthorized(
          "Send the token request through the gateway of a running run. The registry " <>
            "credential in the request matches no run of this instance."
        )
    end
  end

  defp live(run) do
    if Credential.live?(run),
      do: :ok,
      else:
        unauthorized(
          "Start a new run to pull or push images. The run #{run.public_id} has ended, and " <>
            "its registry credential ended with it."
        )
  end

  defp service(%{service: service}) do
    expected = Registry.service()

    cond do
      service == expected ->
        :ok

      is_nil(service) ->
        {:refuse, 400, "UNSUPPORTED",
         service_fix(expected) <> " The request has no service parameter."}

      true ->
        {:refuse, 400, "UNSUPPORTED",
         service_fix(expected) <> " The request's service parameter is #{shown(service)}."}
    end
  end

  defp service_fix(expected),
    do: "Set the registry's token service to #{expected}, the host in QORY_REGISTRY."

  # A value of the request as the message repeats it: without control characters, and at
  # most 253 characters.
  defp shown(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.slice(0, 253)
  end

  defp granted(run, %{scopes: scopes}) do
    case Grant.grant(RunAccess.rights(run), scopes) do
      {:ok, []} ->
        unauthorized(
          "Ask only for images inside the run. The request contains no image that the run " <>
            "#{run.public_id} may pull or push."
        )

      {:ok, access} ->
        {:ok, access}

      {:error, {:too_many_scopes, count}} ->
        {:refuse, 400, "UNSUPPORTED",
         "Send at most #{Grant.max_scopes()} scope parameters in one token request. " <>
           "The request has #{count}."}
    end
  end

  defp limited(run) do
    case RateLimit.check({:registry_token, run.id}, rate: @rate, burst: @burst) do
      :ok ->
        :ok

      {:error, retry_after} ->
        {:limited, retry_after,
         "Wait 1 minute, then try again. Qory Apiary issued #{@burst} registry tokens to the " <>
           "run #{run.public_id} in the last 60 seconds, the limit."}
    end
  end

  defp unauthorized(message), do: {:refuse, 401, "UNAUTHORIZED", message}

  defp refuse(conn, status, code, message) do
    conn =
      if status == 401,
        do: put_resp_header(conn, "www-authenticate", ~s(Basic realm="Qory Apiary")),
        else: conn

    conn
    |> put_status(status)
    |> json(%{errors: [%{code: code, message: message}]})
  end

  # The request's `service`, the first one, and every `scope`, in order: Phoenix's
  # params keep the last of a repeated name, and a request may repeat `scope`. A query
  # that cannot be decoded has neither.
  defp query(query_string) do
    pairs = Enum.to_list(URI.query_decoder(query_string))

    %{
      service: Enum.find_value(pairs, fn {name, value} -> if name == "service", do: value end),
      scopes: for({"scope", value} <- pairs, do: value)
    }
  rescue
    ArgumentError -> %{service: nil, scopes: []}
  end
end
