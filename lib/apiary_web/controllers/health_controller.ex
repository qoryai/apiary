defmodule ApiaryWeb.HealthController do
  @moduledoc """
  `GET /health` for load balancers, container orchestrators and deploy scripts.

  Returns 200 when the database answers `SELECT 1` and 503 otherwise, both with the
  release's version and revision (`Apiary.Revision`). The 200 also has `set_up`, true once
  the instance is set up (`Apiary.Setup.set_up?/0`), so a deploy script or an instance
  admin can see whether the instance is set up. The 503 has no `set_up`, because the
  lookup needs the database. A 200 has none either when the lookup fails or takes more
  than five seconds, the same bound as `SELECT 1`; the log then has one warning with the
  cause. No authentication, no session, never cached.
  """
  use ApiaryWeb, :controller

  require Logger

  @timeout 5_000

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case database_status() do
      :ok ->
        body = %{status: "ok", database: "ok", version: version(), revision: revision()}
        json(conn, put_set_up(body))

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "degraded",
          database: "error",
          version: version(),
          revision: revision()
        })
    end
  end

  defp database_status do
    case Apiary.Repo.query("SELECT 1", [], timeout: @timeout) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  # The database answered a moment ago, but the lookup can still fail or be slow; the body
  # then leaves `set_up` out and stays a 200. The lookup runs in a task, so the five-second
  # bound applies to whatever query the edition makes
  # (`c:Apiary.Edition.instance_organisation_id/0`).
  defp put_set_up(body) do
    task = Task.async(&set_up_lookup/0)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, set_up?}} ->
        Map.put(body, :set_up, set_up?)

      {:ok, {:error, cause}} ->
        warn(cause)
        body

      {:exit, reason} ->
        warn(caught(:exit, reason))
        body

      nil ->
        warn("a timeout after #{div(@timeout, 1000)} s")
        body
    end
  end

  defp set_up_lookup do
    {:ok, Apiary.Setup.set_up?()}
  rescue
    exception -> {:error, inspect(exception.__struct__)}
  catch
    kind, reason -> {:error, caught(kind, reason)}
  end

  # An atom reason, such as `:timeout` or `:killed`, comes from code; any other term may
  # contain data, so the log line has only the kind.
  defp caught(:exit, reason) when is_atom(reason), do: "an exit with #{inspect(reason)}"
  defp caught(:exit, _reason), do: "an exit"
  defp caught(:throw, reason) when is_atom(reason), do: "a throw of #{inspect(reason)}"
  defp caught(:throw, _reason), do: "a throw"

  defp warn(cause) do
    Logger.warning("GET /health left out set_up: the set-up lookup failed with #{cause}")
  end

  defp version do
    :apiary |> Application.spec(:vsn) |> to_string()
  end

  defp revision, do: Apiary.Revision.get()
end
