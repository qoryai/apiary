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
  #  4. 120 tokens issued to the run in its current window of 60 seconds: `429`,
  #     `TOOMANYREQUESTS`, with `Retry-After`, the seconds until the window ends;
  #  5. a run that ended: `401`, `UNAUTHORIZED`;
  #  6. no `service`, or one other than `QORY_REGISTRY`: `400`, `UNSUPPORTED`;
  #  7. more than 16 `scope` parameters: `400`, `UNSUPPORTED`;
  #  8. nothing granted, no scope included, or a run that does not go through a gateway
  #     (`Apiary.Registry.RunAccess.applies?/1`): `401`, `UNAUTHORIZED`;
  #  9. a failure to read or sign: `503`, `UNAVAILABLE`, with a line in the log.
  #
  # The limit (4) is a count per run in a fixed window (`Apiary.Runs.RateLimit.reserve/3`),
  # checked right after the credential matches a run, before the run's rights are read: a
  # request reserves one of the 120, and a refusal after it (5 to 9) gives it back, so the
  # count is of the tokens issued in the window and the requests still being answered. A
  # request whose credential matches no run has no limit per run here.
  #
  # Every `401` has `WWW-Authenticate: Basic realm="Qory Apiary"`. No answer and no log
  # line has the credential or the token.

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :registry

  require Logger

  alias Apiary.Registry
  alias Apiary.Registry.{Credential, Grant, RunAccess, Token}
  alias Apiary.Runs.RateLimit

  # At most 120 tokens to a run in a window of 60 seconds.
  @limit 120
  @window :timer.seconds(60)

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    answer(conn, query(conn.query_string))
  rescue
    exception ->
      Logger.error(
        "Qory Apiary could not build the response to a registry token request: " <>
          inspect(exception.__struct__)
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
      "Send the token request as a GET request. Only a GET request gets a registry token here."
    )
  end

  defp answer(conn, query) do
    with {:ok, username, secret} <- basic(conn),
         {:ok, run} <- verified(username, secret),
         {:ok, window} <- limited(run) do
      case issued(run, query, window) do
        {:ok, token, now} ->
          json(conn, %{
            token: token,
            expires_in: Token.lifetime_seconds(),
            issued_at: DateTime.to_iso8601(now)
          })

        {:refuse, status, code, message} ->
          RateLimit.release(limit_key(run), window)
          refuse(conn, status, code, message)
      end
    else
      {:refuse, status, code, message} ->
        refuse(conn, status, code, message)

      {:limited, retry_after, message} ->
        conn
        |> put_resp_header("retry-after", "#{retry_after}")
        |> refuse(429, "TOOMANYREQUESTS", message)
    end
  end

  # The token for `run`, once it reserved one of its limit in `window`, which an
  # exception gives back before it is answered `503`.
  defp issued(run, query, window) do
    with :ok <- live(run),
         :ok <- service(query),
         {:ok, access} <- granted(run, query) do
      now = DateTime.truncate(DateTime.utc_now(), :second)
      {:ok, Token.issue(ApiaryWeb.Endpoint.url(), run.public_id, access, now), now}
    end
  rescue
    exception ->
      RateLimit.release(limit_key(run), window)
      reraise exception, __STACKTRACE__
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
    rights = if RunAccess.applies?(run), do: RunAccess.rights(run), else: :none

    case rights != :none && Grant.grant(rights, scopes) do
      result when result in [false, {:ok, []}] ->
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
    case RateLimit.reserve(limit_key(run), @limit, @window) do
      {:ok, window} ->
        {:ok, window}

      {:error, retry_after} ->
        {:limited, retry_after,
         "Wait 1 minute, then try again. Qory Apiary issued #{@limit} registry tokens to the " <>
           "run #{run.public_id} in the last 60 seconds, the limit."}
    end
  end

  defp limit_key(run), do: {:registry_token, run.id}

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
